# release 빌드에서 XASL stream의 정렬 여백이 초기화되지 않아, 파티션 표현식과 함께 이전 클라이언트 메모리가 카탈로그에 저장된다

**한 줄 요약**: CUBRID/cubrid#8693(CBRD-28257) 코드 리뷰에서 별도 결함으로 지적된 항목(U-2)이며, 함께 제출된 TC `cbrd_28257`(CUBRID/cubrid-testcases-private-ex#5098)도 "다른 결함"으로 언급한 내용이다. XASL stream 직렬화 코드가 정렬 여백을 debug 빌드에서만 0으로 채우므로, release 빌드에서 파티션 테이블을 만들면 그 여백의 이전 클라이언트 메모리가 파티션 표현식 stream에 섞여 카탈로그에 저장된다. 이 이슈는 빌드 종류와 관계없이 stream에 이전 메모리가 남지 않게 하는 것을 다룬다.

## Issue Triage

**이슈 수행 목적**: XASL stream의 정렬 여백과 남는 바이트를 빌드 종류와 관계없이 0으로 채워, 파티션 표현식처럼 카탈로그에 저장되는 stream에 이전 클라이언트 메모리가 들어가지 않게 한다.

**이슈 수행 이유**: `src/query/xasl_to_stream.c` 는 stream 버퍼를 `malloc`·`realloc` 으로 받고, 정렬 때문에 생기는 여백과 값 크기를 넉넉히 잡아 남는 바이트를 `#if !defined(NDEBUG)` 안에서만 `memset` 으로 지운다. 주석은 valgrind 경고를 막으려는 목적이라고 적고 있다. 파티션 테이블을 만들 때 `execute_schema.c` 는 컴파일한 파티션 표현식 stream을 VARCHAR 값으로 파티션 정보에 넣으므로, release 빌드에서는 지워지지 않은 여백이 문자열 내용으로 root class 레코드와 `_db_partition` 카탈로그 행에 저장된다. 소스 확인만 했고 release 빌드로 재현하지는 않았다.

**영향**: release 빌드에서 파티션 테이블을 만들거나 파티션을 바꾸는 사용자의 카탈로그에, 그 클라이언트(CAS, csql)가 직전에 쓰고 해제한 메모리 조각이 들어갈 수 있다(소스 기반 추론). 카탈로그 클래스는 TDE 암호화 대상이 아니므로, 그 조각이 암호화 테이블의 조회 결과였다면 평문으로 디스크에 남는다. 조각의 크기는 정렬 여백 단위(수 바이트)로 작고, 실제로 어떤 내용이 얼마나 들어가는지는 확인하지 않았다. 표현식을 읽고 실행하는 동작에는 영향이 없다. CBRD-28257 보다 시급성은 낮다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

### 배경: XASL stream과 파티션 표현식

XASL은 클라이언트가 만든 실행 계획이고, `xts_*` 함수는 이를 서버로 보내거나 저장할 바이트 stream으로 직렬화한다. 파티션 테이블의 분할 기준 표현식(예: `PARTITION BY RANGE (a)` 의 `a`)은 `compile_partition_expression ()` 이 `FUNC_PRED` 로 컴파일한 뒤 `xts_map_func_pred_to_stream ()` 으로 stream을 만든다. 이 stream은 실행 계획처럼 한 번 쓰고 버리는 것이 아니라 카탈로그에 저장된다.

### 원인 (develop `cbed1d5707` 기준)

develop `e23905d89a` 이후 `cbed1d5707` 까지 아래 파일은 바뀌지 않았다.

