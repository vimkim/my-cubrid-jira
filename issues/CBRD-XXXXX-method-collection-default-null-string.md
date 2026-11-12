# [PL/CSQL] NULL 원소가 있는 컬렉션 DEFAULT 컬럼을 %TYPE으로 참조하면 client가 std::logic_error로 비정상 종료하는 문제

**한 줄 요약**: cppcheck `nullPointer` 경고(`cubmethod::convert_db_value_to_string`에서 NULL 포인터로 `std::string`을 생성)를 확인하다가, DEFAULT 값에 NULL 원소가 있는 컬렉션 컬럼을 PL/CSQL `%TYPE`으로 참조하면 프로시저를 생성하는 client 프로세스가 `std::logic_error`로 abort되는 것을 재현했다. 이 결함을 고치고, 같은 helper를 쓰는 다른 경로도 함께 점검해야 한다.

## Issue Triage

**이슈 수행 목적**: 컬렉션 값을 문자열로 바꾸는 method/PL 공용 helper가 NULL 원소나 변환 실패를 만나도 프로세스를 종료하지 않게 한다. 그런 컬럼을 참조하는 PL/CSQL 프로시저는 정상적으로 생성되거나, 생성되지 않을 때는 오류를 반환해야 한다.

**이슈 수행 이유**: `src/method/method_query_util.cpp`의 `convert_db_value_to_string`은 `db_get_char`가 NULL을 반환할 수 있는데도 그 결과로 `std::string`을 만든다. C++ 표준에서 이는 정의되지 않은 동작이며, GCC 11 libstdc++에서는 `std::logic_error`가 발생한다. develop debug 빌드에서 SQL 세 문장으로 csql이 abort되는 것을 확인했다. 같은 함수의 broker 쪽 원본(`cas_execute.c`)에는 NULL 검사가 있지만 C++ 이식본에는 없다.

**영향**: 일반 사용자가 만들 수 있는 스키마(`SET(INT) DEFAULT {1, NULL}`)와 일반적인 PL/CSQL 선언(`%TYPE`)만으로 client 프로세스가 오류 메시지 없이 종료된다. CS 모드 csql에서는 세션이 끊긴다. broker를 거치면 같은 callback을 CAS 프로세스가 처리하므로 CAS가 재시작될 것으로 보이지만, 이는 확인하지 않았다. 서버(`cub_server`)는 종료되지 않았다. 질의 결과 컬럼 정보를 만드는 경로도 같은 helper를 쓰므로 Java SP나 PL/CSQL 안의 질의에도 영향이 있을 수 있다. 이 역시 확인하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

PL/CSQL 컴파일러는 `<table>.<column>%TYPE` 선언을 만나면 서버를 거쳐 client의 method callback(`METHOD_CALLBACK_GET_GLOBAL_SEMANTICS`)에 컬럼 정보를 묻는다. 이 callback(`get_column_info`)은 컬럼의 DEFAULT 값을 문자열로 만든다. DEFAULT 값이 컬렉션(`SET`, `MULTISET`, `SEQUENCE`)이면 각 원소를 `convert_db_value_to_string`으로 VARCHAR로 바꾼다.

```cpp
// src/method/method_query_util.cpp:463-474 (develop e64a04a79a)
std::string convert_db_value_to_string (DB_VALUE *value, DB_VALUE *value_string)
{
  const char *val_str = NULL;
  int err;
  err = db_value_coerce (value, value_string, db_type_to_db_domain (DB_TYPE_VARCHAR));
  if (err >= 0)
    {
      val_str = db_get_char (value_string);
    }

  return std::string (val_str);
}
```

이 함수에서 `val_str`이 NULL로 남는 경우는 두 가지다.

1. **원소가 NULL인 경우(재현됨)**: NULL 원소를 VARCHAR로 바꾸는 것은 성공하지만 결과도 NULL 값이다. `db_get_char`는 NULL 값에 대해 NULL을 반환한다(`src/compat/dbtype_function.i`). 아래 Repro가 이 경로다.
2. **VARCHAR로 바꾸지 못한 경우(정적 분석으로만 확인)**: `db_value_coerce`가 실패하면 `val_str`은 초기값 NULL로 남는다. cppcheck가 가리킨 경로다. 실제로 변환에 실패하는 원소 타입이 있는지는 확인하지 않았다.

broker의 원본 구현 `src/broker/cas_execute.c`의 `convert_db_value_to_string`은 `const char *`를 반환하고, 호출자 `serialize_collection_as_string`이 `single_value == NULL`을 검사한다(10252, 10286행). method 모듈의 C++ 이식본은 반환 타입을 `std::string`으로 바꾸면서 이 검사를 잃었다.

### 호출 경로

develop `e64a04a79a` 기준이다.

- `cubmethod::serialize_collection_as_string` (`method_query_util.cpp:811`)이 `convert_db_value_to_string`을 호출하는 유일한 호출자다.
- `cubmethod::get_column_default_as_string` (`method_query_util.cpp:749`)이 컬렉션 DEFAULT 값에 대해 이를 호출한다.
- `get_column_default_as_string`의 호출자는 두 곳이다.
  - `get_column_info` (`method_callback.cpp:1054`): PL/CSQL `%TYPE` 컴파일 경로. **재현됨.**
  - `query_handler::set_column_info` (`method_query_handler.cpp:1070`): server-side JDBC나 PL/CSQL이 질의를 prepare할 때 결과 컬럼 정보를 만드는 경로로 보인다. **재현하지 않음.**

