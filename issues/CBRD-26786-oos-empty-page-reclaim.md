# [OOS/VACUUM] vacuum의 OOS 슬롯 삭제 후 빈 페이지 회수

## Issue Triage

**이슈 수행 목적**: vacuum 이 OOS 슬롯을 모두 비운 페이지를 OOS 파일에 반환해, 삭제가 많은 워크로드에서 빈 페이지가 누적되지 않게 한다.

**이슈 수행 이유**:

- **현재 동작**: `oos_delete` 는 슬롯만 비우고 페이지는 OOS 파일에 그대로 매달아 둔다. bestspace 캐시에 빈 공간만 등록해 같은 OOS 파일 안에서의 슬롯 재사용은 가능하지만, 페이지 자체를 파일에 돌려주는 단계가 없다. 페이지 회수 책임은 처음부터 vacuum 의 일로 설계됐는데 (`oos_delete` header 주석 + `oos_remove_page` 의 TODO 주석 둘 다 명시), 정작 vacuum 측 호출 경로 어디에도 회수 호출이 들어가 있지 않다. (상세 코드 인용은 Description 의 배경 섹션 참조.)
- **영향**: 삭제/UPDATE 비중이 큰 OOS 워크로드에서 회수되지 않은 빈 페이지가 단조 누적된다. 한 OOS 파일 안의 다른 insert 가 그 빈 슬롯을 재사용할 수는 있지만, 페이지가 다른 파일로 재할당되지는 않는다. 결과적으로 OOS 파일 페이지 수가 줄지 않는다.

**이슈 수행 방안 (요약)**:

- 페이지 회수 mechanic 은 storage 레이어 helper 한 곳에 모은다 (`oos_try_reclaim_empty_page` 신설).
- helper 호출 trigger 는 vacuum 두 경로 + SA_MODE eager 한 경로, 총 세 caller 의 batch boundary 에서 일괄 호출한다. `oos_delete` 의 inner per-OID loop 핫패스에는 검사 안 넣음.
- bestspace 캐시 일관성은 기존 `oos_stats_del_bestspace_by_vpid` 재사용으로 해결.
- sticky first page 보호는 helper 안에서 처리.
- 미결정 사항 (sysop 경계, batch 단위, container 선택, recovery 호환성) 은 본문 `## Open Design Questions` 섹션에 후보안과 트레이드오프를 정리. 각 항목은 ANALYSIS 단계에서 확정.
- 회귀 테스트는 Acceptance Criteria 에 구체 시나리오 (10000-row insert/delete 사이클, UPDATE heavy, 동시 워크로드) 로 명시.

상세 설계 결정 / 구현 / 트레이드오프는 아래 AI-Generated Context 섹션 참조.

---

## AI-Generated Context

> 아래 내용은 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 **Issue Triage** 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **문제 / 목적**: vacuum 이 OOS 슬롯을 다 비운 페이지를 OOS 파일에 반환하지 못해 빈 페이지가 누적된다. 빈 페이지를 `file_dealloc` 으로 반환한다.
- **원인 / 배경**: vacuum 측 호출자 (`vacuum_heap_oos_delete`, `vacuum_forward_walk_delete_old_oos`, `heap_update_home_delete_replaced_oos`) 에 페이지 회수 호출이 빠져있고, `oos_remove_page` 는 본문은 갖췄지만 caller 가 0건인 미연결 함수다.
- **제안 / 변경**: storage 레이어 helper (`oos_try_reclaim_empty_page`) 신설 + 세 caller 에서 batch boundary 호출. bestspace 캐시 일관성, sticky first page 가드, transactional safety 검토 동반.
- **영향 범위**: `src/storage/oos_file.{cpp,hpp}`, `src/query/vacuum.c`, `src/storage/heap_file.c`. 사용자 가시 호환성 영향 없음.

---

## Description

### 배경

OOS 마일스톤 1 에서 `oos_delete` (CBRD-26609) 가 도입돼 슬롯 단위 물리 삭제가 가능해졌고, CBRD-26668 에서 vacuum 통합이 마무리됐다. 현재 vacuum 워커는 MVCC 가 dead 로 판정한 heap 레코드의 OOS OID 들을 다음 세 경로에서 `oos_delete` 로 회수한다.

