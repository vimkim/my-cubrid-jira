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

## 2026-11-11 추가 조사. PR #7990 기준 신규 후보와 선행조건 갱신

이번 조사의 목적은 `develop` 대상 `feature/oos-merge` PR에서 동작을 보존하는 정리 후보를 찾아, 사람이 나중에 sub-task를 고를 수 있게 하는 것이다. 기존 본문과 R·DF 항목의 의미, 당시 집계와 검증 기록은 보존한다. 이번 추가분은 신규 후보 2건과 기존 항목의 선행조건 변화다. sub-task 선정이나 구현 완료를 뜻하지 않는다.

고정 head는 `50619ce53ef7b0e6bc8b468b2065ae7da4ef592f`, base와 merge-base는 `2dd94e32ab86a756b0f1ea2123ad7d2ac913321b`이다. 별도 조사 checkout에서 `git diff BASE...HEAD`를 기준으로 storage, heap·DML, recovery·replication, schema·tests를 나누어 읽었다. 합성 단계에서 신규 후보의 본문과 호출부, 초기화, 기존 R·DF 목록을 다시 확인했다. 원래 작업 checkout의 미게시 postpone 변경은 조사 기준에 섞지 않았다.

OOS는 heap의 24바이트 stub과 별도 value chain을 연결한다. 정리할 때도 저장 바이트, 참조의 수명, WAL과 latch 순서를 보존해야 한다. storage와 recovery의 눈에 띄는 중복은 이미 기존 목록에 있거나 accepted reclaim 설계가 교체할 코드였다. 따라서 이번 신규 후보는 기존 parser helper 재사용과 테스트 변환 중복 제거로 좁혔다.

### 신규 후보 2건

| ID | 현재 구조와 가장 작은 변경 | 이득과 비용 | 중복 판정과 선택 조건 |
| --- | --- | --- | --- |
| N-20261111-01 | `attr_def_one`의 CLASS·SHARED STORAGE 거부 블록이 `parser_reject_non_normal_attr_storage`와 같은 오류와 UNSET 복원을 반복한다. inline 블록을 기존 helper 호출로 바꾼다. | namespace 제한을 고칠 곳이 한 곳으로 줄어든다. 변경은 작지만 Bison 재생성과 오류 순서 비교가 필요하다. | R-09는 `execute_schema.c`의 ALTER 플래그 구성, R-60은 schema flag mask이므로 별개다. clause mask와 `attr_storage != UNSET`의 동치가 오류 복구 경로에서도 유지되는지 먼저 확인한다. |
| N-20261111-02 | `fetch_single_int`와 `get_int_column`이 INTEGER·BIGINT·SHORT 변환을 반복한다. 기존 `get_int_column`을 SQL 공용 header로 옮기고, cursor를 위치시킨 `fetch_single_int`가 column 0에 이를 호출한다. | 변환 규칙을 한 곳에서 관리한다. 테스트 helper에만 영향을 주지만 공용 header를 쓰는 SQL 테스트를 다시 빌드해야 한다. | R-06·R-07과 #8368이 정리한 helper와 다른, 현재 남아 있는 중복이다. fixture 상속을 다루는 R-31과도 별개다. 테스트 기반 정리부터 고른다면 이 항목을 먼저 권한다. |

두 후보 모두 새 계층이나 범용 framework를 추가할 필요가 없다. N-20261111-01은 parser의 조건 동치 확인을 통과한 뒤 선택할 조건부 후보다. N-20261111-02는 SQL 실행과 result 종료 책임을 기존 호출자에게 그대로 두는 범위로 제한한다.

