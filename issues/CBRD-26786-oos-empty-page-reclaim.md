# [OOS/VACUUM] vacuum의 OOS 슬롯 삭제 후 빈 페이지 회수

## Issue Triage

> **이슈 수행 목적**: vacuum 이 OOS 슬롯을 모두 비운 페이지를 `file_dealloc` 으로 OOS 파일에 반환하여, 삭제 비중이 큰 워크로드에서 OOS 파일 크기가 단조 증가하지 않도록 한다.
>
> **이슈 수행 이유**:
> - **현재 동작 / 배경**: `oos_delete` (`src/storage/oos_file.cpp:1816`) 는 `oos_delete_chain` 내부에서 `spage_delete` 로 슬롯만 비우고 `oos_stats_update` (`oos_file.cpp:1774`) 로 bestspace 캐시의 free space 만 갱신한다. 페이지에 슬롯이 0개가 되어도 `file_dealloc(... FILE_OOS)` 를 호출하지 않는다. `oos_remove_page` (`oos_file.cpp:1007`) 는 stub 으로 정의만 되어 있고 호출자가 0건이며, 그 위 5줄 TODO 주석은 "will be called by vacuum when OOS vacuum is implemented" 라고 명시한다. `oos_delete` 자체의 header 주석 (`oos_file.cpp:1812-1813`) 도 "Page deallocation is NOT done here. Empty pages will be reclaimed by vacuum after the transaction commits." 라고 책임을 vacuum 으로 미뤄두었다.
> - **영향**: 설계 의도 훼손 + 운영상 스토리지 증가. 슬롯 단위 재사용 (`oos_stats_update` 가 bestspace 에 free space 등록) 은 동작하지만 페이지 자체가 파일에 매달려 있어 다른 파일로 재할당되지 않는다. delete/update 비중이 큰 OOS 워크로드에서 OOS 파일이 단조 증가한다. 현재까지의 OOS 코어 작업 (CBRD-26609 `oos_delete` 도입, CBRD-26668 vacuum 통합) 이 마무리되었으므로 누락된 마지막 회수 단계만 남았다.
>
> **이슈 수행 방안**:
> - mechanic 은 storage 레이어에 helper 로 둔다 — `oos_file.cpp` 에 빈 페이지 판정 + `file_dealloc` + bestspace 캐시 무효화를 묶은 `oos_try_reclaim_empty_page (thread_p, vfid, vpid)` 를 신설한다. Header page 보호 + idempotent 동작 + 동시 insert 와의 안전성은 helper 내부 책임으로 봉인한다.
> - trigger 는 caller 쪽 batch boundary 에서 일괄 호출한다 — `vacuum_heap_oos_delete` (`vacuum.c:2419`), `vacuum_forward_walk_delete_old_oos` (`vacuum.c:3458`), SA_MODE eager cleanup (`heap_file.c:24178`) 세 caller 가 touched VPID 집합을 들고 있다가 마지막에 한 번 helper 를 호출한다. `oos_delete` 의 inner loop 핫패스에는 검사를 넣지 않는다.
> - bestspace 캐시 일관성을 위해 `oos_stats_del_bestspace_by_vpid` 가 신규로 필요한지 검토하고 필요시 추가한다 (현재는 `oos_stats_del_bestspace_by_vfid` 만 존재, `oos_file.cpp:998`).
> - REC_BIGONE 와 OOS 가 공존하지 않는다는 기존 invariant (`vacuum.c:2589` 의 `assert (!heap_recdes_contains_oos (&helper->record))`) 는 본 이슈 범위 밖이며 그대로 둔다.
> - 회귀 테스트: insert/delete heavy 워크로드 + UPDATE heavy 워크로드 각각에서 OOS 파일 페이지 수 추이를 측정해 단조 증가가 멈추는지 확인한다. SA_MODE 경로도 동일 시나리오로 검증한다.
> - `file_dealloc` 을 vacuum 의 기존 sysop 경계 (`vacuum.c:2494` `log_sysop_start`, `vacuum.c:3471` 등) 안에 두는 것이 안전한지: `TBD - ANALYSIS 단계에서 결정`.
> - 빈 페이지 검사를 per-record / per-page / per-block 중 어느 batch 단위에서 돌릴지: `TBD - ANALYSIS 단계에서 결정`.

---

## AI-Generated Context