| 경로 | 위치 | 트리거 |
|---|---|---|
| `vacuum_heap_oos_delete` | `vacuum.c:2419` | 죽은 heap 슬롯의 OOS OID 회수 (REMOVE path) |
| `vacuum_forward_walk_delete_old_oos` | `vacuum.c:3458` | `RVHF_UPDATE_NOTIFY_VACUUM` 의 pre-image OOS OID 회수 (UPDATE 로 교체된 옛 OID) |
| `heap_update_home_delete_replaced_oos` | `heap_file.c:24131` (oos_delete 루프 `heap_file.c:24178`) | SA_MODE 에서 UPDATE 직후 옛 OOS OID 즉시 회수 |

세 경로 모두 슬롯만 비우고 페이지는 그대로 둔다. `oos_delete` (`oos_file.cpp:1816`) 는 `oos_delete_chain` (`oos_file.cpp:1717`) 안에서 chunk 단위로 슬롯만 지우고, chunk 삭제 직후 `oos_stats_update` (`oos_file.cpp:1774`) 로 bestspace 캐시에 free space 만 등록한다. 페이지에 슬롯이 0개가 되어도 `file_dealloc(... FILE_OOS)` 는 호출되지 않는다.

`oos_remove_page` (`oos_file.cpp:1007`) 는 `file_dealloc` 호출 본문을 가지고 있으나 호출자가 0건인 미연결 함수다. 그 위 한 줄 TODO 주석 (`oos_file.cpp:1005`) 은 "will be called by vacuum when OOS vacuum is implemented" 라고 명시한다. `oos_delete` 의 header 주석 (`oos_file.cpp:1812-1813`) 도 "Page deallocation is NOT done here. Empty pages will be reclaimed by vacuum after the transaction commits." 라고 책임을 vacuum 으로 미뤄두었다.

### 영향 받지 않는 경로

- DROP TABLE 의 OOS 파일 통째 reclaim 경로는 본 이슈와 무관하다. `xheap_destroy` (`heap_file.c:5921`) 가 `oos_remove_file` 를 호출하고 (`heap_file.c:5941`), `oos_remove_file` 는 `file_postpone_destroy` 로 위임한다 (`oos_file.cpp:1000`). 파일 단위 reclaim 은 이미 구현되어 있다.
- REC_BIGONE + OOS 의 경우는 `vacuum.c:2589` 에서 invariant 로 막아둔 상태 (`assert (!heap_recdes_contains_oos (&helper->record))`) 이므로 본 이슈 범위 밖이다.
- `RVVAC_NOTIFY_DROPPED_FILE` 게이트와 OOS 처리의 상호작용은 검증된 상태다. REMOVE 경로는 `vacuum_collect_heap_objects` (`vacuum.c:3671`) 로 큐잉되며 forward-walk 진입점도 같은 dropped-file 게이트 (`vacuum.c:3643` `if (is_file_dropped) continue`) 의 하류에 있다. 별도 조치 불필요.

### 책임 분리 결정

| 책임 | 위치 | 이유 |
|---|---|---|
| mechanic (빈 페이지 판정 + dealloc + cache 무효화) | storage 레이어 (`oos_file.cpp`) | 페이지 헤더 레이아웃, sticky first-page 체크, bestspace 캐시 무효화 — 모두 storage 내부 지식. caller 가 storage 내부 구조를 모르고도 정확하게 호출할 수 있도록 한 군데로 가둔다. |
| trigger (언제 검사할지) | caller (vacuum 2 + SA_MODE eager 1) | `oos_delete` 의 inner per-OID 루프에 검사를 넣으면 O(deleted OIDs) 비용이 되지만 caller 쪽 batch boundary 에서 한 번 호출하면 O(touched pages) 로 줄어든다. 그리고 `file_dealloc` 가 fhead 페이지를 fix 하므로 inner loop 안에서 호출하면 chunk-삭제와 page-회수의 latch 보유 구간이 겹친다. |

`oos_delete` 의 header 주석 (`oos_file.cpp:1812-1813`) 이 이미 "Empty pages will be reclaimed by vacuum after the transaction commits." 라고 design intent 를 못박아두었다. 본 작업은 이 미완 부분을 마저 채운다.

---

## Open Design Questions

ANALYSIS 단계에서 확정해야 하는 결정들이다. 각 항목은 후보안과 트레이드오프를 정리해두었으니, 분석 담당자가 이 표를 출발점으로 삼으면 된다.