| ID | 보존할 동작과 영향 모드 | 구현 때 수행할 검증. 이번 조사에서는 미실행 |
| --- | --- | --- |
| N-20261111-01 | 동일한 namespace 거부, 오류 코드·문구·순서, `attr_storage`의 UNSET 복원을 보존한다. 중복 clause 검사용 `COLUMN_CONSTRAINT_STORAGE`와 ALTER의 뒤늦은 namespace 검사도 유지한다. SA와 CS의 client-side parser가 대상이다. 저장 형식이나 실행 계층의 STORAGE 허용 정책은 바꾸지 않는다. | parser를 재생성·빌드하고 grammar conflict 차이를 확인한다. `test_oos_sql_storage`를 실행한다. 현재 grammar의 PREFER_INLINE, FORCE_OUTLINE, DEFAULT, PREFER_OUTLINE 각각에 대해 일반·SHARED·CLASS 속성의 CREATE와 ALTER MODIFY·CHANGE, 생략·중복 clause·구문 오류를 원본과 비교한다. SA와 CS에서 오류 코드·문구·우선순위와 허용 결과를 확인한다. |
| N-20261111-02 | INTEGER·BIGINT·SHORT의 기존 `int` cast, NULL·다른 타입의 `ER_FAILED`, tuple fetch 오류 반환, `out_val`을 쓰는 조건을 보존한다. 현재 `DB_VALUE` 정리 분기와 `db_query_end` 호출 책임도 유지한다. SA SQL 테스트가 대상이며 기존 compile guard를 유지한다. | 모든 OOS SQL 테스트 target을 재빌드한다. `test_oos_sql_show`, `test_oos_sql_deferred_write`, `test_oos_sql_txn`을 실행한다. 세 정수 타입, 큰 BIGINT의 기존 cast 결과, NULL·다른 타입, fetch 실패와 빈 결과의 반환값·출력값·result 종료를 원본과 비교한다. 오류 처리 개선은 같은 변경에 섞지 않는다. |

### 기존 항목의 달라진 선행조건

아래 포함 여부는 고정 head의 Git ancestry와 소스에 관한 확인이다. live GitHub의 merged·closed·draft 상태나 JIRA 완료 상태를 뜻하지 않는다. 이 추가분을 선정할 때는 실제 대상 revision과 live workflow를 다시 확인한다.

| 기존 항목 | 고정 head에서 확인한 변화 | 남은 조건 |
| --- | --- | --- |
| R-18, R-21 | #8330의 `902fe1452`가 head의 ancestor다. 해당 PR과의 미통합 충돌을 전제로 한 기존 보류 사유는 해소됐다. cache 제거와 검색 복합 책임은 남아 있다. | CBRD-27213 재설계 뒤에도 helper 정리가 유효한지 먼저 판단한다. mutex 보유 시간, hash 갱신, 후보 순서와 write-latch 인계를 보존해야 한다. |
| R-22 | 같은 #8330 ancestry는 확인했다. 이른 header-fix fallback은 아직 오류를 버리는 구조다. | DF-04를 다루는 CBRD-28017 수정이 먼저다. 기존 본문의 "다루는 이슈 없음"은 2026-11-03 기록이다. 오류 소실을 보존하는 통합이나 오류 수정을 refactor로 포장하지 않는다. |
| R-28 | #8330 소스는 포함됐다. | R-13·R-42·R-43과 accepted reclaim 변경의 영향을 먼저 확인한다. bestspace와 reclaim은 mutex를 공유하므로 파일 분리만으로 책임이 분리되지는 않는다. |
| R-13 | #8367의 `0f51cd24b`가 ancestor다. 공개 header의 내부 hint 타입은 남아 있다. | 모든 사용자와 저장 layout을 확인한 뒤 재선정한다. 내부 정의 이동은 field 순서·크기·정렬·기존 bytes를 보존한다. accepted ADR-0008이 바꿀 chunk header를 현재 형식으로 고정하는 일과 구분한다. |
| R-16 | #8368의 `f3215feef`가 ancestor이고 공용 `test_oos_utils.hpp`가 존재한다. 기존 "공용 header가 생긴 뒤" 선행조건은 충족됐다. | 현재 남은 page·chunk helper 중복과 이동의 이득을 재조사한다. 이번 조사에서 해당 범위의 구현안이나 완료를 판정하지 않았다. |
| R-26 | #8350의 `d52b1889e`가 ancestor다. 기존 두 선행 PR 중 하나의 소스가 포함됐다. | #8299 의존과 RECDES helper의 실제 이동 범위를 다시 확인한다. 즉시 착수 가능하다는 판정은 아니다. |
| R-29 | `RVREPL_OOS_DELETE`의 enum, null-handler entry와 TDE 분류는 남아 있고 `src` 안의 emitter는 발견하지 못했다. | #8347에 묶자는 과거 제안은 accepted postpone·notification 구현과 함께 다시 정한다. `RVOOS_NOTIFY_VACUUM`은 accepted 설계가 필요로 하므로 미사용이라는 이유로 함께 지우지 않는다. index 삭제·재번호 부여는 별도 형식 변경 범위를 명시하고 SERVER·SA 복구 table, TDE, HA, crash/restart를 검증해야 한다. |

R-01·R-10·R-12·R-14의 결과물도 이 head에 포함되어 있다. 각각 `0f51cd24b`, `90fb67265`, `9ee0e616b`, `f67f2f692`의 ancestry와 현재 소스로 확인했다. 같은 작업을 신규 후보로 다시 세지 않는다. R-14의 과거 PR은 손상된 heap header에서의 동작 차이를 밝혔으므로 엄밀한 동작 보존 사례로 인용하지 않는다.