### Test Build

- cppcheck 2.22.0, `--project=<build>/compile_commands.json --enable=warning,performance,portability`, CUBRID develop `e64a04a79a` (debug GCC preset): `method_query_util.cpp`에서 `nullPointer` 경고가 나왔다.
- 재현은 이미 설치되어 있던 CUBRID 11.5.0.2635-30043f4 (64bit debug build, GCC 11, Linux)에서 했다. `30043f4`는 `e64a04a79a`의 조상이다. 두 리비전 사이에 `method_query_util.cpp`가 바뀌었지만, `convert_db_value_to_string`, `serialize_collection_as_string`, `get_column_default_as_string`의 본문과 `get_column_info`의 해당 호출부는 같다. `e64a04a79a` 빌드에서는 실행하지 않았다.
- CS 모드, PL 서버(`cub_pl`) 실행 상태.

### Repro

DB를 만들고 서버를 시작한 뒤 csql로 다음을 실행한다.

```bash
cubrid createdb testdb en_US.utf8
cubrid server start testdb
cat > repro.sql <<'EOF'
DROP TABLE IF EXISTS cbrd_nullstr_t;
CREATE TABLE cbrd_nullstr_t (c SET(INT) DEFAULT {1, NULL});
CREATE OR REPLACE PROCEDURE cbrd_nullstr_p() AS v cbrd_nullstr_t.c%TYPE; BEGIN NULL; END;
EOF
csql -u dba -C testdb -i repro.sql
```

### Expected Result

`CREATE OR REPLACE PROCEDURE`가 성공하거나, 지원하지 않는 선언이라면 오류를 반환한다. 어느 쪽이든 csql은 계속 실행된다. 참고로 `SHOW COLUMNS FROM cbrd_nullstr_t`는 이 컬럼의 Default를 `'{1, NULL}'`로 보여준다.

### Actual Result

csql이 abort된다(종료 코드 134).

```text
terminate called after throwing an instance of 'std::logic_error'
  what():  basic_string::_M_construct null not valid
```

gdb backtrace(30043f4 빌드, 행 번호도 30043f4 기준):

```text
#9  std::__cxx11::basic_string<...>::basic_string (__s=0x0, ...)
#10 cubmethod::convert_db_value_to_string (...) at src/method/method_query_util.cpp:472
#11 cubmethod::serialize_collection_as_string (...) at src/method/method_query_util.cpp:765
#12 cubmethod::get_column_default_as_string (...) at src/method/method_query_util.cpp:703
#13 cubmethod::get_column_info (...) at src/method/method_callback.cpp:945
#14 cubmethod::callback_handler::get_global_semantics (...) at src/method/method_callback.cpp:993
#15 cubmethod::callback_handler::callback_dispatch (...) at src/method/method_callback.cpp:131
#16 method_dispatch_internal (...) at src/method/query_method.cpp:225
#18 net_client_request_method_callback (request=179, ...) at src/communication/network_cl.c:1806
#19 plcsql_transfer_file (...) at src/communication/network_interface_cl.c:11606
```

서버 프로세스는 계속 실행되었고, 이후 같은 DB에 다시 접속해 테이블을 삭제할 수 있었다.

### ANALYSIS에서 확인할 사항

- NULL 원소를 DEFAULT 문자열에 어떻게 표시할지 정해야 한다. `SHOW COLUMNS`는 `{1, NULL}`을 보여준다. 반면 broker 원본은 NULL 원소가 있으면 컬렉션 전체 문자열을 만들지 않는다. 둘 중 어느 쪽과 맞출지 결정이 필요하다.
- 질의 결과 컬럼 정보 경로(`query_handler::set_column_info`)에서 같은 테이블을 조회하는 Java SP나 PL/CSQL 질의가 같은 방식으로 종료되는지 확인한다.
- broker(CAS)를 거쳐 PL/CSQL 프로시저를 만들 때 CAS가 종료되는지 확인한다.
- `db_value_coerce`가 VARCHAR 변환에 실패하는 컬렉션 원소 타입이 실제로 있는지 확인한다.
- 같은 함수의 기본 분기(`method_query_util.cpp:775`, `result_default_value_string.assign (def_str_p)`)도 NULL 검사 없이 `db_get_string` 결과를 쓴다. 이 분기에서 NULL이 나올 수 있는지 함께 점검한다.

### 관련 이슈

- [CBRD-26631](https://jira.cubrid.org/browse/CBRD-26631): `COLLECTION_TO_STRING` 내장 함수를 추가했다. 이 함수는 NULL 원소를 문자열 `NULL`로 표시한다. NULL 원소의 표시 방식을 정할 때 참고할 수 있다. 같은 결함은 아니다.
- [CBRD-21328](https://jira.cubrid.org/browse/CBRD-21328): broker(CAS)의 `get_column_default_as_string`에서 DEFAULT 식 문자열을 만들다 버퍼를 넘어 써서 CAS가 비정상 종료한 문제다(10.1, 해결됨). 같은 기능의 다른 결함이다.