### Q1. `file_dealloc` 호출의 sysop 경계

vacuum caller 들은 이미 `log_sysop_start/commit` 안에서 동작한다 (`vacuum.c:2494`, `vacuum.c:3471`). helper 가 호출하는 `file_dealloc` 을 그 sysop 안에 둘지, sysop 밖에 둘지 결정 필요.

| 후보안 | 동작 | 장점 | 단점 |
|---|---|---|---|
| **A. sysop 안에서 호출** | 슬롯 삭제 + helper 호출이 같은 sysop 에 들어감. sysop commit 시 모두 atomic 하게 반영. | 코드 단순. 부분 실패 시 sysop abort 로 자동 복원. dealloc 와 슬롯 비움이 같은 logical unit. | sysop 크기가 커져 log 양 증가. `file_dealloc` 자체가 fhead 와 대상 페이지를 fix 하므로 latch 보유 구간이 길어짐. `RVFL_DEALLOC` postpone 의 sysop-end-postpone 처리가 정상 동작하는지 검증 필요 (`log_manager.c:4015`, `log_manager.c:4109` 부근). |
| **B. sysop commit 후 별도 호출** | 슬롯 삭제 sysop 가 먼저 commit. touched VPID 집합을 caller 컨텍스트가 들고 있다가, sysop 종료 후 별도로 helper 를 호출. | sysop 크기 작게 유지. 슬롯 삭제와 페이지 회수의 latch 구간 분리. | helper 호출 도중 크래시 시 슬롯은 비어있고 페이지는 매달려있는 중간 상태가 잔존 (다음 vacuum 사이클에서 회수되므로 무결성은 문제 없으나 일시적 공간 누수). caller 코드가 sysop boundary 와 helper 호출 boundary 두 개를 명시적으로 관리해야 함. |

**잠정 권고**: B. sysop 분리. 이유는 (1) sysop 안에서의 `file_dealloc` 의 sysop-end-postpone interaction 이 검증되지 않은 영역이고, (2) 어차피 helper 는 idempotent 라 중간 상태가 다음 사이클에서 회수되므로 atomicity 가 critical 하지 않으며, (3) latch 구간 분리가 동시성에 유리. 단, ANALYSIS 단계에서 `RVFL_DEALLOC` 의 sysop 처리 코드 (`log_manager.c` 의 sysop-end 경로) 를 직접 읽고 A 안의 안전성을 다시 평가해야 함.

### Q2. helper 호출 batch 단위

언제 helper 를 호출할지. 너무 자주 호출하면 페이지 fix 가 잦아지고, 너무 늦게 호출하면 페이지가 빈 채로 살아있는 시간이 길어진다.

| 후보안 | 동작 | 장점 | 단점 |
|---|---|---|---|
| **A. per-record** | 한 dead heap record (vacuum) 또는 한 UPDATE context (SA_MODE) 의 OOS OID 들을 모두 처리한 직후 helper 호출. | 빈 페이지가 발견되자마자 회수 (회수 latency 짧음). caller 코드 변경 작은 편 (기존 record 처리 함수의 끝에 한 줄 추가). | 한 record 의 OOS OID 들이 여러 페이지에 걸쳐있으면 helper 가 record 마다 여러 번 호출. record 가 많은 워크로드에서는 호출 빈도가 높음. |
| **B. per-page (vacuum 의 heap page 단위)** | vacuum 의 한 heap page 처리 종료 시점에 그 page 내 모든 dead record 의 OOS touched VPID 를 모아 helper 호출. | helper 호출 빈도 감소 (heap page 단위로 amortize). 같은 OOS 파일의 여러 record 가 같은 OOS 페이지를 touch 하는 경우 dedup 효과. | touched VPID 집합이 page 처리 중 메모리에 머무름 (집합 크기 < 수십개 예상이라 부담은 작음). batch 단위가 vacuum 의 heap-page 단위라 SA_MODE 경로에는 적용 불가 (SA_MODE 는 heap-page 가 아닌 record-level 작업). |
| **C. per-block (vacuum log block)** | vacuum 의 한 log block 처리 끝에 한 번 helper 호출. | helper 호출 빈도 최소. | touched VPID 집합이 block 단위로 커짐 (수백개 가능). 회수 latency 가 block 처리 시간만큼 늘어남. SA_MODE 에는 의미 없음 (block 개념 없음). |

