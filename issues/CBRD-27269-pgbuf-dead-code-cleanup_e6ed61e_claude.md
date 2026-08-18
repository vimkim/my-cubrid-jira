# [PGBUF] 죽은 코드와 낡은 주석을 정리한다

## Issue Triage

**이슈 수행 목적**: `page_buffer.c` 와 `page_buffer.h` 에서 소비처가 없는 코드와 현재 구현과 어긋난 주석을 걷어내, 뒤따르는 page buffer 결함 수정과 재구현 논의가 틀린 설명을 근거로 삼지 않게 한다.

**이슈 수행 이유**:

| 구분 | 내용 |
|---|---|
| **AS-IS (현재 동작 / 배경)** | 정리 대상 9건이 남아 있다. 계산만 되고 읽는 곳이 없는 `monitor.victim_rich`(`page_buffer.c:14446`), 호출부 없는 static 함수 `pgbuf_remove_private_from_aout_list`(`:10585`), 정의 자체가 없는 선언 `pgbuf_fix_without_validation_release`(`page_buffer.h:324`), 미사용 매크로 2개(`UINT16MAX` `:300`, `pgbuf_fix_without_validation` `page_buffer.h:320`), 제어 흐름에 영향을 주지 않는 `goto`(`:10772`), 그리고 현재 자료구조·동작과 어긋난 주석 3건과 헤더 인자명 1건이다. 빌드 옵션이 `-Wno-unused`(`CMakeLists.txt:613-617`)라 죽은 심볼은 경고로도 드러나지 않고, 주석과 인자명은 애초에 컴파일러가 검사하지 않는다. |
| **TO-BE (목표 상태 / 기대 동작)** | 실행 동작, 통계 값, 시스템 파라미터, 디스크 형식을 그대로 둔 채 9건을 삭제하거나 현행 코드에 맞게 고친다. 정리 후 남는 주석은 실제 자료구조(shared LRU + private LRU 2구획)와 실제 victim 탐색 흐름만 서술한다. |
| **영향** | 기술 부채 — `pgbuf_get_victim` 주석(`:9048-9052`)은 코드에 존재하지 않는 victim 재시도 정책이 있다고 읽힌다. direct victim 긴급 배정 경로를 다루는 CBRD-27264 가 이 주석을 근거로 목표 동작을 잡으면 없는 정책을 전제로 판단하게 된다. |

**이슈 수행 방안**: 아래 Implementation 표의 9건만 손대고 실행 동작은 바꾸지 않는다. AOUT 강제 비활성 자체는 기존 CBRD-20741 소관이므로 주석 문구만 현행 상태에 맞추고 `prm_tune_parameters`(`system_parameter.c:10078`)는 건드리지 않는다.

------------------------------------------------------------------------

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: `src/storage/page_buffer.c`, `src/storage/page_buffer.h` 두 파일. 삭제와 주석 교체가 대부분이고 함수 인자는 이름만 바뀌므로 외부 심볼, `SHOW PAGE BUFFER STATUS` 컬럼, perfmon 카운터, 시스템 파라미터, 디스크 형식은 전부 그대로다. `-Wno-unused` 상태라 컴파일 경고 출력도 달라지지 않는다. 아래 라인 번호는 별도 표기가 없으면 develop `e6ed61e87` 의 `page_buffer.c` 기준이다.
- **부모 EPIC / 결함 ID**: CBRD-27193 의 자식 이슈이며 결함 N9(죽은 코드·낡은 주석)와 D8(`pgbuf_peek_stats` 헤더 인자명)을 소유한다.

------------------------------------------------------------------------

## Description

`pgbuf` (page buffer manager — 디스크 page 를 메모리 frame 에 캐시하고 fix, latch, 교체, flush 를 관리하는 모듈)는 오랜 기간 여러 차례 개편을 거쳤다. atomic latch 도입, private LRU 와 quota 도입, direct victim 도입이 그때마다 자료구조를 바꿨는데, 그 과정에서 쓰이지 않게 된 필드와 함수, 그리고 새 구조를 반영하지 못한 주석이 남았다. `LRU` (Least Recently Used — 최근 사용 시점 기준 page 교체 목록), `victim` (교체 대상으로 뽑힌 BCB), `direct victim` (빈 frame 을 못 찾아 대기하는 스레드에게 재사용 가능한 BCB 를 직접 넘기는 방식), `BCB` (Buffer Control Block — frame 에 올라온 page 의 fix 수와 latch, dirty 상태를 보관하는 제어 블록)가 이 정리에서 반복해 나오는 용어다.

