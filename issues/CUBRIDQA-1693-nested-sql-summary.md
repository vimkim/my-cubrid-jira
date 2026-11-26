# [CTP] 중첩 SQL 범주의 결과 집계 누락

**한 줄 요약**: 직접 case 가 있는 범주 아래의 하위 범주 case 를 CTP 가 SQL 요약과 JUnit XML 에서 빠뜨린다. 그래서 gha-ci `test_sql` 에서 같은 실행의 JUnit 수가 `summary_info` 보다 적은 무결성 오류가 매번 생긴다. 이 결함을 고쳐 실행한 모든 case 가 보고서에 한 번씩 남게 한다.

## Issue Triage

**이슈 수행 목적**: CTP SQL·medium 실행에서 실행한 모든 case 가 요약 수(`summary_info`)와 JUnit XML 에 정확히 한 번씩 기록되게 한다. 그러면 두 결과를 맞춰 보는 검증과 통계 집계가 같은 수를 얻는다.

**이슈 수행 이유**: 범주(디렉토리)에 직접 case 와 하위 범주가 함께 있으면 하위 범주의 case 가 요약 수와 JUnit 에서 빠진다. 지금 `develop` testcase 에는 이런 case 가 19개 있고, 2026-11-25 CI 에서 shard 01 의 JUnit 이 `summary_info` 보다 19개 적었다(3,538 대 3,557).

