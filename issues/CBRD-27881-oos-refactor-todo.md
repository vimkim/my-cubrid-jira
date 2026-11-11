# [OOS] OOS 리팩토링 후보를 검토하고 작은 sub-task로 선정한다

**한 줄 요약**: 후보의 상세 근거는 문서에서 확인하고, 이 이슈에서 우선 검토와 sub-task 진행을 추적한다.

## Issue Triage

**이슈 수행 목적**: OOS 유지보수자가 동작을 보존하는 정리 후보를 골라 작은 PR로 처리한다.

**이슈 수행 이유**: PR #7990 조사와 후속 확인에서 모은 70개 후보 기록에 대해 변경 범위, 선행조건과 검증 부담을 함께 판단해야 한다.

**영향**: OOS 개발자와 리뷰어가 후보의 근거와 기존 결정을 찾아보고, 같은 코드를 고치는 작업의 순서를 정할 수 있다.

**이슈 수행 방안**: 아래 인덱스에서 후보를 고르고 상세 문서의 조건을 확인한다. sub-task와 PR의 선정·병합 순서는 OOS 유지보수자가 정한다.

## Candidate index

[전체 후보 70개와 상세 내용](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27881/refactoring-candidates.md)에서 기존 R 항목 68개와 신규 N 항목 2개를 찾는다. 보류·기각 기록도 포함한다. 후보 제목은 `[YYYY-MM-DD] ID 변경 내용` 형식이며 날짜는 확인 가능한 최초 기록일이다.

| 검토 순서 | 후보 | 검토할 범위 |
| --- | --- | --- |
| 먼저 검토 | [R-16](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27881/refactoring-candidates.md#r-16) | 테스트의 page free-space 조회 helper 다섯 복사본을 공유한다. |
| 먼저 검토 | [N-20261111-02](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27881/refactoring-candidates.md#n-20261111-02) | SQL 테스트 정수 변환을 기존 helper 하나로 모은다. |
| 이어서 검토 | [R-19](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27881/refactoring-candidates.md#r-19) | 테스트 bridge 선언을 기존 공용 header에 모은다. |
| 이어서 검토 | [R-30](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27881/refactoring-candidates.md#r-30) | SQL 테스트 등록과 공통 속성에 명시적인 공통 목록을 쓴다. |
| 조건 확인 후 | [N-20261111-01](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27881/refactoring-candidates.md#n-20261111-01) | 현재 위치에서 parser의 STORAGE namespace 거부 helper를 재사용한다. |
| 조건 확인 후 | [R-18](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27881/refactoring-candidates.md#r-18) | VFID hash를 먼저 지우는 locked-entry 제거 세 곳만 공유한다. |

후보별 구현과 동작 비교는 각 상세 절의 조건에 따라 검증한다. 위 순서는 유지보수 이득과 변경 범위에 관한 조사 제안이다.

## Existing sub-tasks

2026-11-11 확인 기준이다. PR과 JIRA 상태는 아래 연결에서 확인한다.

| Sub-task | PR | 내용 | 확인한 상태 |
| --- | --- | --- | --- |
| [CBRD-27882](https://jira.cubrid.org/browse/CBRD-27882) | [#8367](https://github.com/CUBRID/cubrid/pull/8367) | 사용하지 않는 매크로·bridge·상수 인자 제거 | PR 병합, Resolved |
| [CBRD-27883](https://jira.cubrid.org/browse/CBRD-27883) | [#8368](https://github.com/CUBRID/cubrid/pull/8368) | 단위 테스트 helper 공유와 사용하지 않는 SQL helper 제거 | PR 병합, Resolved |
| [CBRD-27884](https://jira.cubrid.org/browse/CBRD-27884) | [#8369](https://github.com/CUBRID/cubrid/pull/8369) | heap 속성 writer의 LOB 복사 코드 공유 | draft PR 열림, Confirmed |
| [CBRD-27885](https://jira.cubrid.org/browse/CBRD-27885) | [#8370](https://github.com/CUBRID/cubrid/pull/8370) | 로그 없이 header 페이지를 dirty로 표시하는 코드 공유 | PR 병합, Resolved |
| [CBRD-27886](https://jira.cubrid.org/browse/CBRD-27886) | [#8371](https://github.com/CUBRID/cubrid/pull/8371) | heap 삭제 경로의 OOS 파일 정리 공유 | PR 병합, Resolved |
| [CBRD-27887](https://jira.cubrid.org/browse/CBRD-27887) | [#8372](https://github.com/CUBRID/cubrid/pull/8372) | ALTER 속성 플래그 판정 공유 | PR 병합, Resolved |
| [CBRD-27888](https://jira.cubrid.org/browse/CBRD-27888) | [#8373](https://github.com/CUBRID/cubrid/pull/8373) | OOS 주석 정정 | PR 병합, Resolved |

## Decisions and evidence

- [후보별 현재 판단과 선행조건](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27881/refactoring-candidates.md)은 같은 ID의 상세 절에서 갱신한다.
- [2026-11-11 조사와 결정 기록](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27881/survey-2026-11-11.md)은 이 이슈의 이전 상세 본문, DF-03의 commit 후 postpone 결정과 후속 범위 확인을 보존한다.
- [기존 조사 보고서와 결함 후보](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27881/CBRD-27881-oos-refactoring-candidates_dcbf09e_claude.md#defect-candidates)에서 DF 항목의 근거와 당시 검증 한계를 확인한다.
- [문서 목록](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27881/README.md)에서 담당자 결정과 기존 PR별 검증 자료를 찾는다.

## Completion

기존 sub-task PR 7개의 병합 또는 종료 결과와 필요한 유지보수자 결정을 기록한다. 보류한 후보는 선행 작업이 반영된 revision에서 재검토하고, 선택한 후속 작업을 sub-task로 연결한다.
