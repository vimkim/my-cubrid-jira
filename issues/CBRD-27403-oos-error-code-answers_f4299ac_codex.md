# OOS 오류 번호 변경 후 SQL·shell 테스트 정답 갱신

## Issue Triage

**이슈 수행 목적**: `feat/oos`의 현재 오류 번호와 회귀 테스트의 정답을 일치시킨다.

**이슈 수행 이유**: AS-IS는 develop 병합 전 OOS 오류 번호를 정답에 저장해 두 SQL 테스트와 두 shell 테스트가 실패한다. TO-BE는 같은 오류 조건과 기본 목록을 현재 번호로 검사하여 실제 동작 회귀와 번호 변경을 구분한다.

**이슈 수행 방안**: SQL 정답 두 파일의 OOS 최대 크기 오류를 `-1381`에서 `-1382`로 바꾼다. shell 정답 세 파일의 OOS 기본 오류 목록을 `-1380,-1382,-1383`에서 `-1381,-1383,-1384`로 바꾼다. SQL·shell 입력과 비교 조건은 유지한다.

---

## AI-Generated Context

> 아래는 AI가 코드와 CI 증거를 분석해 작성한 상세 자료다.

### 변경 범위

`cubrid-testcases`의 `bug_bts_10516.answer`, `fbo_ddl02.answer` 및 `cubrid-testcases-private-ex`의 `bug_bts_9836` 정답 두 파일, `bug_bts_14120` 정답 한 파일이다. 엔진 동작이나 데이터 형식은 바꾸지 않는다.

## Description

소스 `f4299ac0cd777a2a964c1f197ae5ebf9841a4936`의 develop 병합은 `ER_CDC_ARCHIVE_KEPT=-1379`를 추가하고 뒤의 OOS(큰 컬럼 값을 별도 페이지에 저장하는 방식) 오류 정의를 하나씩 이동했다. `system_parameter.c`의 기본 호출 스택 목록은 기호 상수를 사용하므로 새 번호를 출력한다. 테스트 정답은 이전 숫자를 유지한다.

## Test Build

CUBRID 11.5.0.2648-f4299ac, Linux. CircleCI SQL job 153253, shell job 153250; GitHub Actions run 34207150213.

## Repro

```sh
# 각 CTP 설정의 scenario를 아래 테스트 경로로 지정한다.
ctp.sh sql -c sql.conf
ctp.sh shell -c shell.conf
```

- `sql/_13_issues/_14_1h/cases/bug_bts_10516.sql`
- `sql/_15_fbo/_02_qa_test/cases/fbo_ddl02.sql`
- `shell/_06_issues/_12_2h/bug_bts_9836`
- `shell/_06_issues/_14_2h/bug_bts_14120`

## Expected Result

현재 엔진의 기호 오류 정의에 해당하는 숫자와 기본 호출 스택 목록을 검사하고 네 테스트가 통과한다.

## Actual Result

SQL 두 건의 유일한 diff는 `Error:-1381` 대신 `Error:-1382`다. Actions shell 두 건은 기본 호출 스택 목록 비교에서 실패한다.

## Additional Information

- SQL testcase revision: `54ebf3b458506f1360b5a03992b4987f4783488e`.
- Actions shell testcase revision: `777b97745076ba2c48cf7e103857f0abbc765b5d`.
- 기존 CDC 수리 CBRD-26939와 JDBC torn-read 수리 CBRD-27400은 별도 원인이다.
- 같은 f4299ac 엔진에서 기존 shell 정답의 실패를 재현했고, 변경 후 bug_bts_9836의 3개 검사와 bug_bts_14120의 2개 검사가 통과했다. SQL 두 테스트도 기존 정답에서 각각 1건 실패하고 수정 후 각각 1/1 통과했다.