**영향**: JUnit 수가 `summary_info` 보다 적은 것은 무결성 오류다. 두 결과를 맞춰 보는 검증 도구(예: `cubrid-ci`)나 다른 통계 집계에서 무결성 오류로 보고될 수 있다. 빠진 case 가 실패해도 JUnit 에는 `<failure>` 가 남지 않으므로, JUnit 만 읽는 실패 목록과 결과 화면은 그 실패를 놓친다. `_05_bug_fix/` 아래에 `cbrd-*` TC 가 더해질 때마다 빠지는 case 도 는다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다. 후보 수정은 [CUBRID/cubrid-testtools#793](https://github.com/CUBRID/cubrid-testtools/pull/793) 이다.

---

## AI-Generated Context

## Description

CTP 는 testcase 디렉토리를 범주 트리로 만들고, 범주마다 요약(`Summary`)을 계산한 뒤 `summary_info` 와 JUnit XML 을 쓴다. 범주가 직접 case 를 가지면 CTP 는 그 범주를 말단으로 보고 하위 범주를 돌지 않는다. `summary_info` 파일은 원래 범주 map 을 따라 쓰므로 하위 case 의 판정 행이 남지만, 합계와 JUnit 은 연결된 요약 트리를 따라가므로 하위 case 가 빠진다. 두 출력의 수가 달라지는 이유다.

이 Sub-task 는 [CUBRIDQA-1501](https://jira.cubrid.org/browse/CUBRIDQA-1501) 의 gha-ci 결과 보고 중 SQL 요약·JUnit 의 누락만 다룬다. JUnit 형식 자체는 [CUBRIDQA-1712](https://jira.cubrid.org/browse/CUBRIDQA-1712) 가 정했다.

### 영향 범위

`develop` testcase(2026-11-26, `ddd400460`)에서 `sql/_05_plcsql/_01_testspec/_05_bug_fix/cases/` 에 직접 case 42개가 있고, 그 아래 `cbrd-*/cases/` 디렉토리 7개에 case 19개가 있다. 이 19개가 빠진다.

| 하위 디렉토리 | case 수 |
| --- | ---: |
| `cbrd-27500` | 1 |
| `cbrd-27556` | 5 |
| `cbrd-27584` | 2 |
| `cbrd-27633` | 6 |
| `cbrd-27634` | 2 |
| `cbrd-27742` | 2 |
| `cbrd-27927` | 1 |

SQL 과 medium 이 같은 생성기를 쓴다. medium 에 같은 배치가 있는지는 확인하지 않았다.

### 경위

| 날짜 | 일 |
| --- | --- |
| 2026-10-30 | [cubrid#8128](https://github.com/CUBRID/cubrid/pull/8128) · [cubrid#8347](https://github.com/CUBRID/cubrid/pull/8347) 의 CI([run 40837919358](https://github.com/CUBRID/cubrid/actions/runs/40837919358), [run 41048233875](https://github.com/CUBRID/cubrid/actions/runs/41048233875))에서 SQL shard 01 이 `summary_info` 3,533 · JUnit 3,531 이었다. 빠진 2개는 `cbrd-27556/cases/` 에 있었다. 실행 당시 CTP(`1c6b224`)로 같은 누락을 재현하고 PR #793 을 draft 로 열었다. |
| 2026-11-05 · 11-06 | [cubrid-testtools#798](https://github.com/CUBRID/cubrid-testtools/pull/798) · [#797](https://github.com/CUBRID/cubrid-testtools/pull/797) 이 JUnit writer 를 `common` 으로 옮겼다. 이 결함이 든 `JunitXmlWriter.walk()` 의 분기는 그대로 남았다. |
| 2026-11-25 | cubrid#8128 의 [run 45578200568](https://github.com/CUBRID/cubrid/actions/runs/45578200568) 에서 shard 01 의 JUnit 이 19개를 빠뜨렸다(`summary_info` 3,557 · JUnit 3,538). |
| 2026-11-26 | PR #793 을 현재 `develop`(`3c2e991`) 위로 rebase 했다(head `cdb0995`). 충돌은 없었다. #798 에 맞춰 회귀 시험만 고쳤다. 이 이슈를 CUBRIDQA-1501 의 Sub-task 로 옮겼다. |

### 후보 수정과 확인한 근거

PR #793 의 운영 코드 변경은 두 파일이다.

- `JunitXmlWriter.walk()`: 범주의 직접 case 를 쓴 뒤 하위 범주도 돈다.
- `TestUtil.makeSummary()`: 범주 트리를 한 번 돌며 수 · 시간 · 하위 링크를 새로 계산한다. 디렉토리가 직접 가진 case 목록과 그룹 합계를 따로 둔다. 경로의 연속 `/` 를 하나로 본다.

결과 디렉토리, `summary_info` 위치, SQL · medium 의 직렬화 계층은 바뀌지 않는다. `head cdb0995` 에서 Java 8 로 확인한 결과는 다음과 같다.

| 검사 | 결과 |
| --- | --- |
| `./tests/sql-summary/run.sh` (DB 없이 실제 CTP 클래스로 요약 · `summary_info` · JUnit 비교) | 통과 |
| 같은 시험을 `develop` 의 `walk()` 로 실행 (음성 대조) | 실패: 섞인 트리에서 JUnit case 5개 기대 · 3개 실제, `<failure>` 1개 기대 · 0개 실제 |
| `ant -f CTP/build.xml` 전체 빌드와 새 `cubridqa-cqt.jar` 로 같은 시험 | 빌드 성공, 시험 통과 |
| rebase 전(`4f720bd`) 보관된 실제 3,533개 경로 · 판정 · 시간으로 보고서 재생 | 요약 · JUnit · 판정 행 모두 3,533개 |

마지막 재생은 SQL 을 다시 실행한 결과가 아니다. 실제 CI 결과로는 아직 확인하지 않았다.

### 완료 조건

- PR #793 또는 ANALYSIS 에서 정한 수정이 `develop` 에 들어가고, 배포 커밋이 runtime jar 를 다시 만든다.
- 그 뒤 gha-ci `test_sql` 에서 각 shard 의 JUnit case 수가 `summary_info` 총수와 같다. 지금 기준으로 shard 01 은 3,557개다.
- 결과 파일을 고치거나 검증 쪽 검사를 완화해 맞추지 않는다.
