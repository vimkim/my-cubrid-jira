# [OOS] vacuum 의 OOS 빈 페이지 file_dealloc 회수 보류 — sector-reclaim 인프라 의존성 (슬롯 삭제는 무관)

## Issue Triage

**이슈 수행 목적**: 본 이슈가 다루는 페이지 단위 `file_dealloc` 회수 단계를 보류 (Won't Fix / Defer) 하고 그 근거를 본문에 남긴다. 슬롯 단위 데이터 회수 (`oos_delete`, CBRD-26609 / CBRD-26668) 는 이 결정과 무관하며 그대로 동작한다 — 본 보류는 페이지/sector 회수에만 한정된다.

**이슈 수행 이유**:

- **현재 동작 / 배경**:
  - 슬롯 단위 데이터 회수: vacuum 이 dead OOS slot 을 `oos_delete` (`oos_file.cpp` 의 entry point) 로 지운 뒤 `oos_delete_chain` 안에서 `oos_stats_update` (`oos_file.cpp:1774`) 를 호출해 bestspace 캐시의 free space 통계를 갱신한다 — 정상 작동 중. CBRD-26609 / CBRD-26668 로 마무리.
  - 페이지 단위 회수 (본 이슈 원래 범위): `oos_remove_page` (`oos_file.cpp:1007`, header `oos_file.hpp:80`) 가 `file_dealloc(... FILE_OOS)` 호출 본문을 가지고 있으나 caller 가 0 건 — `grep oos_remove_page` 결과 선언/정의 2 건만 잡힘. 바로 위 `oos_file.cpp:1005` 의 `TODO: will be called by vacuum when OOS vacuum is implemented` 주석이 미완 상태를 명시한다.
  - sector 반환 경로 부재: `file_dealloc` (`file_manager.c:6122`) 은 permanent file 에 `RVFL_DEALLOC` postpone 만 등록하고 (line 6186), 실제 dealloc 은 `file_perm_dealloc` (`file_manager.c:6315-6612`) 이 run-postpone 시점에 수행한다. `file_perm_dealloc` 은 sector bitmap 의 페이지 비트 clear, sector 가 full 이었으면 partial table 로 이동만 수행한다. `is_empty == true` 분기에서도 `disk_unreserve_ordered_sectors` 를 호출하지 않는다 — 호출처는 file 통째 destroy 경로의 `file_destroy` (`file_manager.c:4330`) 뿐. 즉 dealloc 한 페이지의 sector 는 그 파일 안에 묶여 있고, 다른 파일이 그 sector 를 가져가는 경로는 존재하지 않는다.
  - 접근 모델: OOS 는 OOS OID 의 (volid, pageid) 로의 point-access 만 한다 — `oos_read` (`oos_file.cpp:1406`) -> `oos_read_within_page` (`oos_file.cpp:1347`), 다중 청크는 `oos_read_across_pages` (`oos_file.cpp:1279`) 가 청크 체인을 따라간다. heap 의 `prev_vpid` / `next_vpid` 같은 chain 순회 구조는 없다.

- **영향** — 다음 다섯 카테고리 모두에서 본 이슈 구현으로 얻을 이득이 측정 가능한 수준에 미치지 못한다:
  - **고객 장애**: 없음. 사용자 가시 SQL 동작과 데이터 회수에 영향이 없고, 슬롯 회수 정상 동작으로 OOS 파일은 무한히 새 데이터를 받을 수 있다.
  - **QA 실패**: 없음. 현재 회귀 시나리오에서 빈 OOS 페이지 누적이 fail 을 일으키는 케이스가 보고되지 않았다.
  - **성능 저하**: 측정 가능한 저하가 없다. heap 처럼 sequential scan 으로 빈 페이지를 walk 하는 경로가 OOS 에는 없으므로 (point-access 모델), 빈 페이지가 매달려 있어도 query 비용 증가가 없다.
  - **설계 의도 훼손**: 부분적이지만 손실 미미. `oos_delete` header 주석 (`oos_file.cpp:1812-1813`) 의 "Empty pages will be reclaimed by vacuum after the transaction commits." 라는 design intent 가 미충족 상태로 남는다. 다만 이 intent 가 가정한 "회수 = sector 가 disk 로 돌아감" 자체가 현 disk manager 구조에서 성립하지 않으므로, 본 이슈를 구현해도 그 intent 의 본래 목적은 달성되지 않는다.
  - **기술 부채**: 부활 조건이 외부 인프라 (disk manager sector-level reclaim) 의존이므로 본 이슈 자체가 부채라기보다는 그 외부 인프라의 후속 작업이다. 단, dead 함수 `oos_remove_page` 와 그 TODO 주석이 코드에 남아 있는 것은 작은 부채로, 본 이슈 close 시 함께 정리한다 (AC 참조).

**이슈 수행 방안**:

- 본 이슈를 Resolution: Won't Fix 로 close. JIRA close 코멘트에 결정 요지와 본 문서 link 를 남긴다.
- 보류 범위 명시: 슬롯 단위 회수 (`oos_delete`) 는 본 결정 범위 밖이며 정상 동작 유지. 본 이슈는 페이지 단위 `file_dealloc` (`oos_remove_page` 의 caller 추가) 만 보류.
- 코드 정리: `oos_remove_page` (`oos_file.cpp:1005-1017`, 헤더 `oos_file.hpp:80`) 와 위 `TODO` 주석을 본 이슈 close 와 함께 처리. `oos_delete` 의 `oos_file.cpp:1812-1813` 주석도 "deferred, see CBRD-26786" 로 갱신. 구체 처리 (삭제 / `[[maybe_unused]]` / 주석 갱신만) 는 AC 에서 결정.
- 부활 트리거: disk manager 의 sector-level reclaim 인프라 (permanent file 의 빈 sector 를 file-destroy 외 경로로 disk manager 에 반환) 가 도입되는 시점에 본 이슈를 link 로 부활. 현재 관련 JIRA 미존재.
- 모니터링은 본 방안에서 제외. 별도 측정 항목은 후속 진단 이슈가 필요하면 그때 분리해 만든다 (본 이슈에 매단 채 두면 unactionable TBD 가 된다).

상세 검증 / 부활 시 재활용할 설계 메모는 아래 AI-Generated Context 섹션 참조.

---

## AI-Generated Context

> 아래 내용은 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 **Issue Triage** 블록만으로 충분하며, 본문은 보류 결정의 근거 확인 및 향후 부활 시 출발점으로 참조하면 된다.

### Summary

- **문제 / 목적**: 페이지 단위 OOS 회수 (`file_dealloc`) 도입의 실효성을 코드 사실관계로 검증해 보류 여부를 확정.
- **원인 / 배경**: 원안의 motivation (다른 파일로의 sector 재할당, 페이지 누적 회피) 이 현 disk manager / OOS 접근 모델과 어긋남.
- **제안 / 변경**: 페이지 회수 단계만 보류. 슬롯 회수는 무관하게 정상 동작. dead 함수와 미완 주석은 close 시 함께 정리.
- **영향 범위**: 코드 변경은 `oos_file.cpp` (`oos_remove_page` 처리 + 주석 갱신) 의 minor 한 줄. 사용자 가시 변경 없음. epic CBRD-26583 의 status 메모 한 줄.

---

## Description

### 보류 결정의 발단

본 이슈의 1 차 draft 는 vacuum 이 OOS 슬롯을 다 비운 페이지를 `file_dealloc` 으로 회수하는 helper (`oos_try_reclaim_empty_page`) 신설을 제안했다. 리뷰어가 triage 전에 다음을 지적했다 (요지 — 원문에 가까운 paraphrase):

> heap 의 빈 페이지 제거는 heap scan 비용 때문이라 정당화되지만 OOS 는 scan 자체가 없어 그 시나리오에 해당하지 않는다. "다른 파일에서의 재사용" 도 sector 를 disk manager 에 반환해야 성립하는데 현재 그 메커니즘이 없는 것으로 안다. triage 전에 확인 후 의견 달라.

코드로 두 지적을 검증한 결과 둘 다 정확했다. 본 이슈는 페이지 회수 단계만 보류로 결정하고, 그 결정과 분리된 슬롯 회수 동작은 그대로 둔다.

### 검증 1 — OOS scan 부재

OOS 의 모든 read 경로는 caller 가 미리 알고 있는 OOS OID 의 (volid, pageid, slotid) 로의 point-access 다.

- 단일 청크: `oos_read` (`oos_file.cpp:1406`) 가 `oos_read_within_page` (`oos_file.cpp:1347`) 를 호출, 후자가 OID 의 (volid, pageid) 로 직접 `pgbuf_fix`.
- 다중 청크: 첫 청크의 header 에서 다음 청크의 OID 를 꺼내 `oos_read_across_pages` (`oos_file.cpp:1279`) 가 chained point-access 로 순차 fetch.
- 진입점: caller 는 heap 레코드의 variable area 에서 OOS OID 를 꺼내 들어온다 (`heap_file.c:10652` 의 `oos_read` 호출).

대조 케이스로 `heap_remove_page_on_vacuum` (`heap_file.c:4716`) 가 빈 heap 페이지를 떼어내는 작업의 본체는 `prev_vpid` / `next_vpid` 의 chain 링크 재연결이다 (`heap_file.c:4784-4789` 의 `heap_vpid_prev` / `heap_vpid_next` 호출, 그 후 chain 갱신 블록). heap 에서 빈 페이지 제거가 정당화되는 이유가 바로 이 chain 을 heap scan 이 walk 하기 때문인데, OOS 에는 이 chain 자체가 없다.

결론: heap 식 "빈 페이지가 scan 비용을 키운다" 모델은 OOS 에 적용 불가.

### 검증 2 — permanent file 의 sector 가 disk manager 로 돌아가지 않음

`file_dealloc` (`file_manager.c:6122`) 의 permanent file 분기는 `RVFL_DEALLOC` postpone record 만 등록한다 (`file_manager.c:6186` 의 `log_append_postpone`). 실제 dealloc 은 run-postpone 시점에 `file_perm_dealloc` (`file_manager.c:6315-6612`) 이 수행하며, 그 동작은:

- sector bitmap 의 페이지 비트 clear (`file_manager.c:6376`, `file_partsect_clear_bit`).
- was_full 이었던 sector 면 full table 에서 제거하고 partial table 로 이동 (`file_manager.c:6402-` else 분기).
- `is_empty = file_partsect_is_empty (partsect)` (`file_manager.c:6377`) 로 sector 가 모두 비었는지 판정.
- `file_header_dealloc` (`file_manager.c:6580`) 으로 파일 헤더 통계만 갱신.
- `pgbuf_dealloc_page` (`file_manager.c:6599`) 로 페이지 버퍼만 비움.

`disk_unreserve_ordered_sectors` 는 어디서도 호출되지 않는다 — `is_empty == true` 분기에서도 그렇다. `file_manager.c` 내 호출처 전수 (`grep`):

- `file_manager.c:3890` — `file_create` 의 reservation rollback 경로 (DB_TEMPORARY_DATA_PURPOSE).
- `file_manager.c:4330` — `file_destroy` (`file_manager.c:4119-4128`) 의 cleanup. `file_destroy` 는 `bool is_temp` 인자로 permanent / temp 양쪽을 모두 다루므로 line 4330 자체는 "비-temp 전용" 이 아닌 "destroy 전용".

즉 permanent file 한 페이지를 dealloc 한 결과로 sector 가 disk manager 로 돌아가는 경로는 `file_destroy` 한 곳뿐이다. 한 페이지를 회수해도 그 sector 는 그 파일의 partial table 에 남아 같은 파일의 다음 `file_alloc` 요청에만 재사용된다.

결론: 본 이슈를 구현해도 OOS 파일에 묶인 sector 는 다른 파일이 못 가져간다. 다른 파일의 disk footprint 는 줄지 않는다.

### 검증 3 — 같은 파일 내 슬롯 재사용은 이미 동작 중

`oos_delete_chain` (`oos_file.cpp:1717`) 이 청크 슬롯을 비운 직후 `oos_stats_update` (`oos_file.cpp:1774`) 를 호출해 bestspace 캐시에 해당 페이지의 free space 를 등록한다. 같은 OOS 파일의 다음 OOS 청크 insert 가 bestspace 후보로 그 페이지를 받아 슬롯을 재사용한다 — 이 부분은 본 이슈 보류와 무관하게 그대로 동작한다.

다만 페이지 단위로 보면 의존성이 있다: bestspace 엔트리는 캐시이므로 memory budget 초과나 server restart 의 cold start 직후엔 evict 되어 잊혀질 수 있다. 그 시점 이후 같은 페이지의 dead 슬롯들은 새 insert 가 찾아 들어가지 못하고 살아 있는 상태로 남는다. 본 이슈를 구현하면 이런 evict-후-잊힘 페이지를 `file_dealloc` 으로 정리할 수 있긴 하나, 그래도 sector 는 같은 파일에 묶인 채라 footprint 가 다른 파일로 흘러가지는 않는다 (검증 2). 즉 evict-후-잊힘 시나리오가 실측상 누적되는지 모르는 상태에서 본 이슈를 구현하는 것은 측정값 없는 최적화에 해당한다.

### 부활 시 재활용 가능한 설계 메모

부활 시점에 다음 결정이 필요하다 (1 차 draft 의 Open Design Questions 를 현 검증 결과로 정리).

- **Q1. file_dealloc 의 postpone 처리와 vacuum worker 의 transaction 모델 호환성**: permanent file 의 `file_dealloc` 은 `RVFL_DEALLOC` postpone 으로 deferred dealloc 을 등록한다 (검증 2). 그러면 sysop "안" 이냐 "밖" 이냐는 부분적으로 postpone 메커니즘이 결정한다. 남는 질문은 vacuum worker 의 outer transaction / sysop 종료 시점에 그 postpone 이 정상 run 되는지, SA_MODE crash 후 recovery 가 vacuum 의 postpone 와 충돌하지 않는지.
- **Q2. helper 호출 batch 단위 (per-record / per-page / per-block)**: vacuum 의 호출 빈도 / 회수 latency 트레이드오프. SA_MODE eager 경로는 per-UPDATE 고정이 자연스럽다.
- **Q3. touched VPID 집합 컨테이너**: small-N (한 자릿수 ~ 수십 개) 가정 시 `std::vector` + 호출 직전 sort + unique 가 메모리 locality 와 단순성에서 유리. 실측 결과 N 이 커지면 hash 기반으로 재검토.
- **Q4. `RVFL_DEALLOC` 의 vacuum / SA_MODE recovery 경로 검증**: postpone 가 vacuum worker context 에서 run 되는 시점, SA_MODE active 트랜잭션 도중 호출 시 abort/commit semantics, `FILE_OOS` 자체의 recovery 호환성. Q1 과 묶여 있음.
- **Q5. helper idempotency**: 이미 dealloc 된 VPID, 동시 insert 가 재점유한 VPID, sticky first page VPID — 세 케이스를 NO_ERROR 로 흡수하는 가드.

위 Q1 / Q4 가 가장 load-bearing 한 미결 사항이고 나머지는 구현 디테일이다.

---

## Specification Changes

N/A. 사용자 가시 스펙 변경 없음. 데이터 회수 동작에 변경 없음.

---

## Implementation

본 이슈 보류로 새 helper / caller 추가 없음. close 와 함께 처리할 minor 코드 정리만:

- `oos_file.cpp:1007` 의 `oos_remove_page` 와 `oos_file.hpp:80` 의 선언: 삭제 (caller 0 건, 부활 시 새로 helper 를 설계할 예정이므로 보존 가치 낮음). 삭제 PR 의 description 에 CBRD-26786 close 를 link.
- `oos_file.cpp:1005` 의 `// TODO: will be called by vacuum when OOS vacuum is implemented`: 위 함수 삭제와 함께 제거.
- `oos_file.cpp:1812-1813` 의 `oos_delete` header 주석 ("Empty pages will be reclaimed by vacuum after the transaction commits."): "Empty pages are not reclaimed; see CBRD-26786 for the deferral rationale." 로 갱신.

부활 시 재시작 출발점은 위 `## Description` 의 Q1-Q5 와 본 이슈 close 직전 커밋의 git history.

---

## Acceptance Criteria

- [ ] JIRA 본 이슈를 Resolution: Won't Fix 로 close.
- [ ] close 코멘트에 결정 요지 (3 줄 이내) + 본 문서 link + 검증 1 / 2 의 핵심 코드 reference (`file_manager.c:6315-6612`, `oos_file.cpp:1406`) 포함.
- [ ] `oos_file.cpp:1007` / `oos_file.hpp:80` 의 `oos_remove_page` 함수 삭제 + `oos_file.cpp:1005` TODO 주석 삭제 + `oos_file.cpp:1812-1813` 주석 갱신 — 세 항목을 한 minor 패치로 묶어 별도 commit, commit message 에 CBRD-26786 reference.
- [ ] epic CBRD-26583 status 메모에 "페이지 단위 회수는 sector-level reclaim 인프라 도입까지 보류 (CBRD-26786 참조). 슬롯 회수는 영향 없음." 한 줄 기재.
- [ ] 보류 결정에 대해 원 지적자 (리뷰어) 의 동의 확보 — JIRA 코멘트로 ack.

---

## Definition of done

- [ ] 위 A/C 충족.
- [ ] 본 이슈가 Resolution: Won't Fix 로 close 되어 검색 가능 상태 유지 (label / fix version 정리).

---

## 참고 코드

- `oos_file.cpp:1005-1017` — 미연결 `oos_remove_page` 와 그 위 TODO 주석 (본 이슈 close 시 삭제)
- `oos_file.cpp:1812-1813` — `oos_delete` header 주석 (본 이슈 close 시 갱신)
- `oos_file.cpp:1717, 1774` — `oos_delete_chain` + `oos_stats_update` (슬롯 회수가 보류 결정 후에도 동작하는 근거)
- `oos_file.cpp:1279, 1347, 1406` — OOS read 의 point-access 경로 (검증 1)
- `file_manager.c:6122, 6186` — `file_dealloc` 진입점 + `RVFL_DEALLOC` postpone 등록 (검증 2)
- `file_manager.c:6315-6612` — `file_perm_dealloc` (sector bitmap 처리, `disk_unreserve_ordered_sectors` 미호출 근거)
- `file_manager.c:3890, 4330` — `disk_unreserve_ordered_sectors` 의 두 호출처 (3890 = temp rollback, 4330 = file_destroy)
- `heap_file.c:4716, 4784-4789` — `heap_remove_page_on_vacuum` 의 chain 갱신 (heap 대조 사례)

---

## Remarks

- 선행 / 관련 이슈:
  - CBRD-26609 — `oos_delete` API 도입. 슬롯 단위 회수가 여기서 마무리됨.
  - CBRD-26668 — vacuum OOS 통합 (forward-walk + REMOVE path). vacuum 이 `oos_delete` 를 호출하는 경로가 여기서 연결됨.
  - CBRD-26715 — vacuum OOS 거짓 양성.
  - CBRD-26608 — DROP TABLE 의 OOS cleanup (파일 단위 reclaim 은 정상 동작 중, 본 이슈와 별개).
  - CBRD-26583 — OOS M2 epic (parent).
- 부활 트리거: disk manager 의 sector-level reclaim 인프라 도입. 현재 관련 JIRA 미존재.