**잠정 권고**: vacuum 두 caller 는 **A (per-record)** 시작 후 측정 결과에 따라 B 로 격상 검토. SA_MODE eager 는 **A (per-UPDATE)** 고정. 이유: A 가 가장 단순하고 회수 latency 도 짧음. helper 호출 비용이 측정상 문제되지 않으면 그대로 두고, 측정상 호출이 너무 잦으면 vacuum 측만 B 로 옮김.

### Q3. touched VPID 집합 컨테이너 선택

helper 호출 전까지 touched VPID 들을 어디에 모아둘지.

| 후보안 | 장점 | 단점 |
|---|---|---|
| **A. `std::set<VPID>`** | 자동 정렬 + 자동 dedup. 코드 단순. | 노드 단위 할당 → small-N 에서 오버헤드 큼. |
| **B. `std::unordered_set<VPID>` (custom hasher 필요)** | O(1) 삽입/조회. | hasher 작성 필요. small-N 에서 hash table overhead. |
| **C. `std::vector<VPID>` + 호출 직전 sort + unique** | 메모리 locality 좋음. small-N 에 최적. | 호출 직전 정렬/dedup 비용. 사용자가 dedup 잊으면 helper 가 같은 VPID 두 번 호출 (idempotent 라 정확성은 안전, 비용은 낭비). |

**잠정 권고**: **C (vector + sort/unique)**. 한 record/page 의 touched VPID 수는 실측상 한 자릿수~수십개 정도일 것으로 예상되므로 vector 가 가장 효율. 호출부에서 sort+unique 를 강제하는 helper convention 을 두면 dedup 누락 우려도 해결. 단, 측정값이 예상과 다르면 A/B 로 재검토.

### Q4. `RVFL_DEALLOC` recovery 의 vacuum sysop / SA_MODE 호환성

`file_dealloc` 은 permanent file 에 대해 `RVFL_DEALLOC` postpone 레코드를 남겨 commit/run-postpone 시점에 실제 페이지 해제를 수행한다 (`file_manager.c:6181-6190`). 이 postpone 처리가 vacuum sysop / SA_MODE 컨텍스트에서 정상 동작하는지 확인 필요.

검증 항목:

- **vacuum sysop 안에서의 호출 (Q1-A 채택 시)**: `RVFL_DEALLOC` postpone 이 sysop-end-postpone 경로 (`log_sysop_attach_to_outer` / `log_sysop_end_logical_run_postpone`, `log_manager.c:4015`, `log_manager.c:4109`) 로 outer transaction 에 attach 되는지, attach 된 postpone 이 outer commit 시점에 정상 실행되는지.
- **vacuum sysop commit 후 호출 (Q1-B 채택 시)**: vacuum worker 자체가 어떤 transaction context 에서 동작하는지 (vacuum dedicated transaction? heap operation 의 user transaction?), 그 컨텍스트에서 `RVFL_DEALLOC` postpone 이 정상 실행되는지.
- **SA_MODE eager 경로**: SA_MODE 트랜잭션이 active 상태에서 호출됐을 때 `RVFL_DEALLOC` 가 어느 시점에 실제 dealloc 으로 이어지는지. abort 시 postpone 이 취소되는지 유지되는지. (이전 draft 에서 "abort 시 자동 취소" 라고 단정한 부분은 검증 없이는 부정확하므로 이 단계에서 코드로 확인.)
- **`FILE_OOS` 자체의 recovery 지원**: `file_dealloc(... FILE_OOS)` 가 다른 file type 과 동일하게 recovery 되는지 (`FILE_OOS` 가 비교적 신규 file type 이므로 recovery 경로에 아직 검증 안 된 분기가 있을 가능성).

**잠정 권고**: ANALYSIS 단계에서 위 네 항목을 코드 inspection + crash injection 테스트로 각각 확인. 결과에 따라 Q1 의 sysop 경계 결정 (A vs B) 이 강제될 수 있음.

### Q5. helper 의 idempotency 요구사항 구체화

vacuum worker 가 helper 호출 도중 크래시 후 재기동되면 다음 worker 가 같은 블록을 재처리한다 (`VACUUM_BLOCK_FLAG_INTERRUPTED`). helper 가 idempotent 해야 함.

확인 필요한 케이스:

