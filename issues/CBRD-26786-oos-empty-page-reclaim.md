# [OOS] vacuum 의 OOS 빈 페이지 회수 — bestspace cache 한계 (cap 1000 / no eviction / no persistence) 보완

## Issue Triage

**이슈 수행 목적**: vacuum 이 OOS 슬롯을 모두 비운 페이지를 `file_dealloc` 로 OOS 파일에 반환해, bestspace cache 가 추적하지 못하는 빈 페이지를 file manager 의 partial sector table 에 영구 등록한다. 페이지 회수 후 `file_alloc` 가 그 sector 안에서 fresh page 를 재할당할 수 있어 OOS 파일의 확장 빈도가 줄어든다. 슬롯 단위 회수 (`oos_delete`, CBRD-26609 / CBRD-26668) 는 이 결정과 별개이며 그대로 동작한다.

**이슈 수행 이유**:

- **현재 동작 / 배경**:
  - 슬롯 회수: `oos_delete_chain` (`oos_file.cpp:1717`) 이 청크 슬롯을 비운 직후 `oos_stats_update` (`oos_file.cpp:1774`) 로 bestspace cache 에 free space 를 등록한다. CBRD-26609 / CBRD-26668 로 마무리.
  - bestspace cache 의 한계 — 코드로 확인된 사실 셋:
    - **용량 상한 1000**: `OOS_BESTSPACE_CACHE_CAPACITY` = 1000 (`oos_file.cpp:85`).
    - **No eviction**: `oos_stats_add_bestspace` (`oos_file.cpp:269`) 가 cap 도달 시 `num_stats_entries >= OOS_BESTSPACE_CACHE_CAPACITY` 조건에서 그냥 NULL 반환 (`oos_file.cpp:286-290`). 기존 entry 의 freespace 만 update 되고, 새 VPID 는 추가되지 않는다.
    - **No persistence**: `oos_Bestspace` 는 in-memory hash table (mht). `oos_bestspace_initialize` / `oos_bestspace_finalize` (`oos_file.cpp:183, 227`) 가 lifecycle 을 관리하고, 모든 entry 는 malloc 으로 만들어진다 (`oos_file.cpp:300`). server restart 시 cache 는 비워진다.
  - 페이지 단위 회수 부재: `oos_remove_page` (`oos_file.cpp:1007`, 헤더 `oos_file.hpp:80`) 가 `file_dealloc(... FILE_OOS)` 호출 본문을 가지고 있으나 caller 0 건. 바로 위 `oos_file.cpp:1005` 의 `TODO: will be called by vacuum when OOS vacuum is implemented` 주석이 미완 명시.
  - 본 이슈의 범위 밖 (참고): `file_perm_dealloc` (`file_manager.c:6315-6612`) 은 sector bitmap 비트만 clear 하고 partial table 갱신만 한다. `is_empty == true` 여도 `disk_unreserve_ordered_sectors` 를 호출하지 않으므로 sector 가 disk manager 로 반환되어 다른 파일이 가져가는 동작은 일어나지 않는다. 호출처는 `file_destroy` (`file_manager.c:4330`) 뿐. 즉 본 이슈가 줄여 주는 것은 OOS 파일의 **확장 빈도** 이지 OOS 파일이 점유한 sector 의 총량이 아니다.