> 아래 내용은 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 **Issue Triage** 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **문제 / 목적**: vacuum 이 OOS 슬롯을 다 비운 페이지를 OOS 파일에 반환하지 못하고 있어, 파일 크기가 단조 증가한다. 빈 페이지를 `file_dealloc` 으로 반환한다.
- **원인 / 배경**: `oos_delete` 의 design intent 는 페이지 회수를 vacuum 으로 미루는 것이었으나, 정작 vacuum 쪽 호출자 (`vacuum_heap_oos_delete`, `vacuum_forward_walk_delete_old_oos`) 에 회수 호출이 빠져있고 `oos_remove_page` stub 은 caller 0건이다.
- **제안 / 변경**: storage 레이어 helper (`oos_try_reclaim_empty_page`) 신설 + 세 caller (vacuum 2개 + SA_MODE eager 1개) 에서 batch boundary 호출. bestspace 캐시 일관성 처리 + header page 예외 + transactional safety 검토 동반.
- **영향 범위**: `src/storage/oos_file.{cpp,hpp}`, `src/query/vacuum.c` (`vacuum_heap_oos_delete`, `vacuum_forward_walk_delete_old_oos`), `src/storage/heap_file.c` (SA_MODE eager cleanup 경로). 사용자 호환성 영향 없음 (내부 storage 관리만 변경).

---

## Description

### 배경

OOS 마일스톤 1 에서 `oos_delete` (CBRD-26609) 가 도입되어 슬롯 단위 물리 삭제가 가능해졌고, CBRD-26668 에서 vacuum 통합이 마무리되었다. 현재 vacuum 워커는 MVCC 가 dead 로 판정한 heap 레코드의 OOS OID 들을 다음 세 경로에서 `oos_delete` 로 회수한다.

| 경로 | 위치 | 트리거 |
|---|---|---|
| `vacuum_heap_oos_delete` | `vacuum.c:2419` | 죽은 heap 슬롯의 OOS OID 회수 (REMOVE path) |
| `vacuum_forward_walk_delete_old_oos` | `vacuum.c:3458` | `RVHF_UPDATE_NOTIFY_VACUUM` 의 pre-image OOS OID 회수 (UPDATE 로 교체된 옛 OID) |
| SA_MODE eager cleanup | `heap_file.c:24178` | SA_MODE 에서 UPDATE 직후 옛 OOS OID 즉시 회수 |

세 경로 모두 슬롯만 비우고 페이지는 그대로 둔다. `oos_delete_chain` (`oos_file.cpp:1717`) 의 chunk 삭제 루프 내부에서 `oos_stats_update` 를 호출해 bestspace 캐시에 free space 만 등록한다 (`oos_file.cpp:1774`). 다른 OOS insert 가 같은 페이지에 들어오면 슬롯은 재사용되지만, 모든 슬롯이 비어도 페이지는 파일에 매달려 있다.

### 책임 분리 결정

본 이슈에서는 mechanic / trigger 두 책임을 분리한다.

| 책임 | 위치 | 이유 |
|---|---|---|
| mechanic (빈 페이지 판정 + dealloc + cache 무효화) | storage 레이어 (`oos_file.cpp`) | 페이지 헤더 / 슬롯 회계 / bestspace 캐시 모두 storage 내부 지식. 세 caller 가 공유해야 중복이 안 생긴다. |
| trigger (언제 검사할지) | caller (vacuum 2 + SA_MODE eager 1) | `oos_delete` 의 inner per-OID 루프에 검사를 넣으면 O(deleted OIDs) 비용이 되고 이미 열린 sysop 의 경계 의미가 바뀐다. caller 쪽 batch boundary 에서 한 번 호출하면 O(touched pages). |

`oos_delete` 의 header 주석 (`oos_file.cpp:1812-1813`) 이 이미 "Empty pages will be reclaimed by vacuum after the transaction commits." 라고 design intent 를 못박아두었으므로, 본 이슈는 그 미완 부분을 마저 채우는 작업이다.

### 영향 받지 않는 경로

- DROP TABLE 의 OOS 파일 통째 reclaim 경로 (`xheap_destroy` -> `oos_remove_file` -> `file_postpone_destroy`, `oos_file.cpp:1000`) 는 본 이슈와 무관하다. 파일 단위 reclaim 은 이미 구현되어 있다.
- REC_BIGONE + OOS 의 경우는 `vacuum.c:2589` 에서 invariant 로 막아둔 상태 (`assert (!heap_recdes_contains_oos (&helper->record))`) 이므로 본 이슈 범위 밖이다.
- `RVVAC_NOTIFY_DROPPED_FILE` 게이트와 OOS 처리의 상호작용은 검증된 상태다 (heap VFID 게이트가 OOS forward-walk / REMOVE 진입점보다 상류, `vacuum.c:3643`). 별도 조치 불필요.