- **이미 dealloc 된 페이지**: `file_dealloc` 가 이미 dealloc 된 VPID 에 대해 무엇을 반환하는지 (NO_ERROR? error? assert?). helper 는 그 케이스를 NO_ERROR 로 흡수해야 함. `oos_delete_chain` 의 S_DOESNT_EXIST 회피 (`vacuum.c:3695-3696` 주석 참조) 와 동일한 idempotency 의무.
- **dealloc 직후 재할당 된 페이지**: helper 가 in-use slot > 0 을 보고 dealloc 건너뜀. 정상 동작.
- **sticky first page 강제 호출**: helper 가 sticky check 로 NO_ERROR 빠져나감. 정상 동작.

**잠정 권고**: ANALYSIS 단계에서 `file_dealloc` 의 "이미 dealloc 된 VPID" 동작을 코드로 확인 후, helper 가 그 케이스를 어떻게 흡수할지 결정. 필요시 helper 안에 명시적 `file_get_page_status` (또는 동등) 사전 체크 추가.

---

## Specification Changes

사용자 가시 스펙 변경 없음. 내부 storage 관리 동작만 변경된다.

성능 특성 변화:

- delete/update heavy 워크로드에서 OOS 파일에 회수되지 않는 빈 페이지가 더 이상 누적되지 않는다.
- vacuum 워커당 추가 비용: touched VPID 집합 유지 + record 처리 종료 시점에 집합 크기만큼 helper 호출. 한 record 의 OOS OID 들은 보통 같은 페이지에 몰려있어 집합 크기는 작다.

---

## Implementation

### 신규 함수

| 함수 | 파일 | 책임 |
|---|---|---|
| `oos_try_reclaim_empty_page` | `oos_file.cpp` | `oos_vfid` 안의 한 VPID 가 빈 페이지인지 판정 후 `file_dealloc` + bestspace 캐시 무효화 (`oos_stats_del_bestspace_by_vpid` 재사용). Idempotent. |

helper 시그니처 초안:

```cpp
// 빈 페이지면 dealloc + bestspace 무효화. 이미 dealloc 된 경우 NO_ERROR.
// header page (sticky first page) 는 절대 dealloc 하지 않는다.
int oos_try_reclaim_empty_page (THREAD_ENTRY *thread_p, const VFID &oos_vfid, const VPID &vpid);
```

### Caller 변경

세 caller 모두 동일 패턴:

```
1. 기존 oos_delete 루프를 그대로 둔다.
2. 루프 동안 touched VPID 집합을 caller 컨텍스트에 누적 (Q3 의 잠정 권고: vector + sort/unique).
3. 루프 종료 후 집합을 순회하며 oos_try_reclaim_empty_page 호출 (Q2 의 잠정 권고: per-record).
4. helper 실패는 warning 으로 기록하고 vacuum 진행을 막지 않는다 (페이지 회수 실패는 다음 vacuum 사이클의 후보로 남으면 충분하므로 워커 자체를 멈추지 않는다).
```

대상:

- `vacuum_heap_oos_delete` (`vacuum.c:2419`) — 한 dead heap 레코드 처리 종료 시점
- `vacuum_forward_walk_delete_old_oos` (`vacuum.c:3458`) — 한 `RVHF_UPDATE_NOTIFY_VACUUM` log record 처리 종료 시점
- `heap_update_home_delete_replaced_oos` (`heap_file.c:24131`, oos_delete 루프 `heap_file.c:24178`) — 한 UPDATE 의 옛 OID 회수 종료 시점

### Header page 예외

OOS 파일의 첫 페이지는 sticky first page 로 마킹되어 있다 (`file_alloc_sticky_first_page`, `oos_file.cpp:940`). `file_manager.c:123` 의 `vpid_sticky_first` 필드 주석은 "This page should never be deallocated." 라고 명시한다. helper 는 dealloc 전에 `file_get_sticky_first_page` (`file_manager.c:5786`) 로 sticky first VPID 를 읽어 일치하면 즉시 NO_ERROR 로 빠져나간다. (`file_dealloc` 자체에도 sticky-first 페이지 dealloc 시 assert 가 있다 — `file_manager.c:6178`. 이 assert 는 dev 빌드 전용이므로 release 빌드에서도 가드를 보장하기 위해 helper 에서 한 번 더 검사한다.)

### `oos_remove_page` 처분