남은 것 중 대부분은 무해하다. 쓰이지 않는 매크로, 호출부 없는 함수, 정의조차 없는 선언이 바이너리에 미치는 영향은 사실상 없다. 문제가 되는 쪽은 주석이다. 코드를 처음 읽는 사람은 주석을 규격으로 읽으므로, 실제 코드와 다른 주석은 없는 기능을 있다고 믿게 만든다.

첫째로 `victim_rich` 주석이다. `pgbuf_get_victim` 은 자기 private LRU, 다른 private LRU, shared LRU 를 차례로 뒤지는데, 주석은 "세 탐색을 `victim_rich` 인 동안 반복한다"고 적혀 있다. 실제 재시도 루프(`:9148-9164`)는 shared 단계만 반복하고 그 조건도 flush 데몬 유무와 큐 상태다. `victim_rich` 는 `pgbuf_adjust_quotas` 가 quota 조정마다 값을 채우지만 읽는 코드가 없으니, 이 주석은 코드 어디에도 대응하지 않는다.

둘째로 `buf_LRU_list` 주석의 "garbage LRU" 다. LRU 리스트 배열이 shared, garbage, private 세 구획으로 나뉜다고 설명하지만 garbage 구획은 지금 코드에 없다. `PGBUF_TOTAL_LRU_COUNT` 는 shared 와 private 의 합일 뿐이고, `num_garbage_LRU_list` 라는 이름은 소스 전체에서 이 주석 한 곳에만 등장한다. 같은 표현이 `avoid_shared_lru_idx` 주석(`:733`)에도 남아 있다.

셋째로 AOUT 주석이다. AOUT (2Q 교체 정책에서 main queue 에서 밀려난 page identifier 의 이력을 보관하는 queue)을 설명하는 `:637-641` 주석은 page 교체 알고리즘이 "LRU + Aout of 2Q" 라고 단정한다. 그런데 `data_aout_ratio` 기본값이 `0.0`(`system_parameter.c:3499`)이고, 그것과 무관하게 `prm_tune_parameters` 가 서버·SA 모드 기동 시 값을 `0` 으로 덮어쓴다(`system_parameter.c:10078`, 주석 "disable AOUT list until we fix CBRD-20741"). `pgbuf_initialize_aout_list` 는 ratio 가 0 이면 `max_count = 0` 으로 두고 즉시 반환하므로(`:5777-5782`), 현재 빌드에서 AOUT 은 항상 비어 있다. AOUT 을 되살리는 일은 CBRD-20741 의 몫이고, 이 이슈에서는 주석이 현재 상태를 오해하게 만들지 않도록만 손댄다.

`pgbuf_peek_stats` 헤더 인자명(D8)도 같은 성질이다. 헤더 선언과 정의의 인자 이름이 어긋나 있어, 헤더만 보고 호출부를 작성하면 13번째 인자에 alloc 대기 스레드 수를 넣어야 한다고 오해한다. 실제로 그 자리에 들어가는 값은 direct victim 배정을 기다리는 flush 완료 BCB 수다. 타입이 모두 `UINT64 *` 라 컴파일러는 잡아주지 않는다.

## Specification Changes

없다(N/A). 사용자에게 노출되는 동작, 통계 컬럼, 파라미터, 매뉴얼 기재 사항 중 바뀌는 것이 없다.

## Implementation

### 정리 항목

| # | 위치 | 현재 상태 | 조치 |
|---|---|---|---|
| 1 | `page_buffer.c:713-714`, `:1638`, `:14007`, `:14052`, `:14446` | `monitor.victim_rich` 는 선언 1곳과 대입 4곳뿐이고 읽는 코드가 없다 | 필드와 초기화·계산 코드를 함께 삭제 |
| 2 | `:9048-9052` | 위 필드로 세 단계 탐색을 반복한다고 설명하는 주석 | 실제 재시도 루프(`:9148-9164`)의 조건을 서술하도록 교체 |
| 3 | `:1162`(선언), `:10578-10661`(주석과 정의) | `pgbuf_remove_private_from_aout_list` 는 호출부가 없다 | 선언과 정의 삭제 |
| 4 | `:300` | 매크로 `UINT16MAX` 는 소스 전체에서 이 정의 한 줄만 존재 | 삭제 |
| 5 | `:771-774`, `:733` | `buf_LRU_list` 주석의 garbage LRU 구획 설명과 `avoid_shared_lru_idx` 주석의 같은 표현 | shared + private 2구획 기준으로 교체 |
| 6 | `:637-641` | "LRU + Aout of 2Q" 주석이 AOUT 을 상시 동작으로 서술 | AOUT 이 현재 강제 비활성이라는 사실과 CBRD-20741 참조를 덧붙임 |
| 7 | `:10772` | `goto copy_unflushed_lsa` 의 레이블이 감싼 블록 바로 뒤(`:10776`)라 제어 흐름이 같다 | `goto` 삭제(직전 `iopage = NULL;` 은 유지) |
| 8 | `page_buffer.h:449-454` | `pgbuf_peek_stats` 선언 인자명이 정의(`page_buffer.c:14686-14691`)와 불일치 | 정의를 기준으로 통일하고, 12번 인자는 실제 값에 맞춰 이름 정정 |
| 9 | `page_buffer.h:320-326` | `pgbuf_fix_without_validation_release` 는 선언만 있고 정의가 소스 어디에도 없다. 감싸는 매크로 `pgbuf_fix_without_validation` 도 함께 죽어 있다 | 매크로와 선언 삭제 |