### 이번 추가분에서 제외한 것과 한계

24바이트 stub codec은 R-25, payload 소유권은 R-54, CMake 등록은 R-30, 복제 emitter와 descriptor 상태는 R-24·R-33, log-applier 정리는 R-56부터 R-61에 이미 있다. 작은 helper를 다시 제안해 기존 항목 수를 늘리지 않았다.

DF-02의 demotion target과 DF-03의 rollback·vacuum 문제는 결함 또는 사양 적합성 작업이다. accepted ADR-0008의 postpone·redo-only reclaim, continuation identity, tail-first 삭제도 새 동작을 구현하는 범위다. fixed head에 남은 구현과 accepted 요구를 구분한다. FORCE_INLINE과 fixed-type DEFAULT의 허용 차이도 parser 중복 제거에 섞지 않는다.

결과는 정적 조사 PASS이며 런타임 동작 보존 PASS가 아니다. 신규 소스 변경, 빌드, SQL, 단위 테스트, HA, 복구, fault injection, 동시성·성능 검증은 수행하지 않았다. 조사 checkout에는 build directory와 `compile_commands.json`이 없었다. 기존 본문의 44개 ctest와 CI 성공은 과거 revision의 검증 기록이며 이번 head나 신규 후보의 실행 근거로 재사용하지 않는다.

### 신규 후보 근거 manifest

모든 소스 행은 head `50619ce53ef7b0e6bc8b468b2065ae7da4ef592f` 기준이다.

