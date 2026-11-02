# UPDATE 및 DELETE prepare 경로의 xasl_header stack-use-after-scope 수정

## Issue Triage

**이슈 수행 목적**: UPDATE와 DELETE의 실행 계획을 준비할 때 수명이 끝난 stack 변수에 접근하지 않게 한다.

**이슈 수행 이유**: `do_prepare_update()`와 `do_prepare_delete()`가 안쪽 블록의 `xasl_header` 주소를 `stream.xasl_header`에 저장한다. 캐시 미스 후 블록 밖의 두 번째 `prepare_query()`가 이 포인터를 사용한다. 기존 리뷰가 ASan 오류를 보고했고, 소스 및 도입 커밋을 확인했다.

**영향**: 일반 UPDATE와 DELETE의 계획 준비 경로에 유효하지 않은 메모리 접근이 있다. 클라이언트의 비정상 종료 위험이 있으나 운영 발생 빈도와 실제 데이터 영향은 확인하지 않았다. OOS 컬럼의 존재를 전제하지 않는다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

> 아래는 기존 리뷰의 ASan 보고와 별도로 수행한 소스 및 수정 이력 확인을 바탕으로 작성했다. 이번 이슈 작성 과정에서는 ASan 재현을 새로 실행하지 않았다.

## Description

### 무엇이 문제인가

UPDATE와 DELETE는 먼저 서버의 실행 계획 캐시를 조회한다. 캐시에 계획이 없으면 계획을 만들고 다시 `prepare_query()`를 호출한다. 두 호출에서 사용하는 `XASL_STREAM`은 동일하다.

두 함수의 첫 호출은 다음 형태다.

```c
if (statement->flag.recompile == 0)
  {
    XASL_NODE_HEADER xasl_header = { 0, 0 };
    stream.xasl_header = &xasl_header;
    err = prepare_query (contextp, &stream);
  }
```

이 블록을 벗어나면 `xasl_header`의 수명은 끝난다. 그러나 `stream.xasl_header`는 해당 주소를 유지한다. 캐시 미스 후 새 계획을 준비하는 두 번째 호출은 이 블록 밖에서 실행된다. `xts_map_xasl_to_stream()`은 이 포인터를 초기화하지 않으며, CS 경로의 `qmgr_prepare_query()`는 `INIT_XASL_NODE_HEADER(stream->xasl_header)`를 수행한다.

기존 리뷰는 이 초기화에서 `stack-use-after-scope`가 발생했다고 보고한다. 필요한 동작은 두 번째 준비 요청까지 유효한 header 저장 공간을 사용하는 것이다.

### 왜 문제인가

응용 프로그램과 사용자는 정상 UPDATE 또는 DELETE를 준비하고 실행할 수 있어야 한다. 실행 계획이 아직 캐시에 없다는 일반적인 조건에서 클라이언트가 수명이 끝난 stack 변수에 쓰면, 같은 SQL이라도 캐시 상태와 빌드에 따라 준비가 실패하거나 프로세스가 종료될 위험이 있다. 이 이슈의 확인된 실행 근거는 원본 리뷰의 ASan 보고이며, 실제 운영 장애나 데이터 손상은 확인하지 않았다.

### 왜 해결해야 하는가

캐시를 미리 채우는 방식은 신규 SQL, 캐시 교체 및 재컴파일을 통제하지 못하므로 충분한 우회가 아니다. SELECT의 동일한 수명 문제는 이미 수정된 전례가 있다. UPDATE와 DELETE를 함께 확인하면 같은 원인의 잔여 경로를 한 번에 검증할 수 있다.

## Triage Request

독립적인 Correct Error 이슈로 확인하고 작성자 측에 ANALYSIS를 배정해 주기를 요청한다. UPDATE와 DELETE를 함께 다루며 캐시 미스, 캐시 히트 및 재컴파일 경로의 포인터 수명을 확인한다. 지원 릴리스의 영향 범위와 backport 필요성은 별도로 판정한다.

