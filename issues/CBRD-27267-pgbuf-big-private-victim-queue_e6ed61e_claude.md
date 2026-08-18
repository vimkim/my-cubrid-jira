# [PGBUF] big private victim queue의 생산 경로를 복구하거나 제거한다

## Issue Triage

**이슈 수행 목적**: quota 를 크게 초과한 private LRU 부터 회수하려는 2단계 victim 탐색이 실제로 동작하는 상태로 만들거나, 동작하지 않는 경로를 제거해 victim 탐색 코드를 단순화한다.

**이슈 수행 이유**:

| 구분 | 내용 |
|---|---|
| **AS-IS (현재 동작 / 배경)** | `big_private_lrus_with_victims`(`page_buffer.c:824`)에 리스트를 넣는 지점은 `pgbuf_lfcq_get_victim_from_private_lru` 가 이미 큐에서 하나를 꺼낸 **뒤**(`:16423`)뿐이고, 리스트를 큐에 처음 넣는 진입점은 이 큐를 아예 쓰지 않는다. 그런데 이 큐를 유일한 공급원으로 삼는 쪽은 자기 private LRU 가 quota 를 넘겨 남의 private 리스트를 뒤질 자격을 잃은 `restricted` 스레드이고, 이 스레드는 큐가 비면 승격 코드에 닿기 전에 반환한다. 즉 big 큐는 quota 이하 스레드의 통과 트래픽으로만 채워지므로, victim 을 찾는 스레드가 모두 over-quota 인 부하에서는 계속 비어 있다. 경로 전체와 실측 라인은 아래 Description 에 정리했다. |
| **TO-BE (목표 상태 / 기대 동작)** | `TBD - 합의 미확인`. 아래 두 안 중 하나를 부하 시험으로 선택한다. (a) over-quota 스레드도 big 리스트를 찾을 수 있게 생산 경로를 복구한다. (b) big 큐와 2단계 우선 소비를 제거하고 `restricted` 스레드는 private 단계를 건너뛰게 명시한다. |
| **영향** | 설계 의도 훼손 — 자기 private LRU 가 quota 를 초과한 스레드는 "quota 2배를 넘긴 큰 private 리스트부터 회수" 대신 곧바로 shared LRU 탐색 단계(`:9151`)로 내려간다. private LRU 가 막으려던 스캔 오염이 shared LRU 에서 발생하고, 정작 폭식하는 private 리스트는 회수 압력을 받지 않는다. |

**이슈 수행 방안**:

- 현황 확정은 이 이슈에서 끝났다 — 생산 경로가 아예 없는 것이 아니라 소비 경로 내부에만 있고, 그 소비 경로에 over-quota 스레드가 도달하지 못한다.
- (a)안과 (b)안 중 어느 쪽으로 갈지는 `TBD - 합의 미확인` 이다. over-quota 스레드 여럿이 동시에 victim 을 경쟁하는 부하에서 victim 탐색 비용과 shared LRU 침범량을 비교해 정한다.
- 어느 안이든 `Num_lfcq_big_private_lists` 게이지와 `Num_lfcq_prv_get_big` 카운터로 전후 값을 남기는 것을 완료 조건에 포함한다.

------------------------------------------------------------------------

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: `src/storage/page_buffer.c` 의 LFCQ(lock-free circular queue — 락 없이 index 를 넣고 빼는 원형 큐) 관련 함수 3개(`pgbuf_lfcq_add_lru_with_victims`, `pgbuf_lfcq_get_victim_from_private_lru`, `pgbuf_get_victim`)와 큐 생성/해제(`:1829`, `:2045-2048`)에 한정된다. 디스크 형식, 외부 interface, 시스템 파라미터는 바뀌지 않는다. (b)안을 택하면 `PSTAT_PB_LFCQ_LRU_PRV_GET_BIG` 와 `PSTAT_PB_LFCQ_BIG_PRV_NUM` 두 perfmon 항목이 의미를 잃으므로 statdump 출력이 바뀐다.
- 부모 EPIC 은 CBRD-27193 이고, 이 이슈가 소유하는 결함은 D4(big private victim queue 의 생산 경로)다.

------------------------------------------------------------------------

## Description

