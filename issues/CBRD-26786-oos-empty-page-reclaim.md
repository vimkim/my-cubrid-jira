# [OOS/VACUUM] vacuum의 OOS 슬롯 삭제 후 빈 페이지 회수

## Issue Triage

**이슈 수행 목적**: vacuum 이 OOS 슬롯을 모두 비운 페이지를 `file_dealloc` 으로 OOS 파일에 반환하여, 삭제 비중이 큰 워크로드에서 OOS 파일의 회수되지 않는 빈 페이지가 누적되지 않도록 한다.

**이슈 수행 이유**:
- **현재 동작 / 배경**: `oos_delete` (`src/storage/oos_file.cpp:1816`) 는 `oos_delete_chain` 내부에서 슬롯만 비우고 페이지는 그대로 두며 bestspace 캐시의 free space 만 갱신한다. 페이지에 슬롯이 0개가 되어도 `file_dealloc(... FILE_OOS)` 를 호출하지 않는다. `oos_remove_page` (`oos_file.cpp:1007`) 는 본문에 `file_dealloc` 호출이 들어 있으나 현재 호출자가 0건인 미연결 함수이며, 함수 위 한 줄 TODO 주석 (`oos_file.cpp:1005`) 은 "will be called by vacuum when OOS vacuum is implemented" 라고 명시한다. `oos_delete` 자체의 header 주석 (`oos_file.cpp:1812-1813`) 도 "Page deallocation is NOT done here. Empty pages will be reclaimed by vacuum after the transaction commits." 라고 책임을 vacuum 으로 미뤄두었다.
- **영향**: 슬롯 단위 재사용 (bestspace 에 free space 등록) 은 동작하므로 같은 OOS 파일 안에서의 재배치는 일어난다. 그러나 모든 슬롯이 비어 있는 페이지가 파일에 매달려 있어 다른 파일로 재할당되지 않는다. delete/update 비중이 큰 OOS 워크로드에서 회수되지 않는 빈 페이지가 단조 누적되어 OOS 파일 페이지 수가 줄어들지 않는다.

**이슈 수행 방안**:
- mechanic 은 storage 레이어에 helper 로 둔다 — `oos_file.cpp` 에 빈 페이지 판정 + `file_dealloc` + bestspace 캐시 무효화를 묶은 `oos_try_reclaim_empty_page (thread_p, oos_vfid, vpid)` 를 신설한다. Header page 보호, idempotent 동작, 동시 insert 와의 안전성은 helper 안으로 가둔다.
- trigger 는 caller 쪽 batch boundary 에서 일괄 호출한다 — `vacuum_heap_oos_delete` (`vacuum.c:2419`), `vacuum_forward_walk_delete_old_oos` (`vacuum.c:3458`), SA_MODE 의 `heap_update_home_delete_replaced_oos` (`heap_file.c:24131`, oos_delete 루프는 `heap_file.c:24178`) 세 caller 가 touched VPID 집합을 들고 있다가 마지막에 한 번 helper 를 호출한다. `oos_delete` 의 inner loop 핫패스에는 검사를 넣지 않는다.
- bestspace 캐시 일관성을 위해 helper 는 기존 `oos_stats_del_bestspace_by_vpid` (`oos_file.cpp:336`, 이미 `oos_file.cpp:592` 와 `oos_file.cpp:1870` 에서 사용 중) 를 재사용한다.
- REC_BIGONE 와 OOS 가 공존하지 않는다는 기존 invariant (`vacuum.c:2589` 의 `assert (!heap_recdes_contains_oos (&helper->record))`) 는 본 이슈 범위 밖이며 그대로 둔다.
- 회귀 테스트: insert/delete heavy 워크로드 + UPDATE heavy 워크로드 각각에서 OOS 파일 페이지 수 추이를 측정해 빈 페이지가 회수되는지 확인한다. SA_MODE 경로도 동일 시나리오로 검증한다.
- `file_dealloc` 을 vacuum 의 기존 sysop 경계 (`vacuum.c:2494` `log_sysop_start`, `vacuum.c:3471` 등) 안에 두는 것이 안전한지: `TBD - ANALYSIS 단계에서 결정` (후보안: helper 는 한 sysop 안에서 page fix → in-use slot 카운트 → 후보 마킹 → unfix → `file_dealloc` 순서로 동작시키되, `file_dealloc` 이 내부에서 추가로 fhead/페이지를 fix 하므로 latch 보유 상태로의 호출은 회피한다).
- 빈 페이지 검사를 per-record / per-page / per-block 중 어느 batch 단위에서 돌릴지: `TBD - ANALYSIS 단계에서 결정` (후보안: vacuum 두 caller 는 per-record 종료 시점 — 한 dead heap record 또는 한 `RVHF_UPDATE_NOTIFY_VACUUM` log record 를 처리하는 sysop 끝에서 호출, SA_MODE eager 는 한 UPDATE context 종료 시점에서 호출).

