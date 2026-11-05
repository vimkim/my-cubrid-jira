# [OOS] OOS 코드의 구조 정리 후보를 조사하고 동작을 바꾸지 않는 작은 PR로 나누어 처리한다

**한 줄 요약**: OOS 리팩토링 후보와 분리한 결함을 추적한다. DF-03의 수정은 미팅에서 commit 후 postpone(A')으로 결정됐고 #8347 보류 해제 이력도 반영한다.

## Issue Triage

**이슈 수행 목적**: OOS 코드의 구조 정리 후보를 정리하고 작은 PR로 나누어 처리한다. PR 하나에는 동작을 바꾸지 않는 정리 하나만 담아, 리뷰어가 PR마다 한 번에 판단할 수 있게 한다.

**이슈 수행 이유**: `feature/oos-merge`의 OOS 코드는 버그 수정 PR이 이어지면서 빠르게 커졌다. `oos_file.cpp` 하나만 4,083줄이다. 같은 코드의 복사본, 쓰이지 않는 코드, 지금 코드와 다른 사실을 적은 주석이 쌓였지만, 이를 한 목록으로 모은 적이 없었다. 또 같은 파일을 고치는 PR 6개가 진행 중이어서, 지금 고칠 수 있는 것과 미뤄야 하는 것을 따로 가려야 했다.

**영향**: 사용자에게 보이는 동작은 바뀌지 않는다. 혜택은 OOS 코드를 고치고 리뷰하는 개발자에게 있다. 복사본 한쪽만 고치는 실수, 틀린 주석을 믿고 하는 수정, 쓰이지 않는 인자를 해석하는 시간이 줄어든다. 조사 중 찾은 결함 후보는 리팩토링 범위에서 분리했다. 그중 CBRD-27237(ROLLBACK한 UPDATE의 원래 OOS 값을 vacuum이 지움)은 기준 commit에서 재현했다.

**이슈 수행 방안**: 후보마다 이 이슈 아래 sub-task 하나와 `feature/oos-merge` 대상 draft PR 하나를 둔다. 아래 7개 sub-task가 그 목록이다. PR들은 서로 독립이다. 병합 여부와 순서는 OOS 유지보수자가 정한다. 아래 결정 항목 중 DF-03은 commit 후 postpone(A')으로 확정했고 #8347 보류도 해제했다. 그 외 미결 항목과 이슈 전체 완료 조건은 유지한다.

## Sub-tasks

| Sub-task | PR | 내용 | CI |
| --- | --- | --- | --- |
| [CBRD-27882](https://jira.cubrid.org/browse/CBRD-27882) | [#8367](https://github.com/CUBRID/cubrid/pull/8367) | 쓰이지 않는 bestspace 매크로와 테스트 bridge, 항상 0인 인자를 지운다. | 5/5 SUCCESS |
| [CBRD-27883](https://jira.cubrid.org/browse/CBRD-27883) | [#8368](https://github.com/CUBRID/cubrid/pull/8368) | OOS 단위 테스트의 중복 helper를 한 header로 모으고, 쓰이지 않는 SQL 테스트 helper를 지운다. | 5/5 SUCCESS |
| [CBRD-27884](https://jira.cubrid.org/browse/CBRD-27884) | [#8369](https://github.com/CUBRID/cubrid/pull/8369) | heap 속성 writer 두 곳에 복사된 LOB 복사 코드를 하나로 합친다. | 5/5 SUCCESS (test_shell flaky 1건, rerun 후 통과) |
| [CBRD-27885](https://jira.cubrid.org/browse/CBRD-27885) | [#8370](https://github.com/CUBRID/cubrid/pull/8370) | OOS header 페이지를 로그 없이 dirty로 표시하는 반복 코드를 하나로 합친다. | 5/5 SUCCESS |
| [CBRD-27886](https://jira.cubrid.org/browse/CBRD-27886) | [#8371](https://github.com/CUBRID/cubrid/pull/8371) | heap 삭제 경로 두 곳에 복사된 OOS 파일 정리 코드를 하나로 합친다. 손상된 header 페이지에서만 생기는 동작 차이 하나를 PR 본문에 밝혔다. | 5/5 SUCCESS |
| [CBRD-27887](https://jira.cubrid.org/browse/CBRD-27887) | [#8372](https://github.com/CUBRID/cubrid/pull/8372) | ALTER 속성 변경 판정에서 같은 모양으로 복사된 플래그 블록 세 개를 하나로 합친다. | 5/5 SUCCESS |
| [CBRD-27888](https://jira.cubrid.org/browse/CBRD-27888) | [#8373](https://github.com/CUBRID/cubrid/pull/8373) | 코드와 맞지 않는 OOS 주석을 바로잡는다. | 5/5 SUCCESS |

실행 코드를 바꾼 PR 6개는 CMake Debug 빌드(`-DUNIT_TEST_OOS=ON`)에서 OOS 관련 ctest 44개를 통과했다. 주석만 바꾼 CBRD-27888은 주석을 뺀 token 비교로 실행 코드 차이가 빈 `if` 하나뿐임을 확인했다. GitHub CI는 OOS 단위 테스트를 빌드하지 않으므로, 단위 테스트 결과는 각 PR 본문에 적었다. 모든 PR은 작성 agent와 독립인 코드 리뷰를 거쳤다. CBRD-27888을 뺀 6개는 독립 재빌드와 재실행도 거쳤다.

## Candidates not turned into PRs

조사한 67개 항목 중 8개를 위 PR 7개로 만들었다. 나머지 59개의 상태는 다음과 같다.

| 상태 | 개수 | 뜻 |
| --- | --- | --- |
| DEFERRED | 18 | 진행 중 PR(#8128, #8299, #8330, #8347, #8350)이나 이 이슈의 #8367, #8368과 같은 코드를 고친다. 그 PR이 병합된 뒤 다시 본다. |
| NEEDS-DECISION | 7 | 기술적으로는 할 수 있지만 유지보수자의 결정이 먼저다. |
| REPORT-ONLY | 29 | 효과가 작거나, 래치와 WAL과 복구 순서를 건드려 위험이 효과보다 크다. |
| REJECTED | 5 | 취향 문제이거나 의도된 코드다. |

아래는 결정 완료 사항과 남은 유지보수자 결정 항목이다. 표의 수치는 2026-11-03 조사 당시 분류를 보존한다.

- DF-03과 #8347(결정 완료). 2026-11-05 공유된 미팅 결과로 CBRD-27237은 commit 후 postpone 알림(A')으로 수정한다. CBRD-27781의 OOS chunk 회수는 확정 뒤 postpone·redo-only 방식으로 진행한다. #8347(CBRD-27841) 보류는 2026-11-03에 이미 해제했으며, 알림 구현 때 실제 생산자·소비자와 recovery index를 함께 정의한다. 이 결정은 결함 구현·검증이나 #8347 병합 완료를 뜻하지 않는다.
- R-34. tier-3 bestspace sync(아래 DF-01)를 사양대로 고칠 것인가, 쓰이지 않는 코드로 보고 지울 것인가. 기존 이슈 [CBRD-27213](https://jira.cubrid.org/browse/CBRD-27213)은 이 sync를 지우고 heap bestspace 재설계 기반으로 바꾸는 방향을 정했다.
- R-05. 운영 코드 호출이 없는 `oos_chunk_exists`, `oos_get_identity_stamp`, `oos_get_length`를 진단 API로 남길 것인가, 테스트 빌드에서만 컴파일할 것인가.
- R-39. `FILE_OOS`의 진단 문자열 "OUT_OF_LINE_OVERFLOW_STORAGE"를 기능 이름(Out-of-row Overflow Storage)에 맞게 바꿀 것인가.
- R-35. `LC_IS_FLUSH_INSERT` 매크로를 일반 insert용과 OOS insert용으로 나눌 것인가.

기록하는 곳이 없는 복구 인덱스 `RVREPL_OOS_DELETE`(R-29)는 새 PR 대신 [#8347](https://github.com/CUBRID/cubrid/pull/8347)(CBRD-27841)에 합치기를 제안한다. #8347은 같은 종류의 인덱스를 지우고 번호를 다시 매기므로, 같이 하면 번호를 두 번 바꾸지 않는다.

시험 삼아 만든 PR 2개는 게시하지 않았다. `heap_oos.cpp`의 scope_exit와 last-error helper(R-15)는 보호할 이른 반환이 없었고 들여쓰기만 늘었다. 이름 있는 테스트 seam(R-11)은 seam 함수 10개를 더해 줄어드는 코드보다 늘어나는 코드가 많았다.

## Defect highlights

리팩토링이 아니라 결함일 수 있는 후보 30개를 따로 기록했다. 우선순위가 높은 네 개는 다음과 같다.

| ID | 내용 | 근거 | 처리 |
| --- | --- | --- | --- |
| DF-03 | ROLLBACK한 UPDATE의 원래 OOS chain을 vacuum이 지운다. 그 행을 읽으면 -1389(`ER_HEAP_OOS_CORRUPTED_RECORD`)가 난다. | 기준 commit에서 재현했다. 단위 테스트 2회 모두 실패, gdb로 `vacuum_forward_walk_reclaim_oos`가 `oos_delete_chain`을 부르는 것을 확인, SQL 대조 실험에서 COMMIT한 행은 정상 | [CBRD-27237](https://jira.cubrid.org/browse/CBRD-27237)에 댓글로 남겼다. |
| DF-01 | `oos_find_best_page`의 tier-3 sync 조건은 sync 안에서만 쓰는 값에 기대므로 참이 될 수 없다. 반쯤 빈 페이지를 다시 찾지 못해 OOS 파일이 커질 수 있다(추론). | 소스 확인. OOS 테스트 바이너리 36개를 gdb로 실행했을 때 sync-scan 지점 0회 | 기존 이슈 [CBRD-27213](https://jira.cubrid.org/browse/CBRD-27213)이 다룬다. |
| DF-02 | demotion 기준이 사양의 `heap_oos_inline_target_size()`(16 KB 페이지에서 4,060 B)가 아니라 `DB_PAGESIZE / 4`(4,086 B)다. | 소스 확인. CBRD-27057은 Resolved지만 그 구현 draft #7462는 병합되지 않고 닫혔다. | [CBRD-27057](https://jira.cubrid.org/browse/CBRD-27057) 댓글대로 [#8299](https://github.com/CUBRID/cubrid/pull/8299)(CBRD-27785)의 commit `4c3c8d791`이 고친다. |
| DF-04 | `oos_find_best_page`의 이른 fallback이 header 조회 실패 에러(`ER_INTERRUPTED` 포함)를 버리고 새 페이지를 할당한다. | 소스 확인. 다루는 이슈 없음(JQL 검색) | 새 버그 후보. 관련 리팩토링(R-22)보다 먼저 고친다. |

DF-03의 확인하지 않은 범위는 kill -9 뒤 복구, savepoint rollback, release 빌드다.

2026-11-03 추가: 닫힌 PR #7614(CBRD-26831)와 비교해 R-71(여러 sector 통계 테스트)과 DF-31(`SHOW HEAP OOS` 경로의 `ER_INTERRUPTED` 소실)을 조사 문서에 더했다.

---

## AI-Generated Context

> 아래는 제공된 자료와 확인한 근거를 바탕으로 작성한 상세 맥락이다. 미확인 사항은 본문에 구분한다.

기준 소스는 CUBRID/cubrid `feature/oos-merge`의 `dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67`이다. 조사하는 동안 이 commit은 바뀌지 않았다. 작성일은 2026-11-03 (Asia/Seoul)이다.

조사는 네 단계로 진행했다.

1. 읽기 전용 agent 다섯 개가 OOS 코드를 다섯 구역(bestspace와 회수, insert와 read와 delete, heap 연동, vacuum과 로그와 복구, 단위 테스트)으로 나누어 읽고 원시 후보 70개를 냈다.
2. 판정 agent가 중복을 합쳐 67개 항목으로 정리하고, 결함 후보 30개를 분리했다. PR 대기열 항목의 핵심 주장은 기준 commit에서 다시 확인했다.
3. 30분마다 기준 commit과 진행 중 PR 목록의 변화를 확인하고, 다음 PR 후보의 근거를 코드에서 다시 읽었다.
4. PR마다 owner agent가 구현하고, 독립 review lane과 gate lane이 같은 head SHA에서 판정했다. PR은 한 시간에 하나만 열었다.

한계는 다음과 같다. 후보 조사 자체는 정적 읽기다. HA, 복제, sql.log 경로는 단위 테스트와 CI 어디에도 없어 실행으로 확인하지 않았다. #8299가 다시 쓰는 heap read 경로와 demotion planner는 조사하지 않았다. 성능은 측정하지 않았다.

완료 조건으로 다음을 제안한다. sub-task PR 7개가 병합되거나 닫히고, NEEDS-DECISION 항목마다 결정이 기록되면 이 이슈를 닫는다. DEFERRED 항목은 막고 있는 PR이 병합된 뒤 새 sub-task로 다시 본다.

항목별 근거, DEFERRED와 REPORT-ONLY 전체 목록, 결함 후보 30개의 표는 담당자의 분석 문서(my-cubrid-docs의 `cbrd-27881/CBRD-27881-oos-refactoring-candidates_dcbf09e_claude.md`)에 정리했다.