### 항목 2 - victim 탐색 주석과 실제 루프

    pgbuf_get_victim ()                                              :9022
      1. 자기 private LRU (quota 초과인 경우만)                       :9061
      2. 다른 private LRU (LFCQ 에서 리스트 인덱스를 꺼내 탐색)        :9106
      3. shared LRU                                                  :9150
         └ do { 3단계만 재시도 }                                     :9148-9164
              while (flush 데몬 없음
                     && shared_lrus_with_victims 큐가 비지 않음
                     && 소비 커서 진행량 <= num_LRU_list
                     && ++nloops <= num_LRU_list)
      4. 실패 시 자기 private LRU 재시도 (quota 미달이어도)            :9176
    ★ 주석(:9052)은 "victim_rich 인 동안 1~3 을 반복" 이라고 설명 — 그런 루프는 없다

`LFCQ` 는 victim 이 있는 LRU 리스트 인덱스만 담는 lock-free circular queue 로, 리스트 선택을 O(1)로 만드는 장치다. 재시도 루프가 shared 단계에만 있는 이유는 그 주석(`:9132-9140`)에 따로 적혀 있으므로, 항목 2 는 `:9048-9052` 문단만 지우거나 실제 조건으로 다시 쓰면 된다.

### 항목 8 - `pgbuf_peek_stats` 인자명 대조

호출부는 `perf_monitor.c:1976-1991` 한 곳이고, perfmon 카운터를 순서대로 넘긴다. 헤더와 정의, 실제 값이 어긋난 자리는 다음 세 개다.

| 인자 위치 | 헤더 선언 (`page_buffer.h:449-454`) | 정의 (`page_buffer.c:14686-14691`) | 실제로 채우는 값 | 대응 perfmon 카운터 |
|---|---|---|---|---|
| 6 | `vict_candidates` | `victim_candidates` | LRU 리스트별 `count_vict_cand` 합 (`:14754-14757`) | `PSTAT_PB_VICT_CAND` |
| 12 | `alloc_bcb_waiter_med` | `alloc_bcb_waiter_med` | `direct_victims.waiter_threads_low_priority->size ()` (`:14763`) | `PSTAT_PB_WAIT_THREADS_LOW_PRIO` |
| 13 | `alloc_bcb_waiter_low` | `flushed_bcbs_waiting_direct_assign` | `flushed_bcbs->size ()` (`:14764`) | `PSTAT_PB_FLUSHED_BCBS_WAIT_FOR_ASSIGN` |

12번은 헤더와 정의가 일치하지만 둘 다 값과 맞지 않는다. 대기 우선순위는 high 와 low 두 단계뿐이고 11번이 `alloc_bcb_waiter_high` 이므로, 12번은 `alloc_bcb_waiter_low` 로 바꾸는 것이 실제 값과 카운터 이름 모두에 맞는다. 13번은 정의 쪽 이름이 옳으니 헤더를 정의에 맞춘다.

### 항목 9 - 정의가 없는 `pgbuf_fix_without_validation`

`grep -rn 'fix_without_validation' src/` 는 헤더 세 줄만 반환한다. 매크로 정의(`page_buffer.h:320-323`)와 그 매크로가 가리키는 함수 선언(`:324-326`)뿐이고, 함수 본체는 어디에도 없다.