- **영향** — 다섯 카테고리 중 두 곳에서 측정 가능한 손실이 발생한다:
  - **고객 장애**: 없음. 사용자 가시 SQL 동작은 영향 없음.
  - **QA 실패**: 없음 (현행). 단, 본 이슈가 도입되지 않으면 다수 OOS 파일을 가진 대규모 워크로드 회귀 테스트에서 OOS 파일 page count 누적이 더 두드러질 수 있어 향후 QA 시나리오 추가 시 노출될 수 있다.
  - **성능 저하**: 측정 가능한 저하 — bestspace 가 cap 1000 에 도달하거나 server restart 직후 cold 상태일 때 빈 OOS 페이지는 insert 경로에서 **invisible** 해진다. 결과적으로 다음 insert 가 `file_alloc` 를 통해 새 페이지를 요청하고, 이때 비어 있는 기존 페이지를 못 쓰고 파일을 확장하게 된다. 슬롯이 재사용 가능한데도 그렇다.
  - **설계 의도 훼손**: `oos_delete` header 주석 (`oos_file.cpp:1812-1813`) 의 "Empty pages will be reclaimed by vacuum after the transaction commits." 가 미완 상태로 남아 있다.
  - **기술 부채**: dead 함수 `oos_remove_page` 와 그 TODO 주석이 1 차 OOS 작업 (CBRD-26609) 이후 caller 없이 보존돼 있다. 본 이슈가 그 함수를 superset helper 로 교체한다.

**이슈 수행 방안**:

- 페이지 회수 mechanic 은 storage 레이어 helper 한 곳에 모은다 — `oos_try_reclaim_empty_page` 신설. 책임: in-use slot 검사 -> sticky first page 가드 -> `file_dealloc(... FILE_OOS)` -> bestspace cache 무효화 (`oos_stats_del_bestspace_by_vpid` 재사용).
- helper 호출 trigger 는 vacuum 두 경로 + SA_MODE eager 한 경로, 총 세 caller 의 batch boundary 에서 일괄 호출. `oos_delete` 의 inner per-OID loop 핫패스에는 검사 안 넣음.
- 기존 dead 함수 `oos_remove_page` 는 신설 helper 가 superset 이므로 삭제. 위 TODO 주석도 함께 정리.
- `oos_delete` header 주석 (`oos_file.cpp:1812-1813`) 은 본 이슈 PR 에서 "Reclaimed by vacuum via `oos_try_reclaim_empty_page`." 로 갱신.
- ANALYSIS 단계 first task: 실측 검증. bestspace cap 도달 / restart cold start 시나리오에서 OOS 파일 page count 가 본 helper 도입 전/후로 얼마나 차이 나는지를 CTP 회귀 테스트로 측정. `TBD - ANALYSIS 단계에서 결정` 항목들 (sysop 경계, batch 단위, container, recovery 호환성, idempotency) 은 본문 `## Open Design Questions` 의 후보안을 출발점으로 ANALYSIS 단계에서 확정.

상세 설계 결정 / 구현 / 트레이드오프는 아래 AI-Generated Context 섹션 참조.

---

## AI-Generated Context

> 아래 내용은 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 **Issue Triage** 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **문제 / 목적**: OOS 슬롯 회수 후 남는 빈 페이지가 bestspace cache 의 cap / persistence 한계로 invisible 해지면 다음 insert 가 파일을 불필요하게 확장한다. `file_dealloc` 로 file manager 의 partial sector table 에 영구 등록해 이 손실을 막는다.
- **원인 / 배경**: bestspace 는 cap 1000, no eviction, no persistence 의 in-memory MHT cache. 슬롯 회수는 `oos_delete` 가 처리하지만 페이지 회수는 caller 0 건의 미연결 helper (`oos_remove_page`) 로 방치돼 있다.
- **제안 / 변경**: storage 레이어 helper (`oos_try_reclaim_empty_page`) 신설 + vacuum 두 경로 + SA_MODE eager 경로 총 세 caller 의 batch boundary 에서 호출. 기존 `oos_remove_page` 와 TODO 주석은 정리.
- **영향 범위**: `src/storage/oos_file.{cpp,hpp}`, `src/query/vacuum.c`, `src/storage/heap_file.c`. 사용자 가시 호환성 영향 없음. WAL 호환성 영향 없음 (기존 `RVFL_DEALLOC` postpone 재사용).

---

## Description

### 발단 — 1 차 draft 의 motivation 수정 경위

