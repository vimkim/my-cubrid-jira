# [CTP] SQL 결과 요약 회귀 시험을 PR CI 에서 실행

**한 줄 요약**: [CUBRIDQA-1693](https://jira.cubrid.org/browse/CUBRIDQA-1693) 의 PR [#793](https://github.com/CUBRID/cubrid-testtools/pull/793) 이 더한 SQL 결과 요약 회귀 시험을 아무 CI 도 실행하지 않아서, [#798](https://github.com/CUBRID/cubrid-testtools/pull/798) 이 이 시험의 컴파일을 깨뜨린 것을 아무도 몰랐다. 이 시험을 cubrid-testtools 의 PR CI 에서 실행하여 같은 회귀를 PR 단계에서 잡는다.

## Issue Triage

**이슈 수행 목적**: cubrid-testtools 에 PR 을 올리면 SQL 결과 요약 회귀 시험(`tests/sql-summary/run.sh`)이 자동으로 실행되고, 시험이 실패하면 PR 의 check 가 실패한다.

**이슈 수행 이유**: PR #793 은 SQL · medium 결과 요약의 수, `summary_info`, JUnit XML 을 검사하는 오프라인 회귀 시험을 더한다. 그러나 cubrid-testtools 의 PR CI 는 코드 스타일 검사(`code-style`)만 실행한다. #793 이 열려 있는 동안 #798 이 JUnit writer 를 `common` 으로 옮겼고, 이 시험은 컴파일되지 않게 되었다. JUnit 파일 이름과 skipped case 처리도 바뀌어 기대값이 맞지 않았다. 이 일은 #793 을 `develop` 위로 rebase 할 때에야 드러났다.

**영향**: CTP 의 결과 요약과 JUnit 출력은 gha-ci 의 결과 보고와 무결성 검사가 쓰는 입력이다. 이 코드를 고치는 PR 이 회귀 시험을 깨뜨리거나 집계를 틀리게 해도 리뷰어는 알 수 없고, 결함은 다음 gha-ci 실행의 결과 수 불일치로 늦게 드러난다. 시험이 깨진 채로 남으면 회귀 시험을 더한 의미도 사라진다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다. 후보 구현은 기존 `github-checks` workflow 에 Java 8 로 이 시험을 실행하는 job 을 더하는 것이다.

---

## AI-Generated Context

## Description

`tests/sql-summary/run.sh` 는 CTP SQL 소스 일부와 `SqlSummaryTest.java` 를 컴파일한 뒤, 임시 디렉토리에 가짜 SQL · medium 시나리오를 만들어 결과 요약 수, `summary_info`, JUnit XML 을 검사한다. 데이터베이스나 CUBRID 설치가 필요 없고, Java 8 JDK 와 저장소의 `CTP/*/lib` jar 만 쓴다. 로컬 실행은 약 11초 걸렸다.

cubrid-testtools 의 유일한 PR workflow 는 `.github/workflows/check.yml`(`github-checks`)이고, 그 안의 job 은 `code-style` 하나다. 이 job 은 바뀐 파일의 들여쓰기 · 형식만 검사하고 Java 코드를 컴파일하거나 시험을 실행하지 않는다.

이 Sub-task 는 [CUBRIDQA-1501](https://jira.cubrid.org/browse/CUBRIDQA-1501) 의 gha-ci 결과 보고 작업 중, CTP 결과 요약 회귀 시험을 PR CI 에 연결하는 일만 다룬다. 시험 자체와 요약 누락 수정은 CUBRIDQA-1693 이 다룬다.

### 경위

| 날짜 | 일 |
| --- | --- |
| 2026-10-30 | PR #793 이 요약 누락 수정과 회귀 시험 `tests/sql-summary/` 를 draft 로 더했다. |
| 2026-11-05 | #798 이 JUnit writer 를 `common` 으로 옮겨 merge 되었다. 이 PR 의 CI(`code-style`)는 #793 의 시험을 실행하지 않았다. |
| 2026-11-26 | #793 을 `develop` 위로 rebase 하면서 시험이 컴파일되지 않는 것을 발견하고, 새 JUnit writer 의 `write()` 인자, 파일 이름, skipped 처리에 맞춰 시험을 고쳤다(head `cdb0995`). |

### 확인한 근거

#793 head `cdb0995` 에서 Java 8 로 `bash tests/sql-summary/run.sh` 를 실행했다.

| 검사 | 결과 |
| --- | --- |
| 수정하지 않은 소스 | 통과(`All SQL summary checks passed`, 종료 코드 0) |
| `JunitXmlWriter.write()` 에 인자를 더해 #798 과 같은 API 변경을 흉내 냄 | `javac` 컴파일 오류, 종료 코드 1 |
| `Summary.getTotalCount()` 가 1 을 더 돌려주게 바꿈 | 요약 수 검사 17개 실패, 종료 코드 1 |

시스템 기본 JDK 가 17 이상이면 xstream 의 module 접근 제한 때문에 시험이 실패할 수 있다. CI 에서는 Java 8 을 쓴다.

## Acceptance Criteria

- `develop` 과 `feature/**` 대상 PR 에서 `tests/sql-summary/run.sh` 를 Java 8 로 실행하는 check 가 돈다.
- 시험이 통과하면 check 가 성공하고, 컴파일 오류나 검사 실패가 있으면 check 가 실패한다.
- 기존 `code-style` 검사의 동작은 바뀌지 않는다.

### ANALYSIS 확인 사항

- CI job 은 #793 이 더한 시험 파일에 의존한다. #793 보다 먼저 merge 하면 다른 PR 의 check 가 시험 파일이 없어 실패하므로, merge 순서를 정해야 한다.
