# [OOS] [M2] vacuum 의 OOS 빈 페이지 회수 — file_dealloc 로 partial sector table 반환

## Issue Triage

**이슈 수행 목적**: vacuum 이 슬롯을 모두 비운 OOS 페이지를 `file_dealloc` 로 file manager 의 partial sector table 에 반환해, bestspace cache 가 어떤 상태이든 다음 `file_alloc` 이 그 페이지를 재사용할 수 있게 한다.

**이슈 수행 이유**:

- **AS-IS (현재 동작 / 배경)**: 슬롯 단위 회수(`oos_delete`, CBRD-26609/26668)까지만 구현돼 있고, 페이지 단위 회수는 caller 0건의 dead 함수 `oos_remove_page` 로 방치돼 있다. 빈 페이지 정보를 유일하게 아는 bestspace cache 는 `OOS_BESTSPACE_CACHE_CAPACITY`(1000, 모든 OOS 파일 합산) 상한에 도달하면 새 엔트리를 받지 않고(no eviction), 메모리 전용이라 서버 재시작 시 전부 사라진다(no persistence).
- **TO-BE (목표 상태 / 기대 동작)**: vacuum 이 OOS 삭제 배치를 커밋한 직후, 그 배치가 비운 페이지를 `file_dealloc` 로 partial sector table(캡 없음, 파일 헤더에 디스크 영구 저장)에 등록한다. 이후 `file_alloc` 이 캐시 상태와 무관하게 그 페이지를 재사용한다.
- **영향**: 성능 저하 — 캐시 cap 도달(cap-bound) 또는 재시작 직후(restart-cold) 상태에서 빈 페이지가 insert 경로에 보이지 않아, 슬롯이 재사용 가능한데도 파일 확장이 일어난다. 단 sector 는 파일 소유로 남으므로 줄어드는 것은 확장 빈도이지 디스크 총량이 아니다.

**이슈 수행 방안**: 구현 완료 (기준 커밋 `82d6e4b`, 사용자 지시로 ANALYSIS 실측 게이트를 구현 선행으로 대체). 세 부분으로 확정한다.

| 순서 | 결정 | 근거 요약 |
|------|------|-----------|
| 1 | `FILE_OOS` 를 non-numerable 로 전환하고 페이지 열거를 sector-bitmap walk 로 교체 (CBRD-26831 에서 결정된 전환을 본 구현에 포함) | 성능이 아니라 정합성 전제 — numerable 인 채로 페이지를 회수하면 파일 내부 장부가 어긋난다 (Description 참고) |
| 2 | insert 경로 latch 연속성 확보 — 검증/할당 시점의 WRITE latch 를 쓰기 완료까지 유지 | 회수기의 "비었음" 판정이 쓰기 직전 페이지와 경합하지 않기 위한 안전 불변식 |
| 3 | `oos_try_reclaim_empty_page` 신설, vacuum 두 경로의 sysop 커밋 직후 호출. SA_MODE eager 경로는 의도적으로 제외 | eager 경로는 살아 있는 사용자 트랜잭션 안이라, abort 시 undo 가 이미 회수된 페이지에 청크를 되살리려다 실패한다 |

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: `src/storage/oos_file.{cpp,hpp}`, `src/storage/file_manager.{c,h}` (`file_is_numerable` 신설), `src/query/vacuum.c`, `src/query/vacuum_oos.{cpp,hpp}`, `src/storage/heap_oos.cpp` (주석), OOS 단위 테스트 2본. 사용자 가시 SQL 동작·스펙 변경 없음. WAL 은 기존 `RVFL_DEALLOC` postpone(커밋 시점에 실행되도록 예약해 두는 로그 작업)을 재사용하므로 로그 포맷 변경 없음. feat/oos 는 미출시 브랜치라 상위 호환 부담은 없다.

---

## Description

### 빈 페이지가 insert 경로에서 사라지는 구조