1 차 draft 의 motivation 두 줄 ("다른 OOS 파일로의 페이지 재할당", "OOS 파일 page count 단조 누적") 은 코드 사실관계와 맞지 않다는 리뷰어 지적을 받았다. 검증 결과:

- "다른 파일로 재할당" 부분은 `file_perm_dealloc` 가 sector 를 disk manager 로 반환하지 않으므로 (`file_manager.c:6315-6612`, 호출처는 `file_destroy` 의 `file_manager.c:4330` 뿐) 본 이슈 구현 후에도 그대로 불가능하다. heap 의 sequential scan 처럼 빈 페이지가 비용을 키우는 모델 (`heap_remove_page_on_vacuum`, `heap_file.c:4716`) 도 OOS 엔 적용되지 않는다 — OOS read 는 OOS OID 의 (volid, pageid) 로의 point-access 만 한다 (`oos_read` -> `oos_read_within_page`, `oos_file.cpp:1406, 1347`; 다중 청크는 `oos_read_across_pages`, `oos_file.cpp:1279`).
- "page count 단조 누적" 부분은 bestspace 가 hit 상태일 때는 같은 OOS 파일 안에서 슬롯 / 페이지 재사용이 일어나 page count 가 일정 수준에서 안정화된다. 따라서 무조건 누적은 아니다.

하지만 bestspace cache 자체의 한계를 코드로 들여다보면 새 motivation 이 나온다.

### Bestspace cache 한계 — 코드 인용

```c
// oos_file.cpp:85
#define OOS_BESTSPACE_CACHE_CAPACITY 1000

// oos_file.cpp:286-290 (oos_stats_add_bestspace 내부)
if (oos_Bestspace->num_stats_entries >= OOS_BESTSPACE_CACHE_CAPACITY)
{
    pthread_mutex_unlock (&oos_Bestspace->bestspace_mutex);
    return NULL;
}
```

- 1000 은 **모든 OOS 파일 합산** 으로 hash table 에 들어가는 (VFID, VPID) entry 의 총 상한이다. 한 인스턴스에 OOS 컬럼을 가진 테이블이 여럿이고 각각의 빈 슬롯을 가진 페이지가 누적되면 도달 가능한 수치.
- cap 도달 시 새 VPID 는 `mht_put` 까지 가지 않고 함수가 NULL 반환으로 끝난다. 기존 entry 의 `freespace` 만 update 가능 (`oos_file.cpp:278-284`). 한 번 invisible 해진 VPID 는 다시 등록될 기회가 없다.
- entry 저장소는 `oos_Bestspace_cache_area` 의 mht 두 개 (`vpid_ht`, `vfid_ht`) + malloc 된 free list. 모두 메모리. `oos_bestspace_initialize` / `oos_bestspace_finalize` 사이의 lifetime 안에서만 유효 (`oos_file.cpp:183-263`).
- server 재기동 시 cache 가 비워지므로 그동안 누적된 dead-slot 페이지의 free space 정보는 file system 어디에도 남지 않는다.

### Stranded-page 시나리오

위 한계가 작동하는 구체 시나리오:

1. **Cap-bound stranded**: OOS 컬럼이 있는 테이블이 다수이고 각각의 OOS 파일이 여러 dead-slot 페이지를 가진 상태. 1000 번째 (VFID, VPID) 가 등록된 이후의 신규 dead-slot 페이지는 bestspace 에 들어가지 못한다. 다음 insert 는 그 페이지에 free space 가 있는지 모르므로 `file_alloc` 로 새 페이지를 요청하고, 빈 페이지는 그 자리에 그대로 남는다.
2. **Restart-cold stranded**: server 재기동 직후 cache 는 비었지만 OOS 파일들 안엔 dead-slot 페이지가 그대로 매달려 있다. cache 는 page lookup 시 lazy 하게 populate 되지만 populate 가 안 일어난 페이지는 invisible 상태로 남는다.

