#### **Description**

CUBRID SQL 쿼리문에서 벡터 값을 출력하기 위해 csql_result_format.c 파일의 'csql_db_value_as_string' 함수를 수정하여 DB_TYPE_VECTOR를 지원하도록 개선합니다.

#### **Spec Changes**

csql_result_format.c 파일의 'csql_db_value_as_string' 함수에 DB_TYPE_VECTOR 타입 처리 로직이 추가되어야 합니다.

#### **Implementation**

csql_result_format.c 파일의 'csql_db_value_as_string' 함수에 다음과 같은 코드를 추가했습니다:

```c
case DB_TYPE_SEQUENCE:
+++ case DB_TYPE_VECTOR:
  result = set_to_string (value,
                         default_set_profile.begin_notation,
                         default_set_profile.end_notation,
                         default_set_profile.max_entries,
                         csql_arg);
```

#### **Acceptance Criteria**

- CSQL에서 벡터 타입 컬럼을 포함한 SELECT 문 실행 시 벡터 값이 정상적으로 출력되어야 합니다.
- 벡터 값은 기존 시퀀스 타입과 동일한 형식으로 출력되어야 합니다.

#### **Definition of Done**

A/C