---

## AI-Generated Context

> 아래 내용은 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 **Issue Triage** 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **문제 / 목적**: vacuum 이 OOS 슬롯을 다 비운 페이지를 OOS 파일에 반환하지 못해, 회수되지 않는 빈 페이지가 누적된다. 빈 페이지를 `file_dealloc` 으로 반환한다.
- **원인 / 배경**: vacuum 쪽 호출자 (`vacuum_heap_oos_delete`, `vacuum_forward_walk_delete_old_oos`, `heap_update_home_delete_replaced_oos`) 에 페이지 회수 호출이 빠져있고 `oos_remove_page` 는 본문은 갖췄지만 caller 가 0건인 미연결 함수다. design intent 는 책임 분리 결정 표 참조.
- **제안 / 변경**: storage 레이어 helper (`oos_try_reclaim_empty_page`) 신설 + 세 caller 에서 batch boundary 호출. bestspace 캐시 일관성 처리 + header page 예외 + transactional safety 검토 동반.
- **영향 범위**: `src/storage/oos_file.{cpp,hpp}`, `src/query/vacuum.c` (`vacuum_heap_oos_delete`, `vacuum_forward_walk_delete_old_oos`), `src/storage/heap_file.c` (`heap_update_home_delete_replaced_oos`). 사용자 호환성 영향 없음 (내부 storage 관리만 변경).

---

## Description

### 배경

OOS 마일스톤 1 에서 `oos_delete` (CBRD-26609) 가 도입되어 슬롯 단위 물리 삭제가 가능해졌고, CBRD-26668 에서 vacuum 통합이 마무리되었다. 현재 vacuum 워커는 MVCC 가 dead 로 판정한 heap 레코드의 OOS OID 들을 다음 세 경로에서 `oos_delete` 로 회수한다.

| 경로 | 위치 | 트리거 |
|---|---|---|
| `vacuum_heap_oos_delete` | `vacuum.c:2419` | 죽은 heap 슬롯의 OOS OID 회수 (REMOVE path) |
| `vacuum_forward_walk_delete_old_oos` | `vacuum.c:3458` | `RVHF_UPDATE_NOTIFY_VACUUM` 의 pre-image OOS OID 회수 (UPDATE 로 교체된 옛 OID) |
| `heap_update_home_delete_replaced_oos` | `heap_file.c:24131` (oos_delete 루프 `heap_file.c:24178`) | SA_MODE 에서 UPDATE 직후 옛 OOS OID 즉시 회수 |