---

## Specification Changes

사용자 가시 스펙 변경 없음. 내부 storage 관리 동작만 변경된다.

성능 특성 변화:
- OOS 파일 크기가 delete/update heavy 워크로드에서 더 이상 단조 증가하지 않는다.
- vacuum 워커당 추가 비용: touched VPID 집합 (`std::set<VPID>` 정도) 유지 + record 처리 종료 시점에 set 크기만큼 helper 호출. 한 record 의 OOS OID 들은 보통 같은 페이지에 몰려있어 set 크기는 작다.

---

## Implementation

### 신규 함수

| 함수 | 파일 | 책임 |
|---|---|---|
| `oos_try_reclaim_empty_page` | `oos_file.cpp` | 한 VPID 가 빈 페이지인지 판정 후 `file_dealloc` + bestspace 캐시 무효화. Idempotent. |
| `oos_stats_del_bestspace_by_vpid` (조건부) | `oos_file.cpp` | 단일 VPID 의 bestspace 엔트리 제거. 현재 `oos_stats_del_bestspace_by_vfid` 만 있어 단일 페이지 무효화 helper 필요 여부 검토 후 추가. |

helper 시그니처 초안:

```cpp
// 빈 페이지면 dealloc + bestspace 무효화. 이미 dealloc 된 경우 NO_ERROR.
// header page (slotid=0 이 존재) 는 절대 dealloc 하지 않는다.
int oos_try_reclaim_empty_page (THREAD_ENTRY *thread_p, const VFID &oos_vfid, const VPID &vpid);
```

### Caller 변경

세 caller 모두 동일 패턴:

```
1. 기존 oos_delete 루프를 그대로 둔다.
2. 루프 동안 touched VPID 집합을 worker stack 의 std::set<VPID> 에 누적한다.
3. 루프 종료 후 set 을 순회하며 oos_try_reclaim_empty_page 를 호출한다.
4. helper 실패는 warning 으로 처리하고 vacuum 진행은 막지 않는다 (CI 안전 마진).
```

대상:
- `vacuum_heap_oos_delete` (`vacuum.c:2419`) — 한 dead heap 레코드 처리 종료 시점
- `vacuum_forward_walk_delete_old_oos` (`vacuum.c:3458`) — 한 `RVHF_UPDATE_NOTIFY_VACUUM` log record 처리 종료 시점
- SA_MODE eager cleanup (`heap_file.c:24178`) — 한 UPDATE 의 옛 OID 회수 종료 시점

### 동시성 / Transactional 안전성

- **동시 insert 와의 경쟁**: helper 가 페이지를 fix 한 상태에서 슬롯 카운트를 검사하고 같은 latch 구간에서 `file_dealloc` 을 호출해야 한다. 검사 후 latch 해제 -> 다른 트랜잭션 insert -> dealloc 의 race 를 방지해야 한다. 구체 latch 경계는 ANALYSIS 단계에서 확정한다.
- **vacuum sysop 와의 관계**: vacuum 의 caller 들은 이미 `log_sysop_start` 안에서 동작한다 (예: `vacuum.c:2494`, `vacuum.c:3471`). `file_dealloc` 을 같은 sysop 안에서 호출해도 되는지, 아니면 sysop commit 후 별도 boundary 로 묶어야 하는지 검토가 필요하다. `file_dealloc` 의 postpone 메커니즘이 이미 commit boundary 에서 작동한다면 sysop 내 호출도 안전할 가능성이 높다.
- **SA_MODE 의 트랜잭션 진행 중 호출**: SA_MODE eager 경로는 트랜잭션이 아직 active 인 상태에서 호출된다. 트랜잭션 abort 시 dealloc 가 undo 되어야 일관성이 유지되는데, `file_dealloc` 의 postpone 의미상 commit 까지 미뤄지므로 abort 시 자동으로 취소된다. 이 동작이 SA_MODE 에서도 동일한지 확인이 필요하다.

### Header page 예외