- `xts_reserve_location_in_stream ()`(`src/query/xasl_to_stream.c:9171`): stream 버퍼를 `malloc`·`realloc` 으로 늘리고, 요청 크기를 `MAX_ALIGNMENT` 로 올린 뒤 늘어난 바이트를 9212-9217행의 `#if !defined(NDEBUG)` 안에서만 0으로 채운다.
- `xts_save_regu_variable ()`(1379행): 값 크기를 `OR_VALUE_ALIGNED_SIZE` 로 넉넉히 잡고 `malloc` 한 임시 버퍼에 쓴 뒤, 쓰지 않은 나머지(margin)를 1439-1448행의 `#if !defined(NDEBUG)` 안에서만 0으로 채우고 stream에 복사한다.
- `xts_save_xasl_node ()`(1751행)의 1812행 블록과 `xts_map_xasl_to_stream ()` 의 358-363행 블록도 같은 형태다. 이 둘은 질의 실행용 XASL에 쓰이고, 카탈로그에 저장되는 파티션 표현식 경로에서 지나는지는 확인하지 않았다.
- 저장 위치: `src/query/execute_schema.c:16758` 이 `db_make_varchar (&expr, part_expr->expr_stream_size, part_expr->expr_stream, ...)` 로 stream 전체를 VARCHAR 값으로 만들어 파티션 정보 컬렉션에 넣는다. 이 컬렉션은 root class 레코드와 `_db_partition` 행에 문자열 내용으로 저장된다.
- 서버 쪽 카탈로그 행 작성(`catalog_class.c`)은 이 문자열을 받은 그대로 쓴다. 그래서 CBRD-28257 의 수정(#8693)이 들어가도 이 바이트는 남는다.

### Test Build

- 소스 확인만 했다(develop `cbed1d5707`). release 빌드는 실행하지 않았다.
- debug 빌드에서는 위 `memset` 이 동작하므로 이 결함이 나타나지 않는다.

### Repro

실행하지 않은 제안 절차다.

1. release 빌드에서 DB를 만들고, 같은 클라이언트 세션에서 marker 문자열을 담은 큰 값을 여러 번 조회하거나 넣어 클라이언트 힙을 채운다.
2. 같은 세션에서 `CREATE TABLE p (a INT, b VARCHAR(100)) PARTITION BY RANGE (a) (PARTITION p0 VALUES LESS THAN (10), PARTITION p1 VALUES LESS THAN MAXVALUE);` 를 실행한다.
3. 서버를 정상 종료한 뒤 `_db_partition` 과 root class 레코드가 있는 힙 페이지(`cubrid diagdb -d 9` 또는 볼륨 파일 직접 읽기)에서 표현식 stream의 정렬 여백이 0이 아닌지, marker 조각이 있는지 본다.

### Expected Result

stream의 정렬 여백과 남는 바이트는 빌드 종류와 관계없이 0이다. 같은 파티션 정의는 항상 같은 stream 바이트를 만든다.

### Actual Result

release 빌드에서는 여백 바이트가 `malloc` 이 돌려준 메모리의 이전 내용을 그대로 가진다(소스 판단, 미재현).

### Additional Information

- **수정 방향 후보**(리뷰 제안, ANALYSIS 에서 결정): `#if !defined(NDEBUG)` 를 없애 `memset` 을 항상 실행하거나, stream 버퍼와 임시 버퍼를 `calloc` 으로 받는다. 여백만 지우므로 비용은 작을 것으로 보이나, 질의마다 XASL을 직렬화하는 경로의 비용은 ANALYSIS 에서 확인한다.
- **ANALYSIS 확인 사항**:
    1. 함수 인덱스 표현식(`execute_schema.c:15979`)과 필터 인덱스 조건(3441, 16358행)도 같은 `xts_map_*` 함수로 stream을 만들어 저장하는지, 그렇다면 같은 문제가 있는지.
    2. 5285행 근처처럼 debug 빌드에서만 값을 채우는 다른 블록이 저장되는 stream에 영향을 주는지.
    3. 이미 만들어진 DB의 카탈로그에 남은 여백을 다시 쓸 필요가 있는지.
- **관련**: CBRD-28257(카탈로그 클래스 힙 행의 이전 메모리, #8693), CBRD-28096(같은 파일의 `xts_save_packable_object` 가 원본 버퍼 끝을 4바이트 넘어 읽는 다른 결함), CBRD-27163(파티션 키·필터 인덱스 stream 크기 제한, 해결됨). 중복 이슈는 찾지 못했다.
