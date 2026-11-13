# [PARSER] pt_coerce_value_internal ()이 기본 data type 생성 실패 시 오류 코드 대신 1을 반환한다

**한 줄 요약**: CodeQL 정적 분석(`cpp/ambiguous-assignment-of-comparison`)이 찾은 괄호 누락으로, `pt_coerce_value_internal ()`이 `pt_set_default_data_type ()`의 음수 오류 코드를 버리고 비교 결과 `1`을 반환하는 문제를 고친다.

## Issue Triage

**이슈 수행 목적**: `pt_coerce_value_internal ()`이 `pt_set_default_data_type ()` 실패 시 받은 음수 오류 코드를 그대로 호출자에게 돌려주게 한다.

**이슈 수행 이유**: `(err = pt_set_default_data_type (...) < 0)`에서 `<`가 `=`보다 먼저 결합한다. 그래서 `err`에는 오류 코드가 아니라 비교 결과 `1`이 들어가고, 함수는 `1`을 반환한다. CUBRID 함수의 오류 규약(`NO_ERROR` 또는 음수 오류 코드)을 어기는 반환값이다.

**영향**: 이 실패 경로에서 호출자는 실제 오류 코드(`ER_GENERIC_ERROR`, -2) 대신 양수 `1`을 받는다. 반환값을 검사하는 호출자는 모두 `!= NO_ERROR` 또는 `== NO_ERROR`로 검사하므로 실패를 성공으로 오인하지는 않는다. 다만 `1`을 위로 전달하는 경로에서 오류 코드가 사라진다. 이 실패 경로는 SQL로 재현하지 못했으므로, 사용자에게 보이는 영향과 발생 빈도는 확인되지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

`pt_coerce_value_internal ()` (`src/parser/type_checking.c`)은 PT_VALUE 노드를 원하는 타입으로 변환한다. 대상 타입이 길이나 정밀도 같은 매개변수를 갖는 타입(`PT_IS_PARAMETERIZED_TYPE`)이고 `data_type` 인자가 `NULL`이면, `pt_set_default_data_type ()`으로 기본 data type 노드를 만든다. 이 호출의 결과 처리에 괄호가 빠져 있다.

```c
  if (data_type == NULL && PT_IS_PARAMETERIZED_TYPE (desired_type)
      && (err = pt_set_default_data_type (parser, desired_type, &data_type) < 0))
    {
      return err;
    }
```

의도는 `(err = pt_set_default_data_type (...)) < 0`이지만, 실제로는 `err = (pt_set_default_data_type (...) < 0)`로 해석된다. 실패 시 `err`은 `1`이 되고 함수는 `1`을 반환한다. 성공 시 `err`은 `0`이 되므로 정상 경로의 동작은 바뀌지 않는다. 함수 주석도 반환값을 `NO_ERROR on success, non-zero for ERROR`로 설명한다. 이 코드는 2014년 이전부터 있었다.

### pt_set_default_data_type ()이 실패하는 조건

소스에서 확인한 실패 조건은 두 가지다. 둘 다 `ER_GENERIC_ERROR`(-2)를 반환한다.

1. `parser_new_node ()`가 `NULL`을 반환하는 경우(메모리 부족).
2. `type`이 switch에 없는 타입인 경우. `PT_IS_PARAMETERIZED_TYPE`은 `NUMERIC`, `VARCHAR`, `CHAR`, `VARBIT`, `BIT`, `ENUMERATION`을 포함하지만, `pt_set_default_data_type ()`의 switch는 `ENUMERATION`을 처리하지 않는다. 따라서 `desired_type`이 `PT_TYPE_ENUMERATION`이고 `data_type`이 `NULL`이면 default 분기에서 `PT_INTERNAL_ERROR (parser, "type check")`를 설정하고 `ER_GENERIC_ERROR`를 반환한다.

두 번째 경우에는 parser 오류가 함께 설정된다. 그래서 `pt_has_error ()`를 검사하는 호출자는 오류를 감지할 수 있다. 첫 번째 경우에 `er_errid ()`가 어떤 값을 갖는지는 확인하지 않았다.

### 호출자의 반환값 처리

`pt_coerce_value ()`, `pt_coerce_value_explicit ()`, `pt_coerce_value_for_default_value ()`의 호출 지점(`src/parser/`, `src/query/execute_schema.c`)을 확인했다.

- 반환값을 `< 0`으로 검사하는 호출자는 없다. 실패를 성공으로 오인하는 호출자는 확인되지 않았다.
- `!= NO_ERROR` 또는 `== NO_ERROR`로 검사하는 호출자는 `1`을 실패로 처리한다.
- `(void)`로 반환값을 버리는 호출자(`type_checking.c`의 IN 목록, 비교 연산 처리 등)는 어떤 값이든 영향을 받지 않는다.
- 일부 호출자는 받은 값을 그대로 위로 반환한다. 예: `semantic_check.c`의 `error = pt_coerce_value (...)`, `execute_schema.c`의 `do_alter_one_clause_with_template ()`(ALTER ... DEFAULT 변경)와 `get_att_default_from_def ()`. 이 경로에서는 `-2` 대신 `1`이 상위 호출자에게 전달된다.

## Test Build