OOS(Out-of-row Overflow Storage — heap 레코드의 큰 가변 컬럼을 전용 파일로 분리 저장하는 방식) 파일에서 페이지의 빈 공간을 insert 에게 알려 주는 층은 셋이다: 전역 해시 캐시(`oos_Bestspace`), 헤더 페이지의 best[10] 힌트 배열(`OOS_HDR_STATS`), 그리고 캐시가 비었을 때 파일을 훑는 Tier-3 sync 스캔. 셋 모두 힌트라서 잃어버려도 정확성 문제는 없지만, 잃어버린 페이지는 insert 가 찾지 못한다. vacuum 이 페이지를 완전히 비워도 그 사실이 캐시 상한이나 재시작으로 증발하면, 다음 insert 는 `file_alloc` 로 새 페이지를 요청하고 빈 페이지는 그대로 남는다.

file manager 의 partial sector table 은 다르다. 파일이 점유한 sector(64 페이지 묶음)마다 어느 페이지가 할당돼 있는지를 비트맵으로 파일 헤더에 영구 기록하고, `file_alloc` 진입점이 가장 먼저 여기서 빈 페이지를 찾는다. 즉 `file_dealloc` 까지만 이어 주면 힌트 층의 한계와 무관하게 페이지가 재사용된다. 이것이 본 이슈의 골자다.

### 구현 과정에서 확인된 세 가지 전제 문제

단순히 dead 함수 `oos_remove_page` 에 vacuum caller 를 붙이면 되는 일이 아니었다. 코드를 따라가면 세 가지가 먼저 풀려야 한다.

**(1) numerable 파일인 채로는 회수가 정합성을 깬다.** `FILE_OOS` 는 numerable(파일이 자기 페이지의 할당 순서를 user page table 로 기록해 n번째 페이지 조회를 지원하는 속성)로 생성돼 왔다. 그런데 `file_dealloc` 의 user page table 정리 분기는 파일 타입 매크로로 게이트된다:

```
file_dealloc (file_manager.c)
 ├ log_append_postpone (RVFL_DEALLOC)          -- 실제 회수는 postpone 실행 시점
 ★ if (!FILE_TYPE_CAN_BE_NUMERABLE (hint)) goto exit;
 │   -- EHASH / EHASH_DIR / TEMP 만 통과. FILE_OOS 는 여기서 빠진다
 └ (통과한 타입만) user page table 에 mark-delete 기록
```

`FILE_OOS` 는 이 매크로에 없어서, numerable 인 OOS 파일의 페이지를 회수하면 sector 비트맵에서는 지워지는데 user page table 에는 산 것으로 남는다. 이후 `file_numerable_find_nth` 가 회수된 페이지를 돌려주고, 그 페이지를 fix 하는 순간 dead-page 검사에 걸린다. CBRD-26831 이 "vacuum caller 연결 전에 non-numerable 로 전환"을 결정해 둔 것이 성능 문제(mark-delete 누적 시 find_nth 의 호출당 O(n) slow path)만이 아니라 정합성 전제였던 셈이다. 그래서 본 구현이 전환을 포함한다.

**(2) insert 경로에 latch 공백이 있었다.** 회수기는 "페이지가 비었다"를 확인한 뒤 회수하는데, 그 판정과 다른 스레드의 쓰기 사이에 경합이 있으면 안 된다. 기존 insert 경로에는 후보 페이지를 conditional latch(페이지 단위 단기 잠금을 대기 없이 시도하는 방식)로 검증한 뒤 unfix 했다가 다시 fix 하는 구간(`oos_find_best_page`)과, `file_alloc` 직후 unfix 상태로 있다가 re-fix 하는 구간(`oos_file_alloc_new`)이 있었다. 이 공백 동안 페이지는 "곧 쓰일 예정인데 아무도 잡고 있지 않은" 상태가 되고, 회수기가 그 틈에 비어 있는 페이지를 회수하면 쓰려던 스레드가 회수된 페이지에 기록하는 시나리오가 열린다.

**(3) 회수 시점은 삭제 커밋 이후여야 한다.** `oos_delete` 는 청크마다 undo 로그(`RVOOS_DELETE`)를 남기고, 트랜잭션이나 sysop(system operation — 크래시 복구가 all-or-nothing 으로 다루는 작업 단위)이 abort 되면 undo 가 청크를 원래 슬롯에 되살린다. 페이지가 이미 회수됐다면 undo 가 기록할 페이지가 없다. 따라서 회수는 삭제를 담은 sysop 이 커밋된 뒤에만 안전하고, 같은 이유로 SA_MODE eager 삭제 경로(`heap_oos_delete_unreferenced` — 살아 있는 사용자 트랜잭션 내부)는 회수 대상에서 제외했다. eager 경로가 비운 페이지는 할당된 채 남지만 bestspace 에는 계속 보이므로 이후 insert 가 재사용한다.