두 시나리오 모두 슬롯 회수 (`oos_delete`) 가 이미 끝난 페이지가 insert 경로에서 보이지 않게 되는 손실이다.

### File manager 의 partial sector table 이 보완책인 이유

`file_perm_dealloc` (`file_manager.c:6315-6612`) 가 한 페이지를 회수할 때 하는 일은 sector bitmap 의 페이지 비트 clear (`file_manager.c:6376`, `file_partsect_clear_bit`) + sector 가 was_full 이면 full table 에서 partial table 로 이동 (`file_manager.c:6402-` else branch) + 파일 헤더 통계 갱신 (`file_manager.c:6580`, `file_header_dealloc`).

partial sector table 은 OOS 파일 헤더 페이지에 영구화돼 있고 `file_alloc` 진입점이 그 테이블에서 free page 를 찾는다. bestspace 와 달리 cap 도 없고 restart 후에도 살아남는다. 즉 본 이슈의 helper 가 `file_dealloc` 까지 마치면 회수된 페이지는 bestspace 가 어떤 상태든 다음 `file_alloc` 가 partial sector table 로부터 fresh page 로 즉시 재사용할 수 있다.

이 효과는 OOS 파일의 disk 사용량을 직접 줄이지는 않는다 (sector 는 그 파일에 묶인 채로 남는다). 줄이는 것은 **확장 빈도** — 새 데이터를 받기 위해 disk manager 에서 새 sector 를 reserve 받을 빈도가 감소한다.

### 영향 받지 않는 경로

- DROP TABLE 의 OOS 파일 통째 reclaim 경로는 본 이슈와 무관. `xheap_destroy` (`heap_file.c:5921`) 가 `oos_remove_file` (`oos_file.cpp:994-1003`) 를 호출하고 `oos_remove_file` 가 `file_postpone_destroy` 로 위임 (`oos_file.cpp:1000`). 파일 단위 reclaim 은 이미 구현.
- REC_BIGONE + OOS 의 경우는 vacuum 측 invariant (`assert (!heap_recdes_contains_oos (&helper->record))`, `vacuum.c:2589`) 로 막혀 있어 본 이슈 범위 밖.
- `RVVAC_NOTIFY_DROPPED_FILE` 게이트와 OOS 처리의 상호작용은 검증된 상태. REMOVE 경로는 `vacuum_collect_heap_objects` (`vacuum.c:3671`) 로 큐잉되고 forward-walk 진입점도 같은 dropped-file 게이트 (`vacuum.c:3643`) 의 하류에 있어 별도 조치 불필요.

### 책임 분리 결정

| 책임 | 위치 | 이유 |
|---|---|---|
| mechanic (빈 페이지 판정 + dealloc + cache 무효화) | storage 레이어 (`oos_file.cpp`) | 페이지 헤더 레이아웃, sticky first-page 체크, bestspace cache 무효화 — 모두 storage 내부 지식. caller 가 storage 내부 구조를 모르고도 정확히 호출하도록 한 군데로 가둔다. |
| trigger (언제 검사할지) | caller (vacuum 2 + SA_MODE eager 1) | `oos_delete` 의 inner per-OID 루프에 검사를 넣으면 O(deleted OIDs) 비용이지만 caller batch boundary 에서 한 번 호출하면 O(touched pages) 로 줄어든다. `file_dealloc` 가 fhead 페이지를 fix 하므로 inner loop 안 호출 시 chunk-삭제와 page-회수의 latch 보유 구간이 겹치는 문제도 회피. |

---

## Open Design Questions

ANALYSIS 단계에서 확정할 결정들. 각 항목은 후보안과 트레이드오프를 정리.

### Q1. `file_dealloc` postpone 의 vacuum worker transaction 모델 호환성

