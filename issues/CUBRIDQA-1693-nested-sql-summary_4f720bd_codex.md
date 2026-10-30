# CTP 중첩 범주의 SQL 결과 집계 누락

[PR 8347](https://github.com/CUBRID/cubrid/pull/8347)의 CI를 확인하던 작성자와 QA 담당자가 SQL 결과의 집계 불일치를 이해하고 결과 생성기 수정을 검토하도록 기록한다. 분석일은 2026-10-30, Asia/Seoul이다.

## Issue Triage

**이슈 수행 목적**: 직접 케이스와 하위 범주가 함께 있는 CTP 테스트에서 실행한 모든 케이스를 요약과 JUnit에 정확히 한 번씩 기록한다.

**이슈 수행 이유**: 실제 SQL shard의 성공 판정 3,533개 중 두 개가 총계와 JUnit에서 누락됐고, 실행 당시 CTP 바이너리로 같은 누락을 재현했다.

**영향**: 개발자와 QA 담당자가 실제 수행 목록과 보고서를 일치시킬 수 없다. PR 8347에서는 무결성 검증이 중단돼 정확한 CI 비교와 실패 분석을 이어가지 못했다. SQL·medium이 공유하는 생성기이며 다른 실행의 발생 빈도는 확인하지 않았다.

**이슈 수행 방안**: TBD - 회사 ANALYSIS에서 구현과 적용 범위를 결정한다. 로컬 후보 수정과 검증 결과를 아래에 보존한다.

---

## AI-Generated Context

> 아래는 직접 확인한 소스와 실행 근거이다. 회사 runtime 반영과 실제 SQL 재실행은 수행하지 않았다.

## Description

CTP의 범주 트리 처리에서 누락을 확인했다. 직접 SQL 케이스가 있는 범주를 말단으로 간주해 그 아래 범주를 집계와 JUnit에서 누락한다. 정확한 CI용 CTP 바이너리로 이 동작을 재현했고 결과 생성기 소스를 수정했다. 수집기의 무결성 검사는 유지한다. **아래 검증은 결과 생성의 오프라인 재생이며 기존 CI 자료는 여전히 불일치 상태이다.**

### 왜 문제인가

개발자는 CI 결과로 변경을 검토하고 QA 담당자는 수행한 케이스의 결과를 보존해야 한다. 실행 로그에 성공이 기록됐어도 JUnit에 빠지면 보고서만으로 수행 목록을 확인할 수 없다. 현재는 수집기가 이 모순을 검출해 해당 suite의 검증을 중단한다. 누락을 무시하면 결과 보존이 불완전하고, 엄격히 검증하면 후속 분석이 막힌다.

### 왜 해결해야 하는가

집계 차이를 허용하거나 결과 파일을 직접 고치면 실행한 케이스가 보고서에 보존된다는 보장이 사라진다. 실제 생성기를 수정하고 새 결과를 검증해야 CI 자료를 신뢰할 수 있다. 현재 PR 8347의 증거 수집을 막는 사례가 있으므로 원인과 수정 후보를 검토할 근거가 있다. 전체 발생 빈도와 배포 우선순위는 추가 판단이 필요하다.

## Triage Request

CTP 공통 결과 생성기의 결함을 확인하고 작성자 측의 추가 ANALYSIS와 회사 검토 배정을 요청한다. `CUBRIDQA`의 별도 `Task`로 추적하고 [CBRD-27841](https://jira.cubrid.org/browse/CBRD-27841)과 연결하는 방안을 제안한다. OOS M2 구현의 하위 작업과 구분한다. 이는 신규 티켓의 제안이며 현재 발급·배정·우선순위 변경은 수행하지 않았다.

## 확인한 실행과 소스

| 항목 | 확인한 값 |
| --- | --- |
| 엔진 | `eac70c7e740d55b4623b46bb84797e8214dcdcc4` |
| CI | [41048233875, attempt 1](https://github.com/CUBRID/cubrid/actions/runs/41048233875) |
| SQL shard | [01, job 124040698294](https://github.com/CUBRID/cubrid/actions/runs/41048233875/job/124040698294) |
| CTP 저장소 | `CUBRID/cubrid-testtools` |
| 실행 당시 CTP | `1c6b224d6f48eea01b8b4efa9f64f2521c40f2fd` |
| public testcase | `f54abce15d6d21e87a20f47fda2d678d100124fd` |
| 로컬 수정 tip | `4f720bd2edb9bf8020760f30d4a6a9088dff02b1` |
| 수정 브랜치 | `fix/sql-nested-summary-20261030`, 회사 PR의 대상은 `develop` |

SQL job의 시작·종료 provenance가 같은 CTP commit을 기록한다. 두 누락 케이스의 성공 행도 실행 로그에 있다. 따라서 다른 CTP checkout의 HEAD를 실행 버전으로 대신 사용하지 않았다. 정확한 commit을 별도 Git cache로 받아 추적된 JAR와 소스를 검사했다.

누락된 JUnit 경로는 다음 두 개이다.

- `sql/_05_plcsql/_01_testspec/_05_bug_fix/cbrd-27556/cases/33_static_sql_group_by_having_alias.sql`
- `sql/_05_plcsql/_01_testspec/_05_bug_fix/cbrd-27556/cases/33_static_sql_group_by_having_alias_error.sql`

부모 `_05_bug_fix/cases`와 하위 `_05_bug_fix/cbrd-27556/cases`가 함께 존재한다. 보존된 `summary_info` 974~980행에는 하위 범주의 `total:0`, `success:0` 뒤에 두 성공 행이 기록돼 있다. 전체 판정 행은 3,533개인데 root header와 JUnit은 3,531개이다.

## 첫 누락과 두 출력의 차이

`ConsoleBO.build`는 각 디렉터리의 직접 케이스를 해당 범주의 `Summary`에 등록한다. 범주 map에는 이 객체와 하위 범주 map이 동시에 있을 수 있다. [정확한 소스의 등록 지점](https://github.com/CUBRID/cubrid-testtools/blob/1c6b224d6f48eea01b8b4efa9f64f2521c40f2fd/CTP/sql/src/com/navercorp/cubridqa/cqt/console/bo/ConsoleBO.java#L400-L427).

기존 `TestUtil.makeSummary`는 `Summary`가 없을 때만 하위 범주를 순회한다. 이미 직접 케이스가 있는 범주에서는 하위 순회를 건너뛴다. 그 결과 자식의 집계가 0으로 남고 부모의 `childSummaryMap`에도 연결되지 않는다. [누락 조건과 집계](https://github.com/CUBRID/cubrid-testtools/blob/1c6b224d6f48eea01b8b4efa9f64f2521c40f2fd/CTP/sql/src/com/navercorp/cubridqa/cqt/console/util/TestUtil.java#L490-L590).

`saveResultSummary`는 원래 범주 map을 계속 순회하므로 자식의 성공 행을 파일에 쓴다. 반면 `JunitXmlWriter`는 연결된 Summary 트리를 따라가므로 그 자식을 볼 수 없다. 두 출력의 차이가 여기에서 발생한다. [물리 요약 저장](https://github.com/CUBRID/cubrid-testtools/blob/1c6b224d6f48eea01b8b4efa9f64f2521c40f2fd/CTP/sql/src/com/navercorp/cubridqa/cqt/console/util/TestUtil.java#L612-L637), [JUnit 순회](https://github.com/CUBRID/cubrid-testtools/blob/1c6b224d6f48eea01b8b4efa9f64f2521c40f2fd/CTP/sql/src/com/navercorp/cubridqa/cqt/console/util/JunitXmlWriter.java#L149-L168).

CI 실행 당시의 메모리 트리는 직접 캡처하지 않았다. 소스, 실제 경로, 누락된 두 결과와 정확한 바이너리의 재현 결과가 같은 동작을 가리킨다.

## 수정과 호환성

직접 케이스의 소유 목록을 유지하면서 모든 하위 범주를 순회한다. 각 Summary의 총계·시간·자식 연결과 그룹의 집계 목록은 매번 다시 계산한다. 경로는 재귀 호출마다 전달해 공유 `Test.dirPath`에 의존하지 않는다. JUnit은 직접 케이스를 출력한 뒤 자식도 순회한다. 물리 요약 파일에는 그 디렉터리가 소유한 판정 행만 쓴다.

독립 검토는 첫 수정에서 호환성 회귀 두 개를 찾았다. `sql//parent`의 빈 경로 요소를 별도 범주로 유지하면서 같은 물리 디렉터리가 보고서에 두 번 나타났고, root 실행 횟수가 1에서 0으로 바뀌었다. 이를 그대로 수용하지 않았다. 범주 map을 구성할 때 연속 구분자를 정규화하고 root 실행 횟수를 1로 유지했다. 직접 케이스를 소유한 Summary의 기존 경로 문자열은 보존한다.

기존 순수 말단·그룹 보고서의 SQL·medium 계층, root 실행 횟수, 직접 케이스의 경로, root에 직접 케이스가 있는 경우를 직렬화된 `summary.info`로 검사한다. 공개 메서드와 Summary 상수값은 그대로 사용한다. `TYPE_BOTTOM`은 직접 케이스를 소유한다는 의미이며 자식을 가질 수 있다.

## 실제 검증

최소 재현은 임시 입력·answer 파일을 만들고 실제 `ConsoleBO.build`, `makeSummary`, `makeSummaryInfo`, `saveResultSummary`, `JunitXmlWriter.write`를 호출한다. 케이스의 실행 결과를 성공으로 설정하며 데이터베이스를 시작하지 않는다. 수정 전후 같은 결과 생성 경로를 사용한다.

| 검사 | 수정 전 | 최종 수정 |
| --- | --- | --- |
| 부모·하위 디렉터리에 성공 1개씩 | 판정 행 2, 총계 1, JUnit 1. exit 1 | 판정 행 2, 총계 2, JUnit 2. exit 0 |
| 하위 케이스만 있는 대조군 | 1/1/1 통과 | 통과 |
| 서로 독립된 디렉터리 대조군 | 2/2/2 통과 | 통과 |
| SQL·medium 보고서 호환성 | 최초 수정에서 12개 검사 실패 | 정규화·root metadata 수정 뒤 통과 |
| 실제 3,533개 경로·결과·시간 재생 | 총계 3,531, JUnit 3,531, 고유 판정 행 3,533, 집계 시간 310,410ms | 총계·고유 JUnit·고유 판정 행 모두 3,533, 집계 시간 311,012ms |

마지막 검사는 해당 shard에서 보존한 모든 성공 경로와 기록된 소요 시간을 입력으로 사용했다. 수정 전 JUnit에 없는 경로가 실제 누락된 두 경로와 정확히 일치한다. 시간 차이는 그 두 케이스의 557ms와 45ms 합계 602ms이다. 이 시간은 기록된 값을 합산한 것이며 성능 측정값이 아니다. 수정 후 각 경로는 JUnit과 물리 판정 행에 정확히 한 번씩 나타난다.

회귀 테스트는 다음 사항도 확인한다.

- 여러 깊이의 중첩과 역순 입력, 직접 케이스 목록과 그룹 집계 목록의 소유 관계.
- 성공·실패·skip의 집계와 실제 실행된 케이스의 JUnit 기록.
- 반복 집계에서 중복이 발생하지 않음, site 범주 metadata, `MODE_NO_RESULT` 경로.
- SQL·medium의 직렬화된 범주 계층, root 실행 횟수 1, 같은 물리 경로를 가진 부모·자식이 없음.
- 변경한 production 클래스가 추적된 옛 JAR보다 앞서 로드됨. 새로 빌드한 임시 JAR로도 같은 테스트가 통과함.

실행 명령은 다음과 같다. 임시 빌드 디렉터리는 결과 검증용이며 source checkout의 추적된 JAR를 덮어쓰지 않는다.

```bash
./tests/sql-summary/run.sh
CTP_BUILD_DIR=$(mktemp -d)
ant -f CTP/build.xml -Dbuild="$CTP_BUILD_DIR" compile
```

전체 Ant 컴파일은 수정 전후 모두 성공했다. 최종 SQL runtime JAR를 그 출력으로 별도 생성한 뒤 `CTP_SQL_RUNTIME_JAR=<생성한 JAR> ./tests/sql-summary/run.sh`도 성공했다. Java 형식은 저장소가 사용하는 `google-java-format-1.7`의 출력과 대조했다.

## 검토할 커밋과 적용 경계

| 커밋 | 내용 |
| --- | --- |
| `a5263a1e16636972bd83491921202c9952ea6194` | 최초 재현을 고정한 실패 회귀 테스트 |
| `2750437c8bf414db46a73f2dc72a5d6f581e3009` | 중첩 집계와 JUnit 순회 수정 |
| `7a3acee9a0356a92386a68108302eec01f9fe57d` | 독립 검토가 찾은 보고서 호환성 회귀 테스트 |
| `4f720bd2edb9bf8020760f30d4a6a9088dff02b1` | 범주 정규화, root metadata와 직접 소유 경로 보존 |

로컬 source checkout은 `/home/vimkim/gh/ctp/fix-sql-nested-summary-20261030`이다. 기존 `develop` checkout `/home/vimkim/gh/ctp/run-sql`의 다른 작업은 보존했다. 회사 반영은 `CUBRID/cubrid-testtools:develop`을 대상으로 별도 리뷰를 받아야 한다. [준비한 PR 본문](https://github.com/vimkim/my-cubrid-docs/blob/cb836700a46b6f859e82377b0fe087ba22f490b9/cbrd-27841/CTP-nested-summary-pr-body_4f720bd_codex.md)을 함께 보존한다.

추적된 CTP JAR는 수정하지 않았다. 회사 runtime에 적용하려면 소스 리뷰·반영과 배포용 JAR 재생성이 필요하다. 이번 작업에서 회사 PR 생성, JIRA 변경, 배포, CI 재실행은 하지 않았다. Windows와 실제 SQL 실행을 포함한 전체 회귀는 검증하지 않았다.

기존 [CI 수집 경고](https://github.com/vimkim/my-cubrid-docs/blob/cb836700a46b6f859e82377b0fe087ba22f490b9/cbrd-27841/ci_analysis_report_eac70c7_codex.md)는 유효하다. 결과 파일을 직접 고치거나 collector 검사를 완화해 과거 자료를 통과시키지 않는다. 새 runtime의 새 결과가 검증된 뒤 정확한 기준 비교와 shell 두 실패의 이력·원인 분석을 재개한다. 이번 생성기 수정이 shell 실패의 원인을 설명하지는 않는다.

## 진행 체크리스트와 근거 위치

- [x] 실제 누락된 경로와 실행 당시 CTP commit을 확인한다.
- [x] 정확한 바이너리로 누락과 대조군을 재현한다.
- [x] 실패 테스트를 먼저 커밋하고 생성기 소스를 수정한다.
- [x] 독립 검토가 찾은 보고서 호환성 회귀를 별도 테스트로 고정하고 수정한다.
- [x] 소스·전체 Ant·새 JAR·실제 경로 3,533개 재생을 검증한다.
- [ ] 별도 회사 리뷰와 CTP runtime 반영을 진행한다.
- [ ] 새 CI 증거를 검증한 뒤 R6의 shell 실패 분석을 재개한다.

로컬 근거는 `/home/vimkim/temp/pr8347-sql-count-repair-20261030/`에 있다. `original-repro.json`, `sql01-gh.log`, `root-before-results.json`, `root-regression-before.log`, `root-compat-red.log`, `root-final/verification.json`, `root-final/source-regression.log`, `root-final/jar-regression.log`, `inventory-replay/{input.json,baseline.log,fixed.log}`이 위 검증을 보존한다. `decisions.tsv`에는 설계 선택과 독립 검토에서 수정한 판단을 기록한다. raw 파일과 임시 JAR는 문서 저장소에 넣지 않는다.