세 경로 모두 슬롯만 비우고 페이지는 그대로 둔다. `oos_delete_chain` (`oos_file.cpp:1717`) 의 chunk 삭제 루프 내부에서 `oos_stats_update` (`oos_file.cpp:1774`) 를 호출해 bestspace 캐시에 free space 만 등록한다. 다른 OOS insert 가 같은 페이지에 들어오면 슬롯은 재사용되지만, 모든 슬롯이 비어도 페이지는 파일에 매달려 있다.

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
2. 루프 동안 touched VPID 집합을 caller 컨텍스트에 누적한다 (예: 작은 정렬된 컨테이너). 정확한 컨테이너 선택은 ANALYSIS 단계에서 결정한다.
3. 루프 종료 후 집합을 순회하며 oos_try_reclaim_empty_page 를 호출한다.
4. helper 실패는 warning 으로 기록하고 vacuum 진행을 막지 않는다 (페이지 회수 실패는 다음 vacuum 사이클의 후보로 남으면 충분하므로 워커 자체를 멈추지 않는다).
```

대상:
- `vacuum_heap_oos_delete` (`vacuum.c:2419`) — 한 dead heap 레코드 처리 종료 시점
- `vacuum_forward_walk_delete_old_oos` (`vacuum.c:3458`) — 한 `RVHF_UPDATE_NOTIFY_VACUUM` log record 처리 종료 시점
- `heap_update_home_delete_replaced_oos` (`heap_file.c:24131`, oos_delete 루프 `heap_file.c:24178`) — 한 UPDATE 의 옛 OID 회수 종료 시점

### 동시성 / Transactional 안전성

- **동시 insert 와의 race 처리**: helper 는 페이지를 fix 한 상태에서 in-use slot 수를 검사하지만, `file_dealloc` 자체가 내부에서 fhead 와 대상 페이지를 fix 하므로 동일 latch 구간 안에서 호출하면 latch 충돌이 난다. 구체적인 latch / sysop 경계는 ANALYSIS 단계에서 확정한다 (방안 참조).
- **per-chunk loop 와 helper 의 정상 동작**: 동시 insert 가 빈 페이지를 재점유한 경우 helper 는 in-use slot > 0 을 보고 dealloc 를 건너뛴다. 이는 정상 동작이며, 그 페이지는 다음 vacuum batch 에서 다시 회수 후보가 된다.
- **vacuum sysop 와의 관계**: vacuum 의 caller 들은 이미 `log_sysop_start` 안에서 동작한다 (예: `vacuum.c:2494`, `vacuum.c:3471`). `file_dealloc` 을 같은 sysop 안에서 호출해도 되는지, 아니면 sysop commit 후 별도 boundary 로 묶어야 하는지 검토가 필요하다.
- **SA_MODE 에서 호출 시점 검증**: `file_dealloc` 은 permanent file 에 대해 `RVFL_DEALLOC` postpone 레코드를 남겨 commit/run-postpone 시점에 실제 페이지 해제를 수행한다 (`file_manager.c:6181-6190`). vacuum / SA_MODE caller 에서 sysop commit/abort 와 `RVFL_DEALLOC` postpone 의 상호작용 (sysop 안에서 호출 시 sysop commit 시점에 실제로 회수되는지, 트랜잭션 abort 시 postpone 이 어떻게 취소/유지되는지) 은 ANALYSIS 단계에서 확인한다.

### Header page 예외

OOS 파일의 첫 페이지는 sticky first page 로 마킹되어 있다 (`file_alloc_sticky_first_page`, `oos_file.cpp:940`). `file_manager.c:123` 의 `vpid_sticky_first` 필드 주석은 "This page should never be deallocated." 라고 명시한다. helper 는 dealloc 전에 `file_get_sticky_first_page` (`file_manager.c:5786`) 로 sticky first VPID 를 읽어 일치하면 즉시 NO_ERROR 로 빠져나간다. (`file_dealloc` 자체에도 sticky-first 페이지 dealloc 시 assert 가 있다 — `file_manager.c:6178`. 이 assert 는 dev 빌드 전용이므로 release 빌드에서도 가드를 보장하기 위해 helper 에서 한 번 더 검사한다.)

### Recovery

- `file_dealloc` 의 postpone-기반 회수 모델 (`RVFL_DEALLOC`) 이 vacuum sysop 의 postpone 처리 (`log_sysop_attach_to_outer` / `log_sysop_end_logical_run_postpone` 경로, `log_manager.c:4015`, `log_manager.c:4109`) 와 어떻게 상호작용하는지는 ANALYSIS 단계에서 확인한다. `FILE_OOS` 에 대한 `file_dealloc` recovery (fhead bitmap, full/partial page list 갱신, WAL 기록) 가 정상 동작하는지도 같은 단계에서 재검증한다.
- vacuum 워커가 helper 호출 직전에 죽으면 다음 워커가 같은 블록을 재처리할 때 (`VACUUM_BLOCK_FLAG_INTERRUPTED`) helper 가 idempotent 하게 동작해야 한다. `file_dealloc` 가 이미 dealloc 된 페이지에 대해 무엇을 반환하는지 확인 후 helper 가 그 케이스를 NO_ERROR 로 흡수한다 — `oos_delete_chain` 의 S_DOESNT_EXIST 회피 (`vacuum.c:3695-3696` 주석 참조) 와 동일한 idempotency 의무.

### `oos_remove_page` 처분

기존 `oos_remove_page` (`oos_file.cpp:1007`) 는 `file_dealloc(... FILE_OOS)` 호출 본문은 가지고 있으나 현재 호출자가 0건인 미연결 함수다. 본 이슈에서 `oos_try_reclaim_empty_page` 가 sticky-first 가드 + bestspace 캐시 무효화 + in-use slot 검사를 추가한 superset 이므로 `oos_remove_page` 는 삭제한다.

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