pgbuf(page buffer manager — 디스크 page 를 메모리 frame 에 캐시하고 fix, latch, 교체, flush 를 관리하는 모듈)는 victim(재사용할 수 있도록 회수 대상이 된 BCB — Buffer Control Block, frame 에 올라온 page 의 fix 수와 상태를 보관하는 제어 블록)을 찾을 때 LRU(Least Recently Used — 최근 사용 시점 기준의 page 교체 목록) 전체를 순회하지 않는다. 대신 "victim 후보를 가진 LRU 리스트" 의 index 만 LFCQ 에 담아 두고, 큐에서 index 를 하나 꺼내 그 리스트만 뒤진다.

private LRU 는 세션마다 하나씩 배정되어 대량 스캔이 공용 캐시를 오염시키지 않게 막는 장치다. 세션마다 quota 가 있고, quota 를 넘긴 리스트가 먼저 회수 대상이 된다. 그래서 큐가 세 개로 나뉘어 있다.

| 큐 | 등록 조건 | 소비 주체 |
|---|---|---|
| `big_private_lrus_with_victims` (`:824`) | 리스트 크기 100 초과 && quota 2배 초과 && 후보 2개 초과 | 모든 스레드. `restricted` 스레드에게는 유일한 공급원 |
| `private_lrus_with_victims` (`:823`) | private 이면서 over-quota | `restricted == false` 스레드만 |
| `shared_lrus_with_victims` (`:825`) | quota 무관, 후보 1개 이상 | 모든 스레드 |

`restricted` 는 `pgbuf_get_victim` 이 결정한다. 자기 private LRU 를 먼저 뒤져 실패했고(`:9087`), vacuum worker 가 아니고, 자기 리스트가 `PGBUF_LRU_LIST_IS_OVER_QUOTA_WITH_BUFFER`(`:1070-1071`, quota + max(10, quota 의 1%) 초과)면 `restrict_other = true` 가 된다(`:9100`). 즉 "남의 private 리스트를 뒤질 자격이 없는 폭식 스레드" 다. 이 스레드에게도 예외를 하나 준 것이 big 큐다 — 자기보다 훨씬 심하게 폭식하는 리스트는 뒤져도 된다는 정책이다.

### 생산·소비 지점 현황 (e6ed61e87 실측)

세 큐의 `produce` / `consume` 호출 지점을 전수 대조한 결과다.

| 큐 | produce 지점 | consume 지점 | 관찰 |
|---|---|---|---|
| `big_private_lrus_with_victims` | `:16423` 단 1곳 — `pgbuf_lfcq_get_victim_from_private_lru` 가 두 큐 중 하나에서 consume 에 성공한 **뒤** | `:16396` 단 1곳 — 같은 함수의 진입부, 다른 두 큐보다 먼저 시도 | 생산이 소비 경로 안에만 있다 |
| `private_lrus_with_victims` | `:16351` (`pgbuf_lfcq_add_lru_with_victims` 경유, 신규 등록 진입점), `:16441` (소비 후 재삽입) | `:16409` | 신규 등록 경로가 있다 |
| `shared_lrus_with_victims` | `:16359` (신규 등록 진입점), `:16506` (재삽입) | `:16483` | 신규 등록 경로가 있다 |

`pgbuf_lfcq_add_lru_with_victims` 를 호출하는 곳은 네 군데다 — `pgbuf_adjust_quotas` 의 private 루프 2곳(`:14360`, `:14406`)과 shared 루프 1곳(`:14436`), 그리고 victim 후보가 새로 생길 때마다 불리는 `pgbuf_lru_add_victim_candidate`(`:15651`). 이 함수는 `PGBUF_IS_PRIVATE_LRU_INDEX` 로 private/shared 만 구분하므로(`:16348-16363`), big 조건을 만족하는 리스트도 private 큐로 들어간다.

### 소비 경로와 막히는 지점

```
pgbuf_get_victim ()                                          page_buffer.c:9022
  1단계: 자기 private LRU 탐색                                        :9062-9102
     └ 실패 && !vacuum && 자기 리스트가 buffer 초과 over-quota
          → restrict_other = true                                     :9100
  2단계: if (quota 활성 && flush 데몬 존재)                            :9111
     └ pgbuf_lfcq_get_victim_from_private_lru (thread, restrict_other) :9117
          ├ big 큐 consume 시도                                        :16396
          │    성공 → promotion 재평가 → victim 반환
          └ 실패
               ★ restricted == true 면 즉시 return NULL                :16404-16406
                 (promotion 블록 :16419-16427 에 도달하지 못함)
               restricted == false 면 private 큐 consume               :16409
                 → 리스트가 big 조건 충족 시 big 큐로 promote           :16419-16427
  3단계: shared LRU 탐색                                               :9151
```