OOS 파일의 첫 페이지는 header (slotid=0) 를 가지며 `oos_remove_file` 가 파일 통째 destroy 시에만 회수한다. helper 는 슬롯이 0개인지 검사할 때 header slot 의 존재를 인지하고 절대 dealloc 하지 않아야 한다. "in-use slot count == 0" 단순 검사로 충분한지 (header slot 도 in-use 로 카운트되므로 자연 보호), 아니면 명시적 VPID 비교 (`vpid != first page VPID`) 가 필요한지 ANALYSIS 단계에서 확정한다.

### Recovery

- helper 가 호출하는 `file_dealloc` 은 자체 WAL 로그를 남기므로 vacuum 의 redo-only 의미와 호환된다.
- vacuum 워커가 helper 호출 직전에 죽으면 다음 워커가 같은 블록을 재처리할 때 (`VACUUM_BLOCK_FLAG_INTERRUPTED`) helper 가 idempotent 하게 동작해야 한다 — 이미 빈 페이지면 그대로 dealloc, 이미 dealloc 된 페이지면 NO_ERROR.

---

## Acceptance Criteria

- [ ] `oos_try_reclaim_empty_page` 가 `oos_file.cpp` 에 추가되고, header page 보호 + idempotent + 동시 insert 안전성을 만족한다.
- [ ] `vacuum_heap_oos_delete`, `vacuum_forward_walk_delete_old_oos`, SA_MODE eager cleanup 세 경로에서 touched VPID 추적 + helper 호출이 이루어진다.
- [ ] bestspace 캐시 엔트리가 dealloc 된 페이지에 대해 자동으로 제거된다 (`oos_stats_del_bestspace_by_vpid` 가 필요하면 추가, 아니면 기존 메커니즘으로 무효화).
- [ ] insert/delete heavy 워크로드에서 OOS 파일 페이지 수가 더 이상 단조 증가하지 않는다 (회귀 테스트로 측정).
- [ ] UPDATE heavy 워크로드에서 옛 OOS OID 가 차지하던 페이지가 회수된다 (forward-walk + SA_MODE eager 양쪽).
- [ ] vacuum 워커가 helper 호출 도중 크래시 후 재기동되어도 같은 블록을 재처리해 안전하게 회수한다.
- [ ] 기존 CI (`test_sql`, `test_medium`) 통과.

---

## Definition of done

- [ ] 위 A/C 충족
- [ ] CTP 회귀 테스트 추가 (OOS 파일 페이지 수 추이 측정 시나리오)
- [ ] QA 통과
- [ ] 기존 OOS 문서 (CBRD-26357 epic, CBRD-26583 M2 epic) 에 본 이슈 링크 추가

---

## 참고 코드

- `src/storage/oos_file.cpp:995` — `oos_remove_file` (파일 단위 reclaim, DROP TABLE 경로에서 호출)
- `src/storage/oos_file.cpp:1007` — `oos_remove_page` stub (현재 caller 0건)
- `src/storage/oos_file.cpp:1717` — `oos_delete_chain` (per-chunk 삭제 루프, `oos_stats_update` 호출 지점)
- `src/storage/oos_file.cpp:1816` — `oos_delete` (vacuum 책임 design intent 명시 주석)
- `src/query/vacuum.c:2419` — `vacuum_heap_oos_delete` (REMOVE path, dead heap 슬롯의 OOS OID 회수)
- `src/query/vacuum.c:2494` — REMOVE path 의 `log_sysop_start` 경계
- `src/query/vacuum.c:3458` — `vacuum_forward_walk_delete_old_oos` (UPDATE pre-image OOS OID 회수)
- `src/query/vacuum.c:3471` — forward-walk 의 `log_sysop_start` 경계
- `src/storage/heap_file.c:24178` — SA_MODE eager cleanup 의 `oos_delete` 호출 루프

---

## Remarks

- 선행 / 관련 이슈:
  - CBRD-26609 — `oos_delete` API 도입 (페이지 회수는 vacuum 으로 미룬다고 명시한 그 이슈)
  - CBRD-26668 — vacuum OOS 통합 (forward-walk + REMOVE path)
  - CBRD-26715 — vacuum OOS 거짓 양성 (본 이슈 진행 시 관련 진단 로그 재사용 가능)
  - CBRD-26608 — DROP TABLE 의 OOS cleanup (파일 단위 reclaim, 본 이슈와 별개)
- 본 이슈 완료 후 OOS 의 page lifecycle (insert -> delete -> page reclaim -> file reclaim) 이 완성된다.