> **요지**: 페이지 회수의 mechanic 자체는 `file_dealloc` 한 줄이다. 작업의 실체는 그 한 줄이 안전해지도록 파일 속성(non-numerable), insert 경로의 latch 규율, 호출 시점(커밋 이후)을 맞추는 데 있다.

## Specification Changes

사용자 가시 스펙 변경 없음. 내부 동작 변경 두 가지:

- 신규 생성되는 `FILE_OOS` 는 non-numerable 이다. 구버전 빌드가 만든 numerable OOS 파일은 `oos_try_reclaim_empty_page` 가 `file_is_numerable` 검사로 회수를 건너뛴다 (그 외 동작은 동일).
- vacuum 이 OOS 삭제 배치를 커밋할 때마다 비워진 페이지가 파일에 반환된다. 성능 특성: cap-bound / restart-cold 상황의 OOS 파일 확장 빈도 감소가 기대치이며, 정량 확인은 Acceptance Criteria 의 CTP 회귀 시나리오로 한다.

## Implementation

### 회수 함수와 안전성 논증

`oos_try_reclaim_empty_page (thread_p, oos_vfid, vpid)` (`oos_file.cpp`). 멱등·zero-wait·best-effort 로 설계해, "지금 회수 못 함"(페이지 사용 중, 이미 회수됨, 재점유됨, sticky first page, legacy numerable 파일)은 전부 NO_ERROR 로 빠져나가고 다음 vacuum 사이클의 후보로 남긴다.

```
oos_try_reclaim_empty_page
 ├ sticky first page 면 skip            -- OOS_HDR_STATS 가 사는 페이지, 절대 회수 금지
 ├ legacy numerable 파일이면 skip       -- 위 Description (1)
 ├ stats header page 를 WRITE latch    ★ 이후 전 구간 유지 — insert 측의 모든 페이지 발견
 │                                        경로(해시/best[]/sync 재시도/alloc)가 이 페이지
 │                                        fix 에서 시작하므로, 새 writer 유입이 차단된다
 ├ 대상 페이지 conditional fix (OLD_PAGE_MAYBE_DEALLOCATED, WRITE)
 │   ├ busy       -> skip               -- 이미 잡은 writer 가 있다 = 곧 쓰인다
 │   └ 이미 회수됨 -> skip               -- 멱등성 (vacuum block 재시도 대응)
 ├ ptype == PAGE_OOS && 레코드 0건 확인
 ├ sysop start; file_dealloc (FILE_OOS) -- RVFL_DEALLOC postpone 등록
 ├ 대상 페이지 unfix                     -- postpone 의 pgbuf_dealloc_page 가 단독 fixer 요구
 ├ sysop commit                        ★ postpone 이 여기서 실행 — sector 비트 clear
 └ (header latch 유지한 채) 해시 엔트리 퇴출 + best[] 힌트 무효화
```

비었음 판정이 경합하지 않는 이유는 두 갈래다. 새로 페이지를 받으려는 writer 는 header page fix 를 지나야 하는데 회수기가 그것을 잡고 있고, 이미 페이지를 받아 둔 writer 는 검증/할당 시점부터 WRITE latch 를 놓지 않으므로(아래) 회수기의 conditional fix 가 실패한다. unfix 와 postpone 실행 사이의 짧은 틈에는 읽기 전용 sync 샘플링만 끼어들 수 있고, 그로 인해 생길 수 있는 stale 힌트는 커밋 이후의 퇴출과 lookup 측 관용(아래)이 흡수한다.

### insert 경로 latch 연속성