`file_dealloc` 의 permanent file 분기는 `RVFL_DEALLOC` postpone record 만 등록하고 (`file_manager.c:6186`, `log_append_postpone`), 실제 dealloc 은 run-postpone 시점에 `file_perm_dealloc` 가 한다. 따라서 "sysop 안/밖" 의 결정은 부분적으로 postpone 메커니즘이 이미 답을 정한다. 남는 질문:

- vacuum worker 의 outer transaction / sysop 종료 시점에 그 postpone 이 정상 run 되는지 (`log_sysop_attach_to_outer` / `log_sysop_end_logical_run_postpone`, `log_manager.c:4015, 4109` 부근).
- SA_MODE crash 후 recovery 가 vacuum 의 postpone 와 충돌하지 않는지.
- `FILE_OOS` 자체의 `RVFL_DEALLOC` recovery 분기가 다른 file type 과 동일하게 동작하는지 (`FILE_OOS` 가 비교적 신규 file type 이라 검증 안 된 분기 가능성).

**잠정 권고**: ANALYSIS 단계에서 위 세 항목을 코드 inspection + crash injection 으로 확인.

### Q2. helper 호출 batch 단위

언제 helper 를 호출할지. 너무 자주면 페이지 fix 가 잦고, 너무 늦으면 페이지가 빈 채로 살아 있는 시간이 길어진다.

| 후보안 | 동작 | 장점 | 단점 |
|---|---|---|---|
| **A. per-record** | 한 dead heap record (vacuum) / 한 UPDATE context (SA_MODE) 의 OOS OID 들을 모두 처리한 직후 helper 호출. | 회수 latency 짧음. caller 코드 변경 작음. | 한 record 의 OOS OID 가 여러 페이지에 걸치면 record 마다 여러 번 호출. |
| **B. per-page** (vacuum 의 heap page 단위) | vacuum 의 한 heap page 처리 종료 시점에 그 page 내 모든 dead record 의 touched VPID 를 모아 helper 호출. | 호출 빈도 amortize. 같은 OOS 파일의 여러 record 가 같은 OOS 페이지 touch 시 dedup. | SA_MODE 엔 적용 불가 (heap-page 단위 batch 가 없음). |
| **C. per-block** (vacuum log block) | vacuum 의 한 log block 처리 끝에 한 번. | 호출 빈도 최소. | latency 가 block 처리 시간만큼 늘어남. SA_MODE 엔 무의미. |

**잠정 권고**: vacuum 두 caller 는 **A** 시작 후 측정 결과에 따라 B 로 격상 검토. SA_MODE eager 는 **A (per-UPDATE)** 고정.

### Q3. touched VPID 집합 컨테이너

| 후보안 | 장점 | 단점 |
|---|---|---|
| **A. `std::set<VPID>`** | 자동 정렬 + 자동 dedup. 코드 단순. | 노드 단위 할당 — small-N 에서 오버헤드. |
| **B. `std::unordered_set<VPID>`** | O(1) 삽입/조회. | hasher 필요. small-N 에서 hash table overhead. |
| **C. `std::vector<VPID>` + 호출 직전 sort + unique** | 메모리 locality. small-N 에 최적. | 호출 직전 정렬/dedup 비용. dedup 누락 시 같은 VPID 두 번 호출. |

**잠정 권고**: **C**. 한 record/page 의 touched VPID 수는 실측상 한 자릿수 ~ 수십 개 예상.

### Q4. helper idempotency

vacuum worker 가 helper 호출 도중 크래시 후 재기동되면 다음 worker 가 같은 블록을 재처리한다 (`VACUUM_BLOCK_FLAG_INTERRUPTED`). 다음 케이스를 NO_ERROR 로 흡수해야 한다.

- 이미 dealloc 된 VPID — `file_dealloc` 의 동작 (NO_ERROR / error / assert) 을 코드로 확인 후 helper 가 그 케이스를 흡수.
- 동시 insert 가 빈 페이지를 재점유한 경우 — helper 가 in-use slot > 0 검사로 dealloc 건너뜀.
- sticky first page 강제 호출 — `file_get_sticky_first_page` (`file_manager.c:5786`) 로 확인 후 NO_ERROR 로 빠져나감.