두 줄 모두 `#else /* NDEBUG */` 안, 즉 release 빌드에서만 보이는 구획에 있다. debug 빌드에는 짝이 되는 `_debug` 선언조차 없어서, 만약 누군가 `pgbuf_fix_without_validation` 을 쓰면 debug 빌드는 컴파일 단계에서, release 빌드는 링크 단계에서 서로 다르게 깨진다. 아무도 부르지 않은 덕에 지금까지 드러나지 않았다.

> **요지**: 9건 중 실제로 사람을 헷갈리게 하는 것은 주석 3건(항목 2, 5, 6)과 헤더 인자명 1건(항목 8)이다. 나머지 5건은 삭제로 끝난다.

### 커밋 분리와 병합 순서

정리 커밋에는 동작 변경을 섞지 않는다. 결함 수정 이슈가 나중에 문제를 일으켜 revert 될 때 이 정리까지 함께 되돌아가지 않게 하는 것이 분리 이유다.

항목 7 만 예외적으로 순서 제약이 있다. 삭제할 `goto` 가 `pgbuf_bcb_flush_with_wal` 안에 있고, 같은 함수의 TDE·DWB 조기 실패 경로(`:10755`, `:10767`)를 고치는 CBRD-27262 가 그 바로 위 줄들을 바꾼다. CBRD-27262 를 먼저 병합해야 충돌 없이 적용된다. `TDE` 는 data page 암호화, `DWB` 는 원래 위치에 쓰기 전 별도 파일에 사본을 기록하는 torn-write 보호 장치다.

## Acceptance Criteria

- [ ] 위 표 1~9 항목이 모두 반영된다. `page_buffer.c` 와 `page_buffer.h` 에서 `victim_rich`, `pgbuf_remove_private_from_aout_list`, `UINT16MAX`, `garbage` 검색 결과가 0건이고, `src/` 전체에서 `fix_without_validation` 검색 결과가 0건이다.

- [ ] `pgbuf_peek_stats` 의 헤더 선언과 정의 인자명이 완전히 일치하고, 12번 인자 이름이 실제로 채우는 low priority 대기 스레드 수와 맞다.

- [ ] 남은 주석이 현행 코드와 대조해 참이다 — victim 탐색 주석은 `:9148-9164` 의 실제 조건을, `buf_LRU_list` 주석은 shared + private 2구획을, AOUT 주석은 현재 비활성 상태를 서술한다.

- [ ] 동작 무변경을 확인한다: 같은 워크로드에서 `SHOW PAGE BUFFER STATUS` 19개 컬럼과 `PSTAT_PB_*` 카운터가 정리 전후로 동일한 의미를 유지하고, 시스템 파라미터 기본값과 디스크 형식이 그대로다.

## Definition of done

- [ ] 위 Acceptance Criteria 충족

- [ ] release 와 debug 두 빌드가 통과하고, `-DCUBRID_DEBUG` 관련 코드 경로를 건드리지 않았음을 확인한다

- [ ] QA 통과 (SQL 회귀와 medium 스위트)

- [ ] CBRD-27262 가 먼저 병합된 뒤에 항목 7 을 적용한다

- [ ] 문서/매뉴얼 반영 대상 없음을 커밋 메시지에 남긴다

## Remarks

이 이슈 범위에서 뺀 항목이 둘 있다.

- `pgbuf_peek_stats` 의 `lfcq_big_prv_num` / `lfcq_prv_num` 은 해당 LFCQ 포인터가 `NULL` 이면 대입되지 않고(`:14771-14779`), 진입부 초기화 목록(`:14697-14705`)에도 빠져 있다. 호출부가 미리 채워진 통계 배열의 슬롯을 넘기므로 스택 쓰레기가 출력되는 상황은 아니지만, 값을 채우는 수정은 동작 변경이라 big private victim queue 를 다루는 CBRD-27267 로 넘긴다. 두 값 모두 그 queue(`big_private_lrus_with_victims`, `private_lrus_with_victims`)의 크기라 소유 범위가 맞다.
- 소스에 남은 기존 TODO(`:599-601` victim hint 논리 의심, `:3368`, `:7050`, `:8692`, `:12107`)는 각각 판단이 필요한 항목이라 이 정리 대상이 아니다.

## 참고 코드

- `src/storage/page_buffer.c`, `src/storage/page_buffer.h` — 정리 대상
- `src/base/perf_monitor.c:1976-1991` — `pgbuf_peek_stats` 유일한 호출부
- `src/base/system_parameter.c:3494-3505`, `:10078` — `data_aout_ratio` 정의와 강제 비활성
- `CMakeLists.txt:613-617` — `-Wno-unused` 로 미사용 심볼 경고가 나오지 않는 이유