- `oos_find_best_page`: 후보 검증(Phase C)에서 얻은 WRITE latch 를 unfix/re-fix 없이 `auto_unfix_page_ptr` 로 그대로 인계한다. 기존의 "re-fix 후 다른 스레드가 채웠으면 새로 할당" 폴백 — 검사와 사용 사이 틈을 사후 보정하던 코드 — 도 함께 사라진다.
- `oos_file_alloc_new`: `file_alloc` 의 `page_out` 인자로 할당 시점에 WRITE latch 를 받아 그대로 인계한다.
- `oos_stats_find_page_in_bestspace` Phase C: 후보 fix 를 `OLD_PAGE_MAYBE_DEALLOCATED` 로 바꾸고, 회수된 페이지를 가리키는 stale 힌트는 `ER_PB_BAD_PAGEID` 감지 시 해시/best[] 에서 자가 퇴출한다. 회수가 도입되면 stale 힌트는 버그가 아니라 정상 race 이기 때문이다.

### 열거 전환 (non-numerable, CBRD-26831)

`oos_collect_data_page_vpids` 신설: `file_get_all_data_sectors` 가 partial/full sector table 을 private memory 로 복사해 주면(파일 테이블 페이지는 제외됨) 비트맵을 풀어 VPID(볼륨 + 페이지 식별자) 목록을 만든다. 스냅샷이라 걷는 동안 회수가 끼어들 수 있으므로, 소비자(`oos_stats_sync_bestspace`, `oos_get_stats_by_vfid`)는 `OLD_PAGE_MAYBE_DEALLOCATED` fix 와 페이지 타입(`PAGE_OOS`) 검사로 샘플링하고 건너뛴 페이지 수를 `oos.log` 에 남긴다. `file_numerable_find_nth` 의존은 전부 제거, 생성 플래그는 `is_numerable=false`.

### vacuum 연결

`oos_delete` 에 선택 인자 `touched_vpids` 를 추가해 청크가 지워진 페이지를 (체인이 여러 페이지에 걸치는 경우 포함) 수집한다. 두 경로 모두 배치의 sysop 커밋 직후 `vacuum_oos_reclaim_empty_pages` (정렬 + 중복 제거 후 helper 반복 호출, 실패는 경고만)로 넘긴다:

- forward-walk: `vacuum_forward_walk_oos_delete_atomic` (`vacuum_oos.cpp`) 자체 sysop 커밋 직후.
- REMOVE 경로: `vacuum_heap_oos_delete_within_sysop` 이 수집하고, `vacuum.c` 의 REC_RELOCATION / REC_HOME 분기가 자기 sysop 커밋 직후 호출.

vacuum worker 는 sysop 커밋이 곧 최종 확정이므로(worker 는 바깥 트랜잭션을 abort 하지 않는다) Description (3) 의 조건을 만족한다.

### 부수 정리

- dead 함수 `oos_remove_page` 와 선언, TODO 주석 삭제. `oos_delete` 헤더 주석을 helper 기준으로 갱신.
- `file_is_numerable` 신설 (`file_manager.c`, `file_get_num_user_pages` 와 동형).
- `oos_get_length` (단위 테스트용 프로브)가 회수된 페이지를 "레코드 없음"으로 보고하도록 `pgbuf_fix_if_not_deallocated` 로 전환.
- 단위 테스트: 비어 있지 않은 페이지 skip / 비운 뒤 회수 / 멱등성 / sticky first page 가드 시나리오 추가 (`test_oos_remove_file{,_server}.cpp`). 테스트는 회수 전에 삭제를 커밋한다 — Description (3) 의 계약과 동일.

## Acceptance Criteria