### Q5. ANALYSIS 단계의 실측 검증 시나리오

본 이슈의 motivation 자체가 "bestspace 한계가 실제 워크로드에서 빈 페이지를 stranded 시키는가" 에 달려 있다. 다음 시나리오 측정 후 결과에 따라 본 이슈 진행 / 보류 / 재설계 결정.

- 시나리오 1 (cap-bound): OOS 컬럼이 있는 테이블 N 개 (N 값은 ANALYSIS 단계에서 결정) 에 대해 대량 insert / delete 사이클 반복. bestspace 의 `num_stats_entries` 가 1000 에 도달하는 지점부터 OOS 파일 page count 증가 추이를 helper 도입 전/후로 비교.
- 시나리오 2 (restart-cold): 대량 delete 후 server 재기동. 재기동 직후 insert workload 의 OOS 파일 확장 빈도를 helper 도입 전/후로 비교.
- 시나리오 3 (UPDATE-heavy): 한 row 를 N 번 UPDATE 하여 옛 OOS OID 가 누적되는 경로 — SA_MODE eager + forward-walk 양쪽.

측정 결과 helper 도입 효과가 통계상 유의미하지 않으면 본 이슈는 보류 (Won't Fix) 로 변경하고 dead 함수 `oos_remove_page` 정리만 minor 패치로 처리한다.

---

## Specification Changes

사용자 가시 스펙 변경 없음. 내부 storage 관리 동작만 변경.

성능 특성:

- bestspace cap 도달 / restart cold 상태에서 OOS 파일 확장 빈도 감소 (예상). 정량 측정은 Q5 의 ANALYSIS 단계 시나리오로 확인.
- vacuum 워커당 추가 비용: touched VPID 집합 유지 + record 처리 종료 시점의 helper 호출. 한 record 의 OOS OID 들은 보통 같은 페이지에 몰려 있어 집합 크기는 작다.

---

## Implementation

### 신규 함수

| 함수 | 파일 | 책임 |
|---|---|---|
| `oos_try_reclaim_empty_page` | `oos_file.cpp` | `oos_vfid` 안의 한 VPID 가 빈 페이지인지 판정 후 `file_dealloc` + bestspace cache 무효화 (`oos_stats_del_bestspace_by_vpid` 재사용). Idempotent. |

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
2. 루프 동안 touched VPID 집합을 caller 컨텍스트에 누적 (Q3 잠정 권고: vector + sort/unique).
3. 루프 종료 후 집합을 순회하며 oos_try_reclaim_empty_page 호출 (Q2 잠정 권고: per-record).
4. helper 실패는 warning 으로 기록하고 vacuum 진행을 막지 않는다 — 회수 실패는 다음 vacuum 사이클의 후보로 남으면 충분.
```

대상:

- `vacuum_heap_oos_delete` (`vacuum.c:2419`) — dead heap 레코드 처리 종료 시점.
- `vacuum_forward_walk_delete_old_oos` (`vacuum.c:3458`) — `RVHF_UPDATE_NOTIFY_VACUUM` log record 처리 종료 시점.
- `heap_update_home_delete_replaced_oos` (`heap_file.c:24131`, oos_delete 루프 `heap_file.c:24178`) — UPDATE 의 옛 OID 회수 종료 시점.

### Header page 예외

OOS 파일의 첫 페이지는 sticky first page 로 마킹돼 있다 (`file_alloc_sticky_first_page`, `oos_file.cpp:940`). `file_manager.c:123` 의 `vpid_sticky_first` 필드 주석은 "This page should never be deallocated." 명시. helper 는 dealloc 전에 `file_get_sticky_first_page` (`file_manager.c:5786`) 로 sticky first VPID 를 읽어 일치하면 NO_ERROR 로 빠져나간다. `file_dealloc` 자체에도 sticky-first dealloc 시 assert 가 있으나 (`file_manager.c:6178`) dev 빌드 전용이라 release 빌드 가드를 위해 helper 에서 한 번 더 검사.

### `oos_remove_page` 처분

기존 `oos_remove_page` (`oos_file.cpp:1007`) 와 `oos_file.hpp:80` 의 선언은 본 이슈 helper 가 sticky-first 가드 + in-use slot 검사 + bestspace cache 무효화 superset 이므로 삭제. `oos_file.cpp:1005` 의 TODO 주석도 함께 제거. `oos_delete` header 주석 (`oos_file.cpp:1812-1813`) 은 "Reclaimed by vacuum via `oos_try_reclaim_empty_page`." 로 갱신.

### 동시 insert race

동시 insert 가 빈 페이지를 재점유한 경우 helper 는 in-use slot > 0 검사로 dealloc 를 건너뛴다. 정상 동작이며, 그 페이지는 다음 vacuum batch 의 회수 후보로 남는다.

---

## Acceptance Criteria

- [ ] **(ANALYSIS gate)** Q5 의 시나리오 1/2/3 중 적어도 하나에서 helper 도입 전/후의 OOS 파일 page count 또는 확장 빈도가 통계상 유의미하게 (시나리오 정의 시 임계치 합의) 다르다. 유의미하지 않으면 본 이슈를 Won't Fix 로 close 하고 dead 함수 정리만 별도 minor 패치로 처리.
- [ ] `oos_try_reclaim_empty_page` 가 `oos_file.cpp` 에 추가된다.
- [ ] helper 가 sticky first page 를 dealloc 하지 않는다 (강제 호출 시 NO_ERROR 로 빠져나간다).
- [ ] helper 가 idempotent 하다 (이미 dealloc 된 페이지에 대해 NO_ERROR 반환).
- [ ] helper 의 in-use slot 검사 결과 > 0 이면 `file_dealloc` 을 호출하지 않는다.
- [ ] `vacuum_heap_oos_delete`, `vacuum_forward_walk_delete_old_oos`, `heap_update_home_delete_replaced_oos` 세 경로에서 touched VPID 추적 + helper 호출이 이뤄진다.
- [ ] bestspace cache entry 가 dealloc 된 페이지에 대해 자동으로 제거된다 (helper 가 `oos_stats_del_bestspace_by_vpid` 호출).
- [ ] 기존 dead 함수 `oos_remove_page` + 헤더 선언 + `oos_file.cpp:1005` TODO 주석이 삭제된다. `oos_delete` header 주석 (`oos_file.cpp:1812-1813`) 이 helper 이름으로 갱신된다.
- [ ] 10000-row insert + 10000-row delete 사이클을 5 회 반복 후 OOS 파일 페이지 수가 첫 사이클 종료 시점 대비 +-10% 이내 (insert/delete heavy 회귀).
- [ ] OOS 페이로드가 페이지당 N 개 들어가는 크기일 때, 동일 row 를 10000 회 UPDATE 후 vacuum 완료 시점에서 OOS 파일 페이지 수가 `ceil(10000/N) * 2` 페이지 이하 (UPDATE heavy 회귀, forward-walk + SA_MODE eager 양쪽).
- [ ] vacuum 워커가 helper 호출 도중 크래시 후 재기동되어도 같은 블록을 재처리해 안전하게 회수.
- [ ] 동시 워크로드 CTP: 10000-row delete 트랜잭션 commit 직후 vacuum 처리와 동시에 별 세션에서 10000-row insert 실행. 모든 세션 종료 후 `SELECT COUNT(*)` 결과가 일관되고 `ER_` 로그 0 건.
- [ ] 기존 CI (`test_sql`, `test_medium`) 통과.

---

## Definition of done

- [ ] 위 A/C 충족.
- [ ] Q1-Q5 가 ANALYSIS 단계에서 모두 결정 (각 Q 의 잠정 권고를 출발점으로 검증).
- [ ] CTP 회귀 테스트 추가 (OOS 파일 페이지 수 추이 측정 시나리오, Q5 시나리오 1/2/3 기반).
- [ ] QA 통과.

---

## 참고 코드

- `oos_file.cpp:85` — `OOS_BESTSPACE_CACHE_CAPACITY` 정의 (1000)
- `oos_file.cpp:269-333` — `oos_stats_add_bestspace`, cap 도달 NULL 반환 로직
- `oos_file.cpp:183-263` — bestspace lifecycle (`oos_bestspace_initialize` / `oos_bestspace_finalize`)
- `oos_file.cpp:1717, 1774` — `oos_delete_chain` + `oos_stats_update` (슬롯 회수, 본 이슈 unaffected)
- `oos_file.cpp:1005-1017` — dead 함수 `oos_remove_page` 와 TODO 주석 (본 이슈에서 정리)
- `oos_file.cpp:1812-1813` — `oos_delete` header 주석 (본 이슈에서 갱신)
- `oos_file.cpp:1279, 1347, 1406` — OOS read 의 point-access 경로 (scan 모델 부재 근거)
- `oos_file.cpp:940` — sticky first page 마킹
- `file_manager.c:5786` — `file_get_sticky_first_page` (helper 의 sticky 가드)
- `file_manager.c:6122, 6186` — `file_dealloc` 진입점 + `RVFL_DEALLOC` postpone 등록
- `file_manager.c:6315-6612` — `file_perm_dealloc` (partial sector table 갱신, `disk_unreserve_ordered_sectors` 미호출 근거)
- `file_manager.c:3890, 4330` — `disk_unreserve_ordered_sectors` 의 두 호출처 (3890 = temp rollback, 4330 = `file_destroy`)
- `vacuum.c:2419, 3458` — vacuum 의 두 OOS 회수 진입점 (helper caller 후보)
- `heap_file.c:24131, 24178` — SA_MODE eager 회수 (`heap_update_home_delete_replaced_oos`)
- `heap_file.c:4716` — `heap_remove_page_on_vacuum` (heap 의 chain 갱신 대조 사례, OOS 와 무관)

---

## Remarks

- 선행 / 관련 이슈:
  - CBRD-26609 — `oos_delete` API 도입. 슬롯 단위 회수가 여기서 마무리됨.
  - CBRD-26668 — vacuum OOS 통합 (forward-walk + REMOVE path). vacuum 이 `oos_delete` 를 호출하는 경로가 여기서 연결됨. 본 이슈는 그 위에 페이지 회수 단계를 추가.
  - CBRD-26715 — vacuum OOS 거짓 양성 (본 이슈 진행 시 진단 로그 재사용 가능).
  - CBRD-26608 — DROP TABLE 의 OOS cleanup (파일 단위 reclaim, 본 이슈와 별개).
  - CBRD-26583 — OOS M2 epic (parent). 본 이슈 완료 후 OOS page lifecycle (insert -> delete -> page reclaim -> file reclaim) 이 완성됨.
- 본 이슈 motivation 의 핵심 가정 — bestspace cap / persistence 한계가 실제 워크로드에서 빈 페이지 stranding 을 의미 있게 만든다 — 은 Q5 의 ANALYSIS 단계 실측으로만 확인 가능하다. 측정 결과 효과가 미미하면 본 이슈는 Won't Fix 로 close 한다.
- 향후 disk manager 가 sector-level reclaim (`file_destroy` 외 경로에서 `disk_unreserve_ordered_sectors` 호출) 을 지원하면 본 helper 의 효과가 "확장 빈도 감소" 에서 "OOS 파일 disk 사용량 감소" 로 확장된다. 그 시점에 본 이슈의 후속 작업이 별도 이슈로 열린다.