| 후보 | 직접 재확인한 anchor |
| --- | --- |
| N-20261111-01 | [csql_grammar.y 10187행](https://github.com/CUBRID/cubrid/blob/50619ce53ef7b0e6bc8b468b2065ae7da4ef592f/src/parser/csql_grammar.y#L10187)의 inline 거부, `:23578`의 공용 helper, `:6520`·`:6545`의 ALTER 호출, `:10251`의 중복 clause 검사, `:10717` 이후 네 STORAGE production. `src/parser/parse_tree_cl.c:2519`의 node zero 초기화와 `:7114`의 attribute 초기화. `src/parser/parse_tree.h:2024`의 UNSET enum. |
| N-20261111-02 | [test_oos_sql_common.hpp 137행](https://github.com/CUBRID/cubrid/blob/50619ce53ef7b0e6bc8b468b2065ae7da4ef592f/unit_tests/oos/sql/test_oos_sql_common.hpp#L137)의 tuple 읽기와 `:144` 이후 변환, `unit_tests/oos/sql/test_oos_sql_heap_fixture.hpp:70`의 `get_int_column`, `unit_tests/oos/sql/test_oos_sql_show.cpp:104`와 `test_oos_sql_deferred_write.cpp:463`의 소비자, `unit_tests/oos/sql/CMakeLists.txt:23` 이후 SA target 정의. |

중복 판정에는 기존 `CBRD-27881-oos-refactoring-candidates_dcbf09e_claude.md`와 2026-11-11에 저장한 JIRA 본문을 사용했다. accepted 요구는 2026-11-09판 `OOS-CONTEXT.md`, SHA-256 `426f294420285381835a0e733b12bde9ed2ffa14dfdd6264db5e3c33894f533d`를 기준으로 구분했다. 이 추가분은 기존 본문 끝에 붙일 내용이며, 과거 본문이나 담당자의 결정 기록을 교체하지 않는다.

## 2026-11-11 후속 확인. 담당자 결정과 기존 후보의 범위

아래는 기존 항목의 상태와 구현 선행조건을 구체화한 기록이다. 신규 후보나 sub-task를 추가하지 않는다. 소스 판단은 위와 같은 head `50619ce53ef7b0e6bc8b468b2065ae7da4ef592f`, base `2dd94e32ab86a756b0f1ea2123ad7d2ac913321b` 기준이다.

### 확인한 담당자 결정

- R-34는 [CBRD-27213의 담당자 댓글 4778284](https://jira.cubrid.org/browse/CBRD-27213?focusedCommentId=4778284&page=com.atlassian.jira.plugin.system.issuetabpanels:comment-tabpanel)의 2026-11-10 결정에 따라 해당 재설계로 넘긴다. 기존 tier-3 sync를 별도로 고치지 않고 재설계에서 legacy 구조와 함께 제거한다. 이 결정은 현재 구현의 제거 완료를 뜻하지 않는다.
- R-39는 기능 이름에 맞게 develop 병합 전에 변경하기로 했다. [CBRD-28023](https://jira.cubrid.org/browse/CBRD-28023)이 이 결정을 추적하는 기존 Open sub-task다. 정확한 새 문자열과 테스트 수정 범위는 해당 이슈의 ANALYSIS에서 정한다. 고정 head의 `file_type_to_string(FILE_OOS)`는 여전히 `OUT_OF_LINE_OVERFLOW_STORAGE`를 반환한다. 사용자 출력 문자열의 변경이므로 동작 보존 정리와 구분한다.

2026-11-03 NEEDS-DECISION 집계는 당시 기록으로 유지한다. 이번 확인은 위 두 결정에 한정하며, 다른 다섯 항목의 담당자 선택을 새로 확정하지 않는다.

### N-20261111-01의 정적 조건 확인과 남은 실행 검증

`attr_def_one`의 현재 거부 블록 진입점에서는 STORAGE mask bit와 `attr_storage != UNSET`가 동치라는 정적 확인을 마쳤다. grammar 의존 관계, 초기화와 쓰기 지점, 생성된 parser의 error-token shift 부재, 유한 상태 모델을 확인했다. 실제 SQL parser 실행 결과는 아니다.

교체 범위는 `csql_grammar.y:10187`의 기존 위치에 helper를 호출하는 것으로 제한한다. 거부 후에는 mask가 남고 storage만 UNSET이므로 두 조건은 더 이상 동치가 아니다. helper 호출을 옮기거나 `PARSER_SAVE_ERR_CONTEXT`, visibility·중복 진단 순서, 늦은 ALTER 검사를 바꾸지 않는다. 구현 시 SA·CS에서 정상 입력과 잘못된 입력의 오류 내용·위치·순서를 원본과 비교해야 한다. 후보는 계속 미구현이며 런타임 동치는 미확인이다.

### N-20261111-02의 반환값과 수명 경계

`get_int_column`은 result를 종료하지 않는다. 변경할 때 `fetch_single_int`는 cursor 위치 결정에 성공한 뒤 이 helper를 호출하고, helper가 반환한 다음 result를 한 번 종료하며 helper의 반환값을 돌려준다. 기존 SHOW 소비자는 같은 result에서 여러 열을 읽으므로 종료 책임을 공유 helper로 옮기지 않는다.

오류 처리 개선을 섞지 않는다. SQL 실행 실패의 원래 반환값, first-tuple 실패의 `ER_FAILED`, tuple-fetch 실패의 원래 반환값과 `DB_VALUE`를 clear하지 않는 기존 분기, `db_query_end` 반환값을 무시하는 순서를 보존한다. 지원 타입만 `out_val`에 쓰고, BIGINT의 기존 `int` cast도 유지한다. 범위 밖 BIGINT는 같은 compiler·platform의 원본과 변경 바이너리로 비교해야 한다. header 이동 뒤 전체 OOS SQL target의 빌드와 실제 SQL·오류 경로 비교는 미실행이며 구현 때 남은 검증이다.


## 2026-11-11 R-18 범위 구체화. 잠금 상태의 cache entry 제거

이 기록은 기존 R-18의 정적 재검토다. 신규 후보나 sub-task를 추가하지 않는다. head `50619ce53ef7b0e6bc8b468b2065ae7da4ef592f`, base `2dd94e32ab86a756b0f1ea2123ad7d2ac913321b`에서 entry 수를 줄이는 네 지점을 모두 확인했다. 두 hash에서 entry를 빼고 free-list에 반환하거나 해제한 뒤 개수를 줄이는 책임이 반복된다. 한쪽만 수정하면 hash와 entry 소유 상태의 일관성을 놓칠 수 있다는 유지보수상 위험을 줄이는 후보다.

| 지점 | 현재 순서와 범위 판단 |
| --- | --- |
| [VPID 삭제 443행](https://github.com/CUBRID/cubrid/blob/50619ce53ef7b0e6bc8b468b2065ae7da4ef592f/src/storage/oos_file.cpp#L443) | VFID hash 제거, VPID hash 제거, 기존 `oos_stats_entry_free`, entry 수 감소 순서다. |
| [검색 중 header 제외 616행](https://github.com/CUBRID/cubrid/blob/50619ce53ef7b0e6bc8b468b2065ae7da4ef592f/src/storage/oos_file.cpp#L616), [공간 부족 제외 628행](https://github.com/CUBRID/cubrid/blob/50619ce53ef7b0e6bc8b468b2065ae7da4ef592f/src/storage/oos_file.cpp#L628) | 같은 네 동작을 같은 순서로 반복한다. header 제외의 `continue`와 공간 부족의 `notfound_cnt++`는 호출자에 남긴다. |
| [파일 전체 삭제 470행](https://github.com/CUBRID/cubrid/blob/50619ce53ef7b0e6bc8b468b2065ae7da4ef592f/src/storage/oos_file.cpp#L470) | VPID hash를 먼저 지운다. 순서를 보존하기 위해 이번 helper 대상에서 제외한다. 순서 선택 인자는 추가하지 않는다. |

작은 인터페이스 후보는 `static void oos_stats_remove_entry_locked (THREAD_ENTRY *thread_p, OOS_STATS_ENTRY *ent)`다. 기존 mutex를 보유하고 두 hash에 등록된 non-null entry만 받으며, 위의 VFID 우선 세 지점만 대체한다. identifier 비교는 값 기준이므로 entry의 VFID와 VPID를 key로 쓸 수 있다. 기존 free callback의 반환값을 무시하는 동작과 free-list 용량 정책을 유지하고, callback 뒤에는 entry를 읽지 않는다. 이 인터페이스는 ANALYSIS 후보이며 구현 확정이나 동작 보존 검증 완료를 뜻하지 않는다.

[삽입 실패 정리 410행](https://github.com/CUBRID/cubrid/blob/50619ce53ef7b0e6bc8b468b2065ae7da4ef592f/src/storage/oos_file.cpp#L410)은 두 hash 등록과 entry 수 증가가 끝나기 전이므로 대상에서 제외한다. finalization과 array hint 제거도 제외한다. count 감소를 기존 `oos_stats_entry_free` 안으로 옮기지 않는다.

mutex 획득·해제와 page fix·unfix, 후보 순서, 오류 반환은 기존 위치에 둔다. 특히 VPID 삭제의 recovery growth-gate 재무장은 cache miss 검사보다 먼저 실행되므로 helper 밖에 그대로 둔다. reclaim-state 삭제와 header hint 정리도 각 호출자에 남긴다. pending postpone 변경과는 이 경계를 기준으로 다시 비교한다. CBRD-27213의 미래 재설계가 이 helper를 남길지는 미정이지만, 현재 세 지점의 좁은 정리를 검토하는 데 재설계 완료를 일괄 선행조건으로 두지는 않는다. 실제 작업 순서는 대상 revision과 재설계 진행 상황을 보고 정한다.

구현 후에는 SERVER와 SA를 빌드하고 기존 `OosBestspaceTest`의 `BestspaceStaleCacheEviction`, `BestspaceHeaderPageNeverReturned`, `BestspaceMultipleFilesIsolation`, `BestspaceCacheCleanedOnFileRemove` 등을 실행한다. free-list 재사용과 용량 경계, 공간 부족 검색 budget, cache hit와 miss의 recovery 재무장, reclaim 이후 재사용도 원본과 비교한다. 기존 테스트가 각 분기에 실제 도달하는지는 별도로 확인한다. 이번에는 소스와 테스트를 읽었으며 빌드·런타임 검증은 수행하지 않았다.


## 2026-11-11 후속 확인. R-19 테스트 bridge 선언의 작은 공통 범위

R-19의 전체 이동을 #8128·#8299 병합 뒤로 미룬 과거 기록은 보존한다. 같은 고정 head에서 확인한 아래 두 선언은 기존 private 테스트 header를 재사용하는 별도 범위로 검토할 수 있다. 신규 후보나 구현 완료로 세지 않는다.

- `int bridge_oos_get_max_chunk_size_within_page ();`는 실제 호출이 있는 테스트 파일 14개에 반복된다. SA 8개와 SERVER 6개이며, 모두 기존 fixture header를 통해 `test_oos_utils.hpp`를 이미 포함한다.
- `OOS_HDR_STATS *bridge_oos_get_header_stats_ptr (THREAD_ENTRY *thread_p, PAGE_PTR page_header);`는 `test_oos_bestspace.cpp:47`과 `test_oos_growth_sweep.cpp:46`에 반복되고 두 파일 모두 호출한다. 두 선언은 [oos_file.cpp 3891행 이후 정의](https://github.com/CUBRID/cubrid/blob/50619ce53ef7b0e6bc8b468b2065ae7da4ef592f/src/storage/oos_file.cpp#L3891)와 일치한다.

가장 작은 후보는 [test_oos_utils.hpp](https://github.com/CUBRID/cubrid/blob/50619ce53ef7b0e6bc8b468b2065ae7da4ef592f/unit_tests/oos/test_oos_utils.hpp#L19)에 두 선언을 전역 C++ scope로 두고 호출부의 복사본을 지우는 것이다. 이 header는 필요한 기존 타입 header를 포함한다. `namespace test_oos_utils` 안으로 옮기거나 `extern "C"`, default argument, wrapper를 추가하지 않는다. `CUBRID_UNIT_TEST_ENABLED` 경계와 SA·SERVER 가시성을 유지한다. 이 범위는 호출자 사이의 선언 차이를 막는다. 정의 파일이 이 테스트 header를 포함하지 않으므로 선언과 정의의 불일치까지 컴파일로 검출한다는 주장은 하지 않는다.

작은 전용 bridge header는 SQL 테스트까지 공유하는 debug counter 선언과 page RAII 반환형을 함께 옮길 때 별도로 비교할 수 있다. 위 두 선언만 옮기기 위해 새 header나 엔진의 테스트 utility 의존을 추가하지 않는다. CS 전용 log-applier bridge, heap·locator bridge, 새 이름의 seam, CMake target·등록·fixture 변경은 이번 범위에서 제외한다.

#8128 head `e3589ae42d42b04eb020e1ae43e165b01d31b12a`, #8299 head `cd24a212aa81e2a11d72d1ac57bb10113727a4d8`의 관련 header·정의와 테스트 diff도 별도로 확인했다. 두 PR은 조회 당시 Open이며, 선택한 두 signature의 변경은 확인되지 않았다. #8128은 같은 max-chunk 선언과 호출을 새 테스트에도 추가하므로, 그 테스트가 들어오면 함께 옮길 복사본으로 대조한다. 전체 PR 종료를 일괄 선행조건으로 삼는 대신 실제 구현 revision의 해당 선언·include 변경을 다시 대조한다. 향후 충돌이 없다는 보장은 아니다.

정적 확인만 수행했다. 구현 시 OOS 단위 테스트를 켠 구성에서 영향받는 SA·SERVER target 14개를 빌드·링크하고, 기존 등록 테스트와 fixture를 그대로 실행해야 한다. 비테스트 엔진 빌드에 새 symbol 의존이 생기지 않는지도 확인한다. 이번 조사에서는 빌드·링크·런타임 검증을 수행하지 않았다.


## R-25 scope clarification, 2026-11-11

기존 R-25의 구현 범위를 좁히는 정적 조사다. 새 후보나 sub-task를 추가하지 않는다. 기준은 PR #7990 head `50619ce53ef7b0e6bc8b468b2065ae7da4ef592f`, base `2dd94e32ab86a756b0f1ea2123ad7d2ac913321b`다. 구현과 실행 검증은 하지 않았다.

24바이트 stub의 필드 순서와 offset 지식이 반복된다. [직렬화 writer](https://github.com/CUBRID/cubrid/blob/50619ce53ef7b0e6bc8b468b2065ae7da4ef592f/src/storage/heap_file.c#L14594)와 [pending 확정 writer](https://github.com/CUBRID/cubrid/blob/50619ce53ef7b0e6bc8b468b2065ae7da4ef592f/src/storage/heap_oos.cpp#L250)는 OID, 길이, packed stamp를 쓴다. [디스크 전용 parser](https://github.com/CUBRID/cubrid/blob/50619ce53ef7b0e6bc8b468b2065ae7da4ef592f/src/storage/heap_oos.cpp#L665)와 [pending-aware decoder](https://github.com/CUBRID/cubrid/blob/50619ce53ef7b0e6bc8b468b2065ae7da4ef592f/src/storage/heap_oos_value_ref.cpp#L58)도 같은 위치를 해석한다. 필드 배치가 바뀔 때 한쪽만 고칠 위험을 줄이는 것이 공통화의 목적이다.

후보 방안은 필드 배치만 공유하는 작은 읽기·쓰기 연산이다. 기존 `OR_OOS_INLINE_SIZE`, `oos_pack_identity_stamp`와 `oos_unpack_identity_stamp`를 재사용하고, [VOT 필드 경계 검사](https://github.com/CUBRID/cubrid/blob/50619ce53ef7b0e6bc8b468b2065ae7da4ef592f/src/storage/heap_file.c#L11495)는 기존 `heap_recdes_get_oos_inline_stub`에 둔다. 최종 위치와 인터페이스는 ANALYSIS에서 정한다. 다음 계약을 합치거나 바꾸지 않는다.

- 디스크 parser는 NULL OID와 잘못된 길이를 거부한다. pending decoder는 NULL OID일 때 마지막 8바이트를 owner index로 해석한다. `heap_pending_record::resolve`의 준비 상태, allocation 소유, index와 길이 검사를 유지한다. pending bytes를 디스크 참조로 취급하지 않는다.
- [복제 fixup](https://github.com/CUBRID/cubrid/blob/50619ce53ef7b0e6bc8b468b2065ae7da4ef592f/src/transaction/locator_sr.c#L15294)은 replica-local OID와 stamp만 교체하고 가운데 길이 8바이트는 그대로 둔다. 공통 writer를 쓰기 위해 길이를 다시 쓰는 변경은 이 범위에서 제외한다.
- 직렬화 writer는 실제 `*ptr_varvals` 위치의 용량 검사, `S_DOESNT_FIT`, cursor 갱신과 상위 grow-and-retry를 유지한다. decoder별 출력 초기화와 실패 전에 이미 대입된 출력값, 오류 코드와 설정 순서, pending batch 성공 뒤의 확정·수명도 유지한다. 공통 연산은 validation, 오류 설정, 메모리 할당이나 storage 접근을 맡지 않는다.

[현재 #8299](https://github.com/CUBRID/cubrid/pull/8299) head `cd24a212aa81e2a11d72d1ac57bb10113727a4d8`는 주변 planner, nullable plan과 VOT decoder를 바꾼다. 해당 revision에서도 위 writer와 parser의 공통화 대상은 남는다. 기존 DEFERRED 이력은 유지하며, 실제 통합 revision에서 경계와 호출 순서를 다시 확인한다. #8434 head `94ed2ea463f17694db33a283b56fdeb42856e835`의 회수 정책 변경은 이 codec 정리에 포함하지 않는다.

구현 시 확인할 항목은 24바이트 디스크 bytes 동일성, 기존 짧거나 잘린 VOT 필드 거부, NULL OID와 pending owner 거부의 오류·출력 보존, 실제 cursor 용량 부족의 grow-and-retry, 복제 fixup의 길이 보존이다. SA·SERVER 관련 기존 테스트와 빌드도 실행해야 한다. 이번 조사에서는 모두 미실행이며, malformed-image 결함 수정이나 accepted OOS 요구사항 구현으로 완료 처리하지 않는다.


## R-27 planner 경계 재확인 (2026-11-11 정적 조사)

기존 R-27의 선택지를 좁힌다. 신규 TODO나 구현 완료로 세지 않는다. [PR7990](https://github.com/CUBRID/cubrid/pull/7990) head `50619ce53ef7b0e6bc8b468b2065ae7da4ef592f`, base `2dd94e32ab86a756b0f1ea2123ad7d2ac913321b`에서 `heap_attrinfo_determine_disk_layout`의 직접 production 호출은 `heap_attrinfo_transform_to_disk_internal` 한 곳이다 (`heap_file.c:13743`, `:14840`). INSERT·UPDATE와 pending 준비는 그 경로를 공유한다. 별도 planner 모듈이나 결과 복사를 추가하는 이점은 아직 입증되지 않았다.

현재 [#8299](https://github.com/CUBRID/cubrid/pull/8299) head `cd24a212aa81e2a11d72d1ac57bb10113727a4d8`는 크기 계산과 강제 선택을 합치고, 8개 이하 크기 배열은 stack을 쓰며, 첫 선택 때만 plan을 할당한다. planner의 `std::bad_alloc`을 기존 C 오류로 바꾸는 경계도 추가한다. 이 revision의 target은 `heap_oos_inline_target_size()`이고 gate와 stop이 같은 값을 쓴다. fixed head의 `DB_PAGESIZE / 4`를 바꾸는 DF-02는 별도 동작 변경이다. 두 revision의 할당 실패 동작까지 같다고 판정하지 않는다. DEFERRED 이력은 유지하고 실제 통합 revision에서 다시 대조한다.

추출한다면 이미 있는 `heap_oos_demote_candidate`와 comparator를 재사용하고, 측정된 크기·기존 선택 상태·target을 받는 작은 선택 연산으로 한정하는 안을 검토한다. 전체 descriptor 배열과 결과 복사, production 호출이 하나뿐인 전달 helper는 이점이 없으면 추가하지 않는다. `heap_oos_column_plan`의 OID·stamp·pending index는 뒤의 직렬화 상태이므로 선택 연산에 복제하지 않는다.

보존할 계약은 FORCE_OUTLINE 선행 선택, 24B 초과 조건, ordinary 우선·크기 내림차순·동률 attribute index 내림차순, loop 전 header 추정값과 loop 뒤 한 번의 재계산, MVCC 여유분, 선택 flag와 `has_oos`, offset 폭, 실제 revision의 할당·오류 순서다. header를 매 선택마다 다시 계산하면 VOT 폭 경계에서 선택 결과가 달라질 수 있다. 수용된 FORCE_INLINE·bigone 정책의 적합성 변경과 OOS 저장·WAL·latch 동작은 이 정리에 섞지 않는다.

실행 검증은 하지 않았다. 향후 구현에서는 gate 미진입, 강제·NULL·24B 경계, 우선순위·동률, 후보 소진, MVCC·VOT 폭 전환에서 선택 index와 최종 크기·offset·flag를 비교한다. 할당 실패 시점과 오류, 일반 행의 지연 할당 경로, SA·SERVER 통합도 별도로 확인해야 한다. 순수 연산 경계가 복사 없이 유용한지 확인되기 전에는 현재 함수에 두는 안을 유지한다.

## R-33 복제 큐와 억제 상태의 소유권 재확인

2026-11-11에 같은 fixed head `50619ce53ef7b0e6bc8b468b2065ae7da4ef592f`와 base `2dd94e32ab86a756b0f1ea2123ad7d2ac913321b`를 정적으로 추적했다. 새 후보는 추가하지 않는다. R-33은 미구현이며 실행 동등성도 미검증이다.

`LOG_LSA_QUEUE`는 이미 vector와 소비 위치 `m_head`를 가진 FIFO 타입이다(`src/transaction/log_lsa.hpp:127`). `LOG_TDES`의 큐와 thread의 OOS 참조 vector는 수명이 다르다. FK 갱신 재귀는 두 컨테이너 전체를 swap해 부모를 보관하고, 성공·오류 분기 전에 복원한다(`locator_sr.c:9653`). 큐 내용만 복사하거나 복제 상태 전체를 한 타입으로 묶으면 소비 위치와 이 소유권 경계가 흐려질 수 있다. 일반 `suppress_replication`은 복제 로그 기록을 막고 OOS 큐 소비 전에 반환한다(`replication.c:313`). OOS 전용 flag는 `RVOOS_INSERT`의 자동 enqueue만 막으므로 둘을 합치지 않는다.

파일 생성은 flag가 false였을 때만 true로 바꾸고 복원하지만(`oos_file.cpp:1193`), 다중 chunk 삽입은 추적 중 true로 설정한 뒤 종료 때 false로 만든다(`:2358`). 조사한 운영 경로는 파일 조회·생성을 삽입 전에 끝내고 batch의 다중 chunk 호출도 순차 실행한다. FK 재귀가 chunk loop 안에서 발생한다는 근거도 찾지 못했다. 이미 true인 상태로 진입하는 경로는 입증하지 못했으며, 할당·회수 하위 경로의 간접 재진입까지 배제한 것은 아니다. 이전 값을 복원하는 guard는 그 상태에서 결과를 바꾸므로, 단순 추출과 구분해 도달성과 의도된 동작부터 확인한다. R-48의 기존 guard 후보도 중복 추가하지 않는다.

추적 중인 다중 chunk 삽입은 dummy 로그 뒤 tail부터 chunk를 쓰고, 완료 때 dummy LSA와 tail LSA를 그 순서로 큐에 넣는다. null 참조 marker 뒤 실제 head 참조가 오며 복제 emitter는 이 순서를 소비한다. 중간 오류의 publication 상태 정리와 이미 쓴 chunk의 transaction undo는 서로 다른 책임이다. 자동 enqueue 두 곳, 논리 publication 시작, 오류 정리, descriptor 초기화, FK swap의 경계를 유지한다. savepoint별 큐 snapshot이 없다는 정적 관찰만으로 rollback 결함을 단정하지 않는다.

[#8330](https://github.com/CUBRID/cubrid/pull/8330)의 merge `902fe1452360dcdd4c6e08812dbe0ae7d52ae9c7`는 fixed head의 ancestor다. #8299의 현재 head `cd24a212aa81e2a11d72d1ac57bb10113727a4d8`에서도 관련 queue·flag 지점은 유지된다. [#8434](https://github.com/CUBRID/cubrid/pull/8434)의 현재 head `94ed2ea463f17694db33a283b56fdeb42856e835`는 append·recovery 경로를 바꾸므로 실제 통합 revision에서 다시 확인한다. 단일·다중 chunk, batch, 일반 억제·no-logging, FK 중첩 실패, allocation 실패, sysop·transaction·savepoint rollback, 재시작 복구와 HA 검증은 실행하지 않았다.

