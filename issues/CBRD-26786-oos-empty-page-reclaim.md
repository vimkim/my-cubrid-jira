# [OOS] vacuum 의 OOS 빈 페이지 `file_dealloc` 회수 보류 — sector-reclaim 인프라 의존성 (슬롯 삭제는 무관)

## Issue Triage

**이슈 수행 목적**: 본 이슈가 다루는 페이지 단위 `file_dealloc` 회수 단계를 보류 (Won't Fix / Defer) 하고 그 근거를 본문에 남긴다. 슬롯 단위 데이터 회수 (`oos_delete`, CBRD-26668, PR #6986) 는 이 결정과 무관하며 그대로 동작한다. 본 보류는 페이지 단위 dealloc 단계에만 한정한다.

**이슈 수행 이유**:

- **현재 동작**:
  - 슬롯 단위 회수는 vacuum 이 dead OOS slot 을 `oos_delete` 로 지운 뒤 `oos_delete_chain` 안에서 `oos_stats_update` (`oos_file.cpp:1774`) 를 호출해 bestspace 캐시의 free space 통계를 갱신한다. PR #6986 / CBRD-26668 로 마무리됐고 정상 작동 중.
  - 페이지 단위 회수 (본 이슈 범위) 는 미구현이다. `oos_remove_page` (`oos_file.cpp:1007`, 선언 `oos_file.hpp:80`) 가 `file_dealloc(... FILE_OOS)` 호출 본문을 가지고 있으나 caller 가 0 건이다. `grep oos_remove_page` 가 선언과 정의 두 줄만 잡는다. 바로 위 `oos_file.cpp:1005` 의 `// TODO: will be called by vacuum when OOS vacuum is implemented` 주석이 미완 상태를 명시한다.
  - `file_dealloc` (`file_manager.c:6122`) 의 permanent file 분기는 `RVFL_DEALLOC` postpone record 만 등록한다 (`file_manager.c:6186`). 실제 dealloc 은 run-postpone 시점에 `file_perm_dealloc` (`file_manager.c:6315-6612`) 이 수행한다.
  - `file_perm_dealloc` 은 sector bitmap 의 페이지 비트 clear, full sector 의 partial table 이동, 파일 헤더 통계 갱신, 페이지 버퍼 비움까지만 한다. `is_empty == true` 분기에서도 `disk_unreserve_ordered_sectors` 를 호출하지 않는다.
  - permanent file 의 sector 가 disk manager 로 반환되는 경로는 `file_destroy` (`file_manager.c:4330`) 한 곳뿐이다. `file_destroy` 는 `bool is_temp` 인자로 permanent / temp 양쪽을 다루므로 4330 자체는 "destroy 전용" 경로다. 다른 `disk_unreserve_ordered_sectors` 호출처 `file_manager.c:3890` 은 temp file reservation rollback 전용이다.
  - 접근 모델 측면에서 OOS 는 OOS OID 의 (volid, pageid, slotid) 로의 point-access 만 한다. `oos_read` (`oos_file.cpp:1406`) -> `oos_read_within_page` (`oos_file.cpp:1347`), 다중 청크는 `oos_read_across_pages` (`oos_file.cpp:1279`) 가 청크 체인을 따라간다. heap 의 `prev_vpid` / `next_vpid` 같은 페이지 chain 순회 구조가 없다.

- **한계 / 영향** — 본 이슈를 구현해도 다음 다섯 카테고리 모두에서 의미 있는 이득이 없다:
  - **고객 장애**: 없음. 사용자 가시 SQL 동작과 데이터 회수에 영향이 없고, 슬롯 회수가 정상 동작하므로 OOS 파일은 계속 새 데이터를 받는다.
  - **QA 실패**: 없음. 빈 OOS 페이지 누적이 회귀 fail 을 일으키는 케이스가 현재까지 보고되지 않았다.
  - **성능 저하**: 미미. heap 처럼 sequential scan 으로 빈 페이지를 walk 하는 경로가 OOS 에 없다 (point-access 모델). 빈 페이지가 매달려 있어도 query 비용은 늘지 않는다. `db_volume_info` / `db_space` 같은 DBA 가시 지표에는 영향이 있을 수 있으나, 사용자가 체감할 만한 비용은 아니다 (실측 미확보).
  - **설계 의도 훼손**: 부분적이지만 손실은 작다. `oos_delete` header 주석 (`oos_file.cpp:1812-1813`) 의 "Empty pages will be reclaimed by vacuum after the transaction commits." 라는 design intent 가 미충족이다. 그러나 이 intent 가 가정한 "회수 = sector 가 disk 로 돌아감" 자체가 현 disk manager 구조에서 성립하지 않으므로, 본 이슈를 구현해도 intent 의 본래 목적은 달성되지 않는다.
  - **기술 부채**: 본 이슈 자체보다는 외부 인프라 (disk manager sector-level reclaim) 의 후속 작업에 가깝다. 다만 dead 함수 `oos_remove_page` 와 그 TODO 주석이 코드에 남아 있는 작은 부채가 있고, 본 이슈 close 시 함께 정리한다 (AC 참조).

**이슈 수행 방안**:

- 본 이슈를 Resolution: Won't Fix 로 close 한다. JIRA close 코멘트에 결정 요지와 본 문서 link, 그리고 코드 검증 근거 (`file_manager.c:6315-6612`, `oos_file.cpp:1406`) 를 함께 남긴다.
- 보류 범위를 명시한다. 슬롯 단위 회수 (`oos_delete`) 는 본 결정 밖이며 정상 동작이 유지된다. 본 이슈는 페이지 단위 `file_dealloc` (`oos_remove_page` 의 caller 추가) 만 보류한다.
- 코드 정리: `oos_remove_page` (`oos_file.cpp:1005-1017`, 선언 `oos_file.hpp:80`) 와 위 TODO 주석을 본 이슈 close 와 함께 삭제한다. `oos_delete` 의 `oos_file.cpp:1812-1813` 주석은 "deferred, see CBRD-26786" 로 갱신한다.
- 부활 트리거: disk manager 가 permanent file 의 빈 sector 를 `file_destroy` 외 경로로 disk manager 에 반환하는 인프라가 도입되는 시점에 본 이슈를 link 로 부활시킨다. 현재 관련 JIRA 미존재.

---

## AI-Generated Context

> 아래 내용은 AI 가 코드와 맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 결정 근거 확인과 향후 부활 시 출발점으로 참조하면 된다.

### Summary

- **문제 / 목적**: 페이지 단위 OOS 회수 (`file_dealloc`) 도입의 실효성을 코드 사실관계로 검증하고 보류 여부를 확정한다.
- **원인 / 배경**: 원안의 motivation (다른 파일로의 sector 재할당, 페이지 누적 회피) 이 현 disk manager 구조와 OOS 의 접근 모델에 맞지 않는다.
- **제안 / 변경**: 페이지 회수 단계만 보류한다. 슬롯 회수는 무관하게 정상 동작한다. dead 함수와 미완 주석은 close 시 함께 정리한다.
- **영향 범위**: 코드 변경은 `oos_file.cpp` 와 `oos_file.hpp` 의 minor 한 줄 (dead 함수 + 주석 정리) 이다. 사용자 가시 변경 없음. epic CBRD-26583 의 status 메모 한 줄.

---

## Description

### 보류 결정의 발단

본 이슈의 1 차 draft 는 vacuum 이 OOS 슬롯을 다 비운 페이지를 `file_dealloc` 으로 회수하는 helper (`oos_try_reclaim_empty_page`) 신설을 제안했다. 리뷰어가 triage 전에 다음을 지적했다.

> [원문 그대로] heap 의 빈 페이지 제거는 heap scan 비용 때문이라 정당화되지만 OOS 는 scan 자체가 없어 그 시나리오에 해당하지 않는다. "다른 파일에서의 재사용" 도 sector 를 disk manager 에 반환해야 성립하는데 현재 그 메커니즘이 없는 것으로 안다. triage 전에 확인 후 의견 달라.

코드로 두 지적을 검증한 결과 둘 다 코드 동작과 일치했다. 본 이슈는 페이지 회수 단계만 보류로 결정하고, 슬롯 회수 동작은 그대로 둔다.

### 검증 1 — OOS scan 부재

OOS 의 모든 read 경로는 caller 가 미리 알고 있는 OOS OID 의 (volid, pageid, slotid) 로의 point-access 다.

- 단일 청크는 `oos_read` (`oos_file.cpp:1406`) 가 `oos_read_within_page` (`oos_file.cpp:1347`) 를 호출하고, 후자가 OID 의 (volid, pageid) 로 직접 `pgbuf_fix` 한다.
- 다중 청크는 첫 청크 header 에서 다음 청크의 OID 를 꺼내 `oos_read_across_pages` (`oos_file.cpp:1279`) 가 chained point-access 로 순차 fetch 한다.
- 진입점에서는 caller 가 heap 레코드의 variable area 에서 OOS OID 를 꺼내 들어온다 (`heap_file.c:10652` 의 `oos_read` 호출).

대조 케이스로 `heap_remove_page_on_vacuum` (`heap_file.c:4716`) 이 빈 heap 페이지를 떼어내는 작업의 본체는 `prev_vpid` / `next_vpid` 의 chain 링크 재연결이다 (`heap_file.c:4784-4789` 의 `heap_vpid_prev` / `heap_vpid_next` 호출과 그 후 chain 갱신 블록). heap 에서 빈 페이지 제거가 정당화되는 이유가 바로 이 chain 을 heap scan 이 walk 하기 때문인데, OOS 에는 이 chain 자체가 없다.

결론: heap 식 "빈 페이지가 scan 비용을 키운다" 모델은 OOS 에 적용할 수 없다.

### 검증 2 — permanent file 의 sector 가 disk manager 로 돌아가지 않음

`file_dealloc` (`file_manager.c:6122`) 의 permanent file 분기는 `RVFL_DEALLOC` postpone record 만 등록한다 (`file_manager.c:6186` 의 `log_append_postpone`). 실제 dealloc 은 run-postpone 시점에 `file_perm_dealloc` (`file_manager.c:6315-6612`) 이 수행하며, 그 동작은 다음이다.

- sector bitmap 의 페이지 비트 clear (`file_manager.c:6376` 의 `file_partsect_clear_bit`).
- `is_empty = file_partsect_is_empty (partsect)` 로 sector 가 모두 비었는지 판정 (`file_manager.c:6377`).
- was_full 이었던 sector 면 full table 에서 제거하고 partial table 로 이동 (`file_manager.c:6402` 이후 else 분기).
- 파일 헤더 통계 갱신 (`file_manager.c:6580` 의 `file_header_dealloc`).
- 페이지 버퍼 비움 (`file_manager.c:6599` 의 `pgbuf_dealloc_page`).

`disk_unreserve_ordered_sectors` 는 `file_perm_dealloc` 어디서도 호출되지 않는다. `is_empty == true` 분기에서도 호출되지 않는다. `file_manager.c` 내 `disk_unreserve_ordered_sectors` 호출처를 `grep` 으로 모두 나열하면 두 곳이다.

- `file_manager.c:3890` — `file_create` 의 temp file reservation rollback 경로 (`DB_TEMPORARY_DATA_PURPOSE`).
- `file_manager.c:4330` — `file_destroy` (`file_manager.c:4119-4128`) 의 cleanup. `file_destroy` 는 `bool is_temp` 인자로 permanent / temp 양쪽을 모두 다루므로, permanent file 의 sector 가 disk manager 로 반환되는 경로는 `file_destroy` 한 곳뿐이다.

즉 permanent file 의 한 페이지를 dealloc 해도 그 sector 는 그 파일의 partial table 에 남아 같은 파일의 다음 `file_alloc` 요청에만 재사용된다. 본 이슈를 구현해도 OOS 파일에 묶인 sector 를 다른 파일이 가져가지 못한다. 다른 파일의 disk footprint 는 줄지 않는다.

### 검증 3 — 같은 파일 내 슬롯 재사용은 이미 동작 중

`oos_delete_chain` (`oos_file.cpp:1717`) 이 청크 슬롯을 비운 직후 `oos_stats_update` (`oos_file.cpp:1774`) 를 호출해 bestspace 캐시에 해당 페이지의 free space 를 등록한다. bestspace 에 등록되어 있는 동안에는 같은 OOS 파일의 다음 OOS 청크 insert 가 bestspace 후보로 그 페이지를 받아 슬롯을 재사용할 수 있다. 이 부분은 본 이슈 보류와 무관하게 그대로 동작한다.

다만 bestspace 는 캐시이므로 memory budget 초과나 server restart 의 cold start 직후엔 evict 되어 잊혀진다. eviction 이후의 해당 페이지는 새 insert 의 후보로 잡히지 못하고 dead 슬롯들이 살아 있는 상태로 남는다. 본 이슈를 구현하면 이 evict-후-잊힘 페이지를 `file_dealloc` 으로 정리할 수 있긴 하나, 검증 2 에 따라 그 sector 는 같은 파일에 묶인 채라 다른 파일로 흘러가지 않는다. evict-후-잊힘 시나리오가 실측상 누적되는지 모르는 상태에서 본 이슈를 구현하는 것은 측정값 없는 최적화에 해당한다.

### 부활 시 재활용 가능한 설계 메모

부활 시점에 다음 결정이 필요하다. 1 차 draft 의 Open Design Questions 를 현 검증 결과로 정리한 것이다.

- **Q1. vacuum worker 의 transaction 컨텍스트에서 `RVFL_DEALLOC` postpone 의 정상 run 가능 여부**: permanent file 의 `file_dealloc` 은 `RVFL_DEALLOC` postpone 으로 deferred dealloc 을 등록한다 (검증 2). vacuum worker 의 outer transaction / sysop 종료 시점에 그 postpone 이 정상 run 되는지, vacuum 의 호출 컨텍스트가 postpone 메커니즘이 요구하는 transaction 상태를 만족하는지 확인이 필요하다.
- **Q2. helper 호출 batch 단위 (per-record / per-page / per-block)**: vacuum 의 호출 빈도와 회수 latency 의 트레이드오프. SA_MODE eager 경로는 per-UPDATE 고정이 자연스럽다.
- **Q3. touched VPID 집합 컨테이너**: small-N (한 자릿수에서 수십 개) 가정 시 `std::vector` 와 호출 직전 sort 와 unique 가 메모리 locality 와 단순성에서 유리하다. 실측에서 N 이 커지면 hash 기반으로 재검토한다.
- **Q4. `RVFL_DEALLOC` 의 vacuum / SA_MODE recovery 경로 호환성**: 동일 메커니즘이 SA_MODE crash recovery 와 충돌하지 않는지 확인이 필요하다. SA_MODE 에서는 server-side vacuum 이 없고 SA_MODE 종료 시점에 즉시 cleanup 이 일어나므로, vacuum 이 등록한 postpone 의 timing 과 SA_MODE recovery 의 replay timing 사이 race 가 있는지 검증해야 한다. Q1 과 묶여 있다.
- **Q5. helper idempotency**: 이미 dealloc 된 VPID, 동시 insert 가 재점유한 VPID, sticky first page VPID — 세 케이스를 NO_ERROR 로 흡수하는 가드.

위 Q1 과 Q4 가 가장 load-bearing 한 미결 사항이고 나머지는 구현 디테일이다.

---

## Specification Changes

N/A. 사용자 가시 스펙 변경이 없다. 데이터 회수 동작 변경도 없다.

---

## Implementation

본 이슈 보류로 새 helper 와 caller 추가가 없다. close 와 함께 처리할 minor 코드 정리만 다음과 같다.

- `oos_file.cpp:1007` 의 `oos_remove_page` 와 `oos_file.hpp:80` 의 선언을 삭제한다. caller 가 0 건이고, 부활 시 새 helper 를 설계할 예정이므로 보존 가치가 낮다. 삭제 PR 의 description 에 CBRD-26786 close 를 link 한다.
- `oos_file.cpp:1005` 의 `// TODO: will be called by vacuum when OOS vacuum is implemented` 주석을 위 함수 삭제와 함께 제거한다.
- `oos_file.cpp:1812-1813` 의 `oos_delete` header 주석 ("Empty pages will be reclaimed by vacuum after the transaction commits.") 을 "Empty pages are not reclaimed; see CBRD-26786 for the deferral rationale." 로 갱신한다.

부활 시 재시작 출발점은 위 Description 의 Q1 ~ Q5 항목과 본 이슈 close 직전 commit 의 git history 다.

---

## Acceptance Criteria

- [ ] JIRA 본 이슈를 Resolution: Won't Fix 로 close 한다.
- [ ] close 코멘트에 결정 요지 (3 줄 이내), 본 문서 link, 검증 1 / 2 의 핵심 코드 reference (`file_manager.c:6315-6612`, `oos_file.cpp:1406`) 를 포함한다.
- [ ] `oos_file.cpp:1007` 와 `oos_file.hpp:80` 의 `oos_remove_page` 함수와 선언, `oos_file.cpp:1005` 의 TODO 주석, `oos_file.cpp:1812-1813` 주석 갱신을 한 minor 패치 / 단일 commit 으로 묶어 처리한다. commit message 에 CBRD-26786 reference 를 포함한다.
- [ ] epic CBRD-26583 status 메모에 "페이지 단위 회수는 sector-level reclaim 인프라 도입까지 보류 (CBRD-26786 참조). 슬롯 회수는 영향 없음." 한 줄을 기재한다.
- [ ] 보류 결정에 대해 epic CBRD-26583 owner 의 동의를 JIRA 코멘트로 확보한다.

---

## Definition of done

- [ ] 위 Acceptance Criteria 모든 항목 충족.
- [ ] 본 이슈가 Resolution: Won't Fix 로 close 되고 label / fix version 정리가 끝나 검색 가능 상태로 남는다.

---

## 참고 코드

- `oos_file.cpp:1005-1017` — 미연결 `oos_remove_page` 와 그 위 TODO 주석 (본 이슈 close 시 삭제)
- `oos_file.hpp:80` — `oos_remove_page` 선언 (본 이슈 close 시 삭제)
- `oos_file.cpp:1812-1813` — `oos_delete` header 주석 (본 이슈 close 시 갱신)
- `oos_file.cpp:1717, 1774` — `oos_delete_chain` 과 `oos_stats_update` (슬롯 회수가 보류 결정 후에도 동작하는 근거)
- `oos_file.cpp:1279, 1347, 1406` — OOS read 의 point-access 경로 (검증 1)
- `file_manager.c:6122, 6186` — `file_dealloc` 진입점과 `RVFL_DEALLOC` postpone 등록 (검증 2)
- `file_manager.c:6315-6612` — `file_perm_dealloc` (sector bitmap 처리, `disk_unreserve_ordered_sectors` 미호출 근거)
- `file_manager.c:3890, 4330` — `disk_unreserve_ordered_sectors` 호출처 (3890 은 temp file reservation rollback, 4330 은 `file_destroy`)
- `heap_file.c:4716, 4784-4789` — `heap_remove_page_on_vacuum` 의 chain 갱신 (heap 대조 사례)

---

## Remarks

- 선행 / 관련 이슈:
  - CBRD-26668 — vacuum OOS 통합 (PR #6986). 슬롯 단위 회수 (`oos_delete`) 가 여기서 마무리됐다.
  - CBRD-26715 — vacuum OOS 거짓 양성.
  - CBRD-26608 — DROP TABLE 의 OOS cleanup (파일 단위 reclaim 은 정상 동작 중, 본 이슈와 별개).
  - CBRD-26583 — OOS M2 epic (parent).
- 부활 트리거: disk manager 가 permanent file 의 빈 sector 를 `file_destroy` 외 경로로 반환하는 인프라가 도입되는 시점. 현재 관련 JIRA 미존재.