`:16419-16420` 의 big 판정은 `PGBUF_LRU_LIST_COUNT (lru_list) > PBGUF_BIG_PRIVATE_MIN_SIZE`(100, `:1073`) && `PGBUF_LRU_LIST_COUNT (lru_list) > 2 * lru_list->quota` && `lru_list->count_vict_cand > 1` 이다. 이 판정은 promotion 블록 안에만 있어서, big 조건을 만족하는지 여부는 **누군가 그 리스트를 private 큐에서 꺼낸 순간에만** 평가된다.

`PGBUF_LRU_VICTIM_LFCQ_FLAG`(`:1076`, `0x80000000`)가 리스트의 큐 중복 등록을 막는 역할을 하므로, 한 리스트는 세 큐 중 최대 한 곳에만 들어 있다. 따라서 big 큐는 별도 레인이 아니라 private 큐를 통과해야만 닿는 승격 레인이다.

> **요지**: big 큐는 "영원히 비어 있는" 것이 아니라 "quota 이하 스레드가 private 큐를 소비해 줄 때만 채워지는" 상태다. 이 승격을 유발할 수 있는 유일한 주체가 정작 big 큐를 필요로 하지 않는 스레드라는 점이 문제의 핵심이다.

### 이전 분석 주장의 재검증 결과

구 분석 보고서(commit `5cd4f860e` 기준의 D4)는 "big 큐는 영원히 비어 있다" 고 판정했다. `e6ed61e87` 재검증 결과 이 판정은 과하게 단정한 것이다. 정확한 서술은 아래와 같다.

| 항목 | 구 분석 D4 | e6ed61e87 재검증 |
|---|---|---|
| 신규 등록 진입점이 big 큐에 넣는가 | 넣지 않는다 | 넣지 않는다 (일치) |
| 유일한 produce 가 consume 이후인가 | 그렇다 | 그렇다 (일치) |
| big 큐가 항상 비어 있는가 | 항상 비어 있다 | 아니다. `restricted == false` 스레드가 private 큐를 소비하면서 승격시킬 수 있다 |
| over-quota 스레드가 2단계에서 항상 NULL 을 받는가 | 항상 그렇다 | 부하에 따라 다르다. quota 이하 victim 소비자가 함께 돌면 big 큐가 채워져 성공할 수 있고, 경쟁자가 모두 over-quota 면 항상 NULL 이다 |

즉 결함은 "죽은 코드" 가 아니라 "특정 부하에서만 무력해지는 자기 참조 구조" 다. 무력해지는 부하는 흔한 편이다 — 대량 스캔 세션 여럿이 동시에 도는 상황에서는 모든 victim 소비자가 over-quota 가 된다.

## Specification Changes

동작 스펙 변경은 선택안에 달려 있다. 두 안 모두 사용자 설정과 SQL 동작은 바꾸지 않는다.

| 선택안 | 스펙 변경 | 관측 지표 영향 |
|---|---|---|
| (a) 생산 경로 복구 | over-quota 스레드가 자신보다 크게 폭식한 private 리스트에서 victim 을 회수할 수 있게 된다. shared LRU 로 내려가는 빈도가 줄어든다 | `Num_lfcq_big_private_lists` 가 0 이 아닌 값을 갖고 `Num_lfcq_prv_get_big` 이 증가한다 |
| (b) 큐 제거 | over-quota 스레드는 2단계를 건너뛰고 shared LRU 로 직행하는 현행 실효 동작이 코드에 명시된다 | `Num_lfcq_big_private_lists`, `Num_lfcq_prv_get_big` 두 항목이 statdump 에서 제거된다 |

## Implementation

### 후보안 비교