## Test Build

- 원본 리뷰는 feature base `dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67` 및 PR #8299 계열에서 ASan 결과를 보고한다. 정확한 실패 실행의 빌드 명령과 SQL은 보고서만으로 확정할 수 없다.
- 소스 비교 기준은 develop `d5674fe94f08d084c6832ba4e3f6521d66cbee0e`이다. 추가로 develop `2b3158b66843052fdecadff60df864bbee84fab1`에도 두 block-local 선언과 블록 밖의 두 번째 호출이 남아 있음을 확인했다.
- 이번 이슈 작성 중 새 빌드나 재현을 실행하지 않았다. 릴리스별 재현 여부는 미확인이다.

## Repro

아래는 미실행 검증 제안이다.

1. ASan과 stack-use-after-scope 검출을 켠 client를 준비한다.
2. 서버 실행 계획 캐시에 없는 일반 테이블의 UPDATE와 DELETE를 각각 준비한다.
3. 두 번째 `prepare_query()`에서 `stream.xasl_header`의 유효 수명과 sanitizer 결과를 확인한다.
4. 같은 SQL의 캐시 히트와 명시적 재컴파일도 대조한다.

기존 보고서의 정확한 최소 SQL과 실행 명령을 확보하는 것을 ANALYSIS 산출물에 포함한다.

## Expected Result

모든 준비 요청에서 `stream.xasl_header`가 가리키는 객체가 유효하다. UPDATE와 DELETE의 결과 및 계획 캐시 동작을 유지하고 ASan의 수명 오류가 발생하지 않는다.

## Actual Result

기존 리뷰는 `qmgr_prepare_query()`의 header 초기화에서 `stack-use-after-scope`를 보고한다. 소스에서도 블록 밖의 두 번째 호출까지 지역변수 주소가 남는 흐름을 확인했다.

## Additional Information

- [UPDATE의 선언 위치](https://github.com/CUBRID/cubrid/blob/2b3158b66843052fdecadff60df864bbee84fab1/src/query/execute_statement.c#L10020)와 [두 번째 호출](https://github.com/CUBRID/cubrid/blob/2b3158b66843052fdecadff60df864bbee84fab1/src/query/execute_statement.c#L10110), [DELETE의 선언 위치](https://github.com/CUBRID/cubrid/blob/2b3158b66843052fdecadff60df864bbee84fab1/src/query/execute_statement.c#L11415)와 [두 번째 호출](https://github.com/CUBRID/cubrid/blob/2b3158b66843052fdecadff60df864bbee84fab1/src/query/execute_statement.c#L11493)을 확인했다.
- [CBRD-26768](http://jira.cubrid.org/browse/CBRD-26768)의 [SELECT 수정 커밋 a454b8eff](https://github.com/CUBRID/cubrid/commit/a454b8eff7c47fb2528c08f043fbc942974b4215)과 [PR #7144](https://github.com/CUBRID/cubrid/pull/7144)는 `do_prepare_select()`만 수정했다. 새 이슈는 그 SELECT 수정의 중복이 아니다.
- UPDATE와 DELETE의 block-local header는 CBRD-26959의 커밋 `532ce4b6d`, [PR #7476](https://github.com/CUBRID/cubrid/pull/7476)에서 추가되었다. SELECT에 수정된 코드가 되돌아간 경우와는 구분한다.
- [CBRD-20383](http://jira.cubrid.org/browse/CBRD-20383)은 XASL stream의 포인터 구조를 재편하는 더 넓은 과제다. 이번 이슈는 현재 DML 두 경로의 수명 오류를 대상으로 한다.
- [원본 리뷰의 non-OOS 기존 문제 절](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27785/CBRD-27785-pr8299-adversarial-review_f8114e432_claude.md#non-oos-existing)에 ASan 보고의 출처가 있다. [CBRD-27873](http://jira.cubrid.org/browse/CBRD-27873)은 이를 후보로 기록한 이슈다.