- [x] `oos_try_reclaim_empty_page` 가 `oos_file.cpp` 에 추가된다.
- [x] helper 가 sticky first page 를 회수하지 않는다 (강제 호출 시 NO_ERROR).
- [x] helper 가 멱등하다 (이미 회수된 페이지에 NO_ERROR).
- [x] 사용 중 슬롯이 있으면 `file_dealloc` 을 호출하지 않는다.
- [x] forward-walk / REMOVE 두 vacuum 경로에서 touched VPID 수집 + 커밋 후 회수가 이뤄진다.
- [x] 회수된 페이지의 bestspace 엔트리(해시 + 헤더 best[])가 제거되고, 남은 stale 힌트는 lookup 이 자가 퇴출한다.
- [x] `FILE_OOS` 가 non-numerable 로 생성되고 열거가 sector-bitmap walk 로 동작한다. legacy numerable 파일은 회수를 건너뛴다.
- [x] dead 함수 `oos_remove_page` 계열 정리.
- [x] OOS 단위 테스트 전체 통과 (25/25, debug 빌드).
- [ ] CTP 회귀: 10000행 insert + delete 사이클 5회 반복 후 OOS 파일 페이지 수가 첫 사이클 종료 대비 +-10% 이내.
- [ ] CTP 회귀: 동일 행 10000회 UPDATE 후 vacuum 완료 시점 OOS 파일 페이지 수가 `ceil(10000/N) * 2` 이하 (N = 페이지당 페이로드 수).
- [ ] 동시 워크로드 CTP: 10000행 delete 커밋 직후 vacuum 과 동시에 별 세션 10000행 insert. 종료 후 COUNT 일관 + 에러 로그 0건.
- [ ] vacuum worker 가 회수 도중 크래시 후 재기동돼도 같은 블록 재처리가 안전하다 (crash injection).
- [ ] 기존 CI (`test_sql`, `test_medium`) 통과.

## Definition of done

- [ ] 위 A/C 충족.
- [ ] CTP 회귀 테스트가 저장소에 추가된다.
- [ ] QA 통과.

## 참고 코드

기준 커밋 `82d6e4b` (feat/oos 기반 구현 브랜치).

- `oos_file.cpp` — `oos_try_reclaim_empty_page`, `oos_collect_data_page_vpids`, Phase C 관용 (`oos_stats_find_page_in_bestspace`), latch 인계 (`oos_find_best_page`, `oos_file_alloc_new`), 생성 플래그 (`oos_create_file_internal`)
- `vacuum_oos.cpp` — `vacuum_oos_reclaim_empty_pages`, forward-walk 커밋 후 회수
- `vacuum.c` — REC_RELOCATION / REC_HOME 분기의 커밋 후 회수 호출
- `file_manager.c:186` — `FILE_TYPE_CAN_BE_NUMERABLE` (FILE_OOS 제외 게이트), `file_dealloc`, `file_perm_dealloc`, `file_is_numerable`
- `heap_oos.cpp` — `heap_oos_delete_unreferenced` 의 회수 제외 사유 주석

## Remarks

- 선행/관련: CBRD-26609 (`oos_delete` API), CBRD-26668 (vacuum OOS 통합), CBRD-26658 (3-tier bestspace), CBRD-26608 (DROP TABLE 파일 회수). 본 이슈로 OOS 페이지 생애 주기 (할당 -> 슬롯 회수 -> 페이지 회수 -> 파일 회수) 가 완성된다.
- non-numerable 전환은 CBRD-26831 로 별도 추진 예정이던 항목인데, 위 Description (1) 의 정합성 전제 때문에 본 구현에 포함했다. CBRD-26831 과의 정리(중복 종료 또는 잔여 범위 축소)가 필요하다.
- 구 이슈 본문의 caller 함수명은 리팩터링으로 바뀌었다: `vacuum_heap_oos_delete` -> `vacuum_heap_oos_delete_within_sysop`, `vacuum_forward_walk_delete_old_oos` -> `vacuum_forward_walk_oos_delete_atomic`, `heap_update_home_delete_replaced_oos` -> `heap_oos_delete_unreferenced`. 구 본문이 세 번째 caller (SA eager) 도 회수 대상으로 잡았던 것은 Description (3) 의 이유로 철회했다.
- 구 본문의 Open Questions 정리: Q1 (postpone 호환성) 은 sysop 커밋 시 postpone 실행으로 확인, Q2 (batch 단위) 는 per-record/per-log-record 로 확정, Q3 (컨테이너) 는 vector + sort/unique 채택, Q4 (멱등성) 는 helper 내부 흡수로 해결. Q5 (실측 게이트) 는 구현 선행으로 대체하고 정량 확인을 A/C 의 CTP 회귀로 이관했다.
- 향후 disk manager 가 sector 단위 반환(`disk_unreserve_ordered_sectors` 의 `file_destroy` 외 호출 경로)을 지원하면 효과가 "확장 빈도 감소"에서 "디스크 사용량 감소"로 확장된다. 그 시점에 후속 이슈를 연다.