| 순위 | 후보 | 권장 이유 / 고려사항 |
|---|---|---|
| 1 | (a) `pgbuf_lfcq_add_lru_with_victims` 에서 big 조건을 판정해 라우팅 | 설계 의도를 그대로 살린다. 이 함수는 이미 `lru_list` 를 받으므로 `PGBUF_LRU_LIST_COUNT`, `quota`, `count_vict_cand` 를 그 자리에서 볼 수 있어 추가 자료구조가 필요 없다. 다만 이 함수는 victim 후보가 생길 때마다 불리는 hot 경로(`:15651`)라 판정 3개가 추가되는 비용을 측정해야 한다. big 조건이 흔히 성립하면 큐가 편중돼 quota 이하 리스트가 굶을 가능성도 확인 대상이다 |
| 2 | (a') `pgbuf_adjust_quotas` 에서만 big 큐로 라우팅 | 100ms 주기 데몬 경로라 hot 경로 비용이 없다. 그 대신 quota 재계산 시점까지 최대 100ms 지연되고, 이미 큐에 들어 있는 리스트는 플래그 때문에 재라우팅되지 않아 승격이 다음 사이클로 밀린다 |
| 3 | (b) big 큐와 2단계 우선 소비 제거 | 가장 단순하고 죽은 분기가 사라진다. `restricted` 스레드는 2단계를 아예 건너뛰도록 `pgbuf_get_victim`(`:9111-9117`)에서 분기한다. over-quota 스레드가 shared LRU 를 침범하는 현행 동작을 공식화하는 셈이라, 부하 시험에서 (a)가 이득을 보이지 않을 때만 택한다 |

### (a)안을 택할 경우의 변경 지점

| 파일 / 라인 | 변경 |
|---|---|
| `page_buffer.c:16334-16369` | `pgbuf_lfcq_add_lru_with_victims` 의 private 분기에서 big 조건을 판정해 `big_private_lrus_with_victims` 또는 `private_lrus_with_victims` 로 라우팅. produce 실패 시 플래그 롤백(`:16365`)은 현행 유지 |
| `page_buffer.c:16419-16427` | 소비 후 promotion 블록은 유지. 등록 시점 판정과 소비 시점 판정이 이중이 되지만, 큐에 머무는 동안 리스트 크기가 변하므로 재평가는 필요하다 |
| `page_buffer.c:16404-16406` | `restricted` 조기 반환은 유지. big 큐가 채워지면 이 반환은 정상 동작이 된다 |

big 조건 판정을 매크로로 뽑아 두 지점이 같은 정의를 쓰게 만드는 것이 유지보수상 안전하다. 현재는 `:16419-16420` 에만 인라인으로 있다.

### 검증 방법

부하는 over-quota 스레드끼리 경쟁하는 형태여야 한다. private LRU 가 quota 를 넘도록 세션마다 큰 테이블 full scan 을 돌리고, 세션 수를 늘려 모든 victim 소비자가 over-quota 가 되게 만든다. 그 상태에서 아래 지표를 비교한다.

| 지표 | 이름 | 의미 |
|---|---|---|
| `PSTAT_PB_LFCQ_BIG_PRV_NUM` | `Num_lfcq_big_private_lists` | big 큐에 든 리스트 수 (게이지) |
| `PSTAT_PB_LFCQ_LRU_PRV_GET_BIG` | `Num_lfcq_prv_get_big` | big 큐에서 consume 성공한 횟수 |
| `PSTAT_PB_LFCQ_LRU_PRV_GET_CALLS` | `Num_lfcq_prv_get_total_calls` | 2단계 진입 횟수 |
| `PSTAT_PB_LFCQ_LRU_PRV_GET_EMPTY` | `Num_lfcq_prv_get_empty` | private 큐가 비어 실패한 횟수 |
| `PSTAT_PB_VICTIM_SEARCH_SHARED_LISTS` | shared 탐색 시간 | shared LRU 침범량의 대리 지표 |
| `PSTAT_PB_ALLOC_BCB_COND_WAIT_HIGH_PRIO` 계열 | victim 대기 시간 | 최종 사용자 체감 지표 |

이 카운터들은 전부 `perfmon_is_perf_tracking_and_active (PERFMON_ACTIVATION_FLAG_PB_VICTIMIZATION)` 게이트 안에 있고(`:16387`), `extended_statistics_activation` 기본값(`system_parameter.c:4148-4149`)에는 `PB_VICTIMIZATION`(0x10, `perf_monitor.h:64`)이 빠져 있다. 측정 시 `extended_statistics_activation` 에 0x10 을 포함시켜야 한다.

### 함께 수정할 출력 인자 초기화 누락

`pgbuf_peek_stats`(`:14686-14782`)는 `big_private_lrus_with_victims` 와 `private_lrus_with_victims` 가 NULL 일 때(quota 비활성 설정) `lfcq_big_prv_num` / `lfcq_prv_num` 출력 인자를 대입하지 않는다(`:14771-14779`). 함수 진입부의 0 초기화 목록(`:14697-14705`)에도 두 인자가 없어서, 호출자(`perf_monitor.c:1989-1990`)가 넘긴 버퍼의 이전 값이 그대로 노출될 수 있다. 위 검증 지표가 이 경로를 지나므로 부하 시험의 신뢰성이 여기에 걸려 있고, 대상 자료구조도 이 이슈와 같다. 따라서 이 초기화 누락은 이 이슈 범위로 두고 부하 시험 전에 먼저 수정한다 — 동작이 있는 결함이라 죽은 코드 정리(B4) 범위가 아니고, 통계 의미 정리 이슈(CBRD-27266)와도 분리한다.

수정은 두 출력 인자를 진입부 0 초기화 목록에 추가하는 것으로 충분하다. 큐가 NULL 인 설정에서 "큐에 든 리스트 0개" 는 정확한 값이다.

## Acceptance Criteria

- [ ] over-quota 스레드끼리 경쟁하는 부하에서 `Num_lfcq_big_private_lists` 와 `Num_lfcq_prv_get_big` 의 수정 전 값을 기록한다 (현행 동작 baseline).
- [ ] (a)안과 (b)안 중 선택한 근거가 위 지표 비교 결과와 함께 본문에 기록된다.
- [ ] (a)안을 택한 경우, 같은 부하에서 `Num_lfcq_prv_get_big` 이 0 보다 크고 shared LRU 탐색 시간이 baseline 이하다.
- [ ] (b)안을 택한 경우, big 큐 관련 자료구조와 두 perfmon 항목이 남지 않고 `restricted` 스레드의 2단계 우회가 코드에 명시된다.
- [ ] 선택한 안이 quota 비활성 설정(`private_lrus_with_victims == NULL`)에서 기존과 동일하게 동작한다.
- [ ] `pgbuf_peek_stats` 의 lock-free 큐 출력 인자 초기화 누락이 처리된다.

## Definition of done

- [ ] 위 Acceptance Criteria 충족
- [ ] QA 통과 (버퍼 포화 스트레스 시나리오 포함)
- [ ] 회귀 성능 측정: victim 대기 시간 분포와 hit rate 를 수정 전후로 비교해 악화가 없음을 확인
- [ ] (b)안을 택한 경우 statdump 항목 제거를 운영 문서에 반영

## Open Questions

### 목표 동작 선택

생산 경로를 복구할지 큐와 2단계 탐색을 제거할지는 `TBD - 합의 미확인` 이다. over-quota 경쟁 부하에서 victim 탐색 비용과 shared LRU 침범량을 비교해 정한다.

### big 조건 판정 위치

(a)안을 택할 경우 판정을 hot 경로(`pgbuf_lru_add_victim_candidate` 경유)에 둘지 100ms 주기 데몬(`pgbuf_adjust_quotas`)에만 둘지는 `TBD - 합의 미확인` 이다. 전자는 반응이 빠르고 후자는 hot 경로 비용이 없다.

### big 큐 편중 가능성

big 조건이 흔히 성립하는 부하에서 모든 소비자가 big 큐만 소비하게 되면, quota 를 조금 넘긴 리스트는 회수 압력을 받지 못한다. 이 편중이 실제로 문제가 되는지는 부하 시험에서 함께 확인해야 한다.

## 참고 코드

- `src/storage/page_buffer.c:823-825` — 세 LFCQ 필드 선언
- `src/storage/page_buffer.c:1820-1835`, `:2045-2048` — 큐 생성과 해제
- `src/storage/page_buffer.c:9022-9196` — `pgbuf_get_victim`, 3단계 탐색과 `restrict_other` 결정
- `src/storage/page_buffer.c:16326-16369` — `pgbuf_lfcq_add_lru_with_victims`, 신규 등록 진입점
- `src/storage/page_buffer.c:16380-16461` — `pgbuf_lfcq_get_victim_from_private_lru`, big 큐 consume 과 promotion
- `src/storage/page_buffer.c:14345-14442` — `pgbuf_adjust_quotas` 의 큐 재등록 지점
- `src/storage/page_buffer.c:15612-15657` — `pgbuf_lru_add_victim_candidate`, 후보 발생 시 큐 등록
- `src/storage/page_buffer.c:1060-1073` — quota 판정 매크로와 `PBGUF_BIG_PRIVATE_MIN_SIZE`

## Remarks

- 부모 EPIC: CBRD-27193
- 같은 victim 공급 계열의 정확성 결함(A3, direct victim 긴급 배정 경로 미실행)은 별도 이슈다. 이 이슈는 탐색 정책 쪽이라 수정 단위를 분리해 둔다.