- 소스 기준: CUBRID develop `e64a04a79a`
- 실행 빌드: CUBRID 11.5.0.2635-30043f4 debug build (Linux x86_64). 이 빌드의 `pt_set_default_data_type ()`, `pt_coerce_value_internal ()`, `PT_IS_PARAMETERIZED_TYPE`은 `e64a04a79a`와 같다.
- 정적 분석: CodeQL 2.27.4, `cpp/ambiguous-assignment-of-comparison` (Likely Bugs/Likely Typos/AmbiguousAssignmentOfComparison), build-mode none

## Repro

### SQL로 재현 시도: 재현하지 못함

`csql -S`로 새 DB에서 ENUM 컬럼을 대상으로 비교, IN, BETWEEN, UNION, COALESCE, IF, CASE, GREATEST/LEAST, NVL/NULLIF, row 비교, ANY 서브쿼리, UPDATE, ALTER ... DEFAULT, CAST, PREPARE/EXECUTE 문을 실행했다. gdb로 `pt_set_default_data_type ()`의 호출을 모두 기록했다. 호출은 `VARCHAR` 대상으로 한 번만 일어났고, `ENUMERATION` 대상 호출은 일어나지 않았다.

과거에 같은 default 분기에 도달한 [CBRD-3](https://jira.cubrid.org/browse/CBRD-3)의 재현 SQL(ENUM 컬럼의 `DEFAULT (a)`를 view로 조회)도 실행했다. 이 SQL은 2013년에 `System error (type check)`를 냈지만, 현재 빌드에서는 정상 결과를 반환했고 `pt_set_default_data_type ()`도 호출되지 않았다. 따라서 현재 SQL에서 이 실패 경로에 도달하는 조건은 확인되지 않았다.

### 오류 주입으로 반환값 확인

실패 경로의 반환값을 확인하려고 gdb에서 `pt_set_default_data_type ()`이 `-2`를 반환하도록 강제했다. 이 결과는 코드 결함의 동작만 보여 주며, 실제 SQL 실패를 재현한 것은 아니다.

```sql
-- in.sql
create table t_e (a enum('red','green','blue'), c int);
insert into t_e values ('red',1), ('blue',2);
select * from t_e where a in ('red', 1, 'blue');
drop table t_e;
```

```
# g.gdb
set pagination off
set confirm off
set breakpoint pending on
break pt_set_default_data_type
run
bt 3
return (int) -2
next
print err
finish
delete
cont
```

```sh
cubrid createdb cqrepro en_US.utf8
gdb -batch -x g.gdb --args $CUBRID/bin/csql -S -u dba -i in.sql cqrepro
cubrid deletedb cqrepro
```

## Expected Result

`pt_set_default_data_type ()`이 `ER_GENERIC_ERROR`(-2)를 반환하면 `pt_coerce_value_internal ()`도 `-2`를 반환한다.

## Actual Result

```
#1 pt_coerce_value_internal (..., desired_type=PT_TYPE_VARCHAR, data_type=0x0, check_string_precision=false, implicit_coercion=true)
#2 pt_coerce_value (..., desired_type=PT_TYPE_VARCHAR, data_type=0x0)
INJECT: force pt_set_default_data_type to return -2 (ER_GENERIC_ERROR)
AFTER CONDITION: err=1
Value returned is $1 = 1
```

`err`은 `1`이 되고 `pt_coerce_value_internal ()`은 `1`을 반환했다. 이 호출 지점은 반환값을 버리므로 SELECT는 정상 결과 2건을 출력했다.

## Additional Information

관련 이슈(중복 아님):

- [CBRD-3](https://jira.cubrid.org/browse/CBRD-3) (Closed): `data_type`이 `NULL`인 ENUM이 `pt_coerce_value ()`에 전달되어 같은 default 분기에서 `System error (type check)`가 발생했다. 그 이슈는 종료되었다. 이 이슈는 그 분기가 반환한 오류 코드를 `pt_coerce_value_internal ()`이 `1`로 바꾸는 문제를 다룬다.
- [CBRD-27549](https://jira.cubrid.org/browse/CBRD-27549) (Open): 클라이언트 경로가 오류를 삼키거나 다른 오류로 바꾸는 문제를 다룬다. 문제 유형은 비슷하지만 대상 위치(통계, 히스토그램, 도메인 검사 등)가 다르다.

## ANALYSIS에서 확인할 사항

- `desired_type`이 `PT_TYPE_ENUMERATION`이고 `data_type`이 `NULL`인 상태로 `pt_coerce_value_internal ()`에 도달하는 SQL 경로가 있는가. 있다면 사용자에게 어떤 오류 메시지가 보이는가.
- `semantic_check.c`와 `execute_schema.c`에서 받은 값을 그대로 반환하는 경로에서, 양수 `1`이 상위 호출자(`do_alter ()` 등)와 클라이언트에 어떻게 전달되는가. 양수 반환값을 행 수 등 다른 의미로 해석하는 상위 코드가 있는가.
- 메모리 부족으로 실패할 때 `er_errid ()`와 반환값이 일치하는가.
- `pt_set_default_data_type ()`이 `ENUMERATION`을 처리하지 않는 것이 의도된 동작인가, 아니면 `PT_IS_PARAMETERIZED_TYPE`과의 불일치인가.