기존 `oos_remove_page` (`oos_file.cpp:1007`) 는 `file_dealloc(... FILE_OOS)` 호출 본문은 가지고 있으나 호출자가 0건인 미연결 함수다. 본 이슈에서 `oos_try_reclaim_empty_page` 가 sticky-first 가드 + bestspace 캐시 무효화 + in-use slot 검사를 추가한 superset 이므로 `oos_remove_page` 는 삭제한다.

### 동시 insert 와의 race 처리

동시 insert 가 빈 페이지를 재점유한 경우 helper 는 in-use slot > 0 을 보고 dealloc 를 건너뛴다. 이는 정상 동작이며, 그 페이지는 다음 vacuum batch 에서 다시 회수 후보가 된다.

---

## Acceptance Criteria

- [ ] `oos_try_reclaim_empty_page` 가 `oos_file.cpp` 에 추가된다.
- [ ] helper 가 sticky first page 를 dealloc 하지 않는다 (강제 호출 시 NO_ERROR 로 빠져나간다).
- [ ] helper 가 idempotent 하다 (이미 dealloc 된 페이지에 대해 NO_ERROR 반환).
- [ ] helper 의 in-use slot 검사 결과 > 0 이면 `file_dealloc` 을 호출하지 않는다 (단위 테스트로 가드; 구현 단계 invariant 검증).
- [ ] `vacuum_heap_oos_delete`, `vacuum_forward_walk_delete_old_oos`, `heap_update_home_delete_replaced_oos` 세 경로에서 touched VPID 추적 + helper 호출이 이루어진다.
- [ ] bestspace 캐시 엔트리가 dealloc 된 페이지에 대해 자동으로 제거된다 (helper 가 `oos_stats_del_bestspace_by_vpid` 호출).
- [ ] 10000-row insert + 10000-row delete 사이클을 5회 반복 후, OOS 파일 페이지 수가 첫 사이클 종료 시점 대비 ±10% 이내에 머문다 (insert/delete heavy 회귀).
- [ ] OOS 페이로드가 페이지당 N 개 들어가는 크기일 때, 동일 row 를 10000회 UPDATE (각 UPDATE 가 OOS 페이로드를 변경) 하고 vacuum 완료 시점에서 OOS 파일 페이지 수가 `⌈10000/N⌉ * 2` 페이지 이하 (UPDATE heavy 회귀, forward-walk + SA_MODE eager 양쪽 시나리오; 베이스라인 N 은 동일 페이로드 크기로 단일 INSERT 만 한 직후의 OOS 파일 페이지당 슬롯 수로 산출).
- [ ] vacuum 워커가 helper 호출 도중 크래시 후 재기동되어도 같은 블록을 재처리해 안전하게 회수한다.
- [ ] 동시 워크로드 CTP 시나리오: 10000-row delete 트랜잭션 commit 직후 vacuum 처리와 동시에 별 세션에서 10000-row insert 를 실행, 모든 세션 종료 후 SELECT COUNT(*) 결과가 일관되고 ER_ 로그가 0건이다.
- [ ] 기존 CI (`test_sql`, `test_medium`) 통과.

---

## Definition of done

- [ ] 위 A/C 충족
- [ ] Open Design Questions Q1-Q5 가 ANALYSIS 단계에서 모두 결정 (각 Q 의 잠정 권고를 출발점으로 검증)
- [ ] CTP 회귀 테스트 추가 (OOS 파일 페이지 수 추이 측정 시나리오)
- [ ] QA 통과

---

## 참고 코드

주요 진입점 및 신규 helper 호출 지점은 Implementation 섹션의 Caller 변경 표를 참조한다.

---

## Remarks

- 선행 / 관련 이슈:
  - CBRD-26609 — `oos_delete` API 도입 (페이지 회수는 vacuum 으로 미룬다고 명시한 그 이슈)
  - CBRD-26668 — vacuum OOS 통합 (forward-walk + REMOVE path)
  - CBRD-26715 — vacuum OOS 거짓 양성 (본 이슈 진행 시 관련 진단 로그 재사용 가능)
  - CBRD-26608 — DROP TABLE 의 OOS cleanup (파일 단위 reclaim, 본 이슈와 별개)
- 본 이슈 완료 후 OOS 의 page lifecycle (insert -> delete -> page reclaim -> file reclaim) 이 완성된다. 기존 OOS epic / M2 epic (CBRD-26357, CBRD-26583) 에 본 이슈 링크를 추가한다.
