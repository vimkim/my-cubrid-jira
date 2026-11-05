# [OOS] parse tree printer가 컬럼 정의의 STORAGE DEFAULT와 PREFER_OUTLINE을 출력하지 않는 문제

**한 줄 요약**: CBRD-27259(`STORAGE FORCE_INLINE`) 구현 중 발견한 결함이다. parse tree printer `pt_print_attr_def` 가 명시적 `STORAGE DEFAULT` 와 `STORAGE PREFER_OUTLINE` 을 출력하지 않아, 출력한 문장에서는 이 절을 생략한 문장과 구분할 수 없다. 이 이슈는 printer의 출력이 원래 문장의 의미를 보존하도록 고친다.

## Issue Triage

**이슈 수행 목적**: `pt_print_attr_def` 가 출력한 컬럼 정의를 다시 파싱했을 때, 사용자가 쓴 `STORAGE` 정책과 같은 값이 나와야 한다.

**이슈 수행 이유**: OOS의 `STORAGE` 절은 "생략"과 "명시적 `DEFAULT`"의 의미가 다르다. ALTER MODIFY/CHANGE에서 생략하면 기존 정책을 유지하고, `DEFAULT` 를 명시하면 정책을 해제한다. 그런데 printer는 `DEFAULT` 를 출력하지 않으므로, 출력된 문장에서는 정책 해제가 정책 유지로 바뀐다. CBRD-27259 이후에는 고정 길이 컬럼에서 `PREFER_OUTLINE` 은 거부하고 `DEFAULT` 는 허용하므로, 출력에서 `PREFER_OUTLINE` 이 빠지면 거부되어야 할 문장이 허용되는 문장으로 바뀐다.

**영향**: 이번 조사에서는 이 출력을 다시 실행하거나 복제에 쓰는 소비 경로를 찾지 못했다. HA 복제와 CDC는 사용자가 입력한 원문(`sql_user_text`)을 쓰고, `SHOW CREATE TABLE` 과 unloaddb는 스키마에 저장된 flag로 DDL을 만든다. 따라서 현재 확인된 영향은 printer 출력을 읽는 사람이 잘못된 정보를 얻을 수 있다는 것뿐이다. 데이터나 스키마가 잘못 바뀐 사례는 확인되지 않았다. 다만 앞으로 이 printer의 출력을 다시 실행하는 경로가 생기면 정책이 조용히 바뀔 수 있다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

### 배경: STORAGE 절과 parse tree printer

OOS(Out-of-row Overflow Storage)는 큰 가변 길이 컬럼 값을 행 밖의 별도 파일에 저장하는 기능이다. 사용자는 컬럼 정의에 `STORAGE` 절을 붙여 컬럼별 저장 정책을 지정한다. parser는 이 절을 컬럼 정의 노드(`PT_ATTR_DEF`)의 `attr_storage` 값으로 기록한다. 절을 생략하면 `PT_ATTR_STORAGE_UNSET` 이 된다.

parse tree printer(`parser_print_tree`, `pt_print_bytes` 계열)는 파싱한 트리를 다시 SQL 문자열로 바꾼다. 컬럼 정의 노드는 `pt_print_attr_def` 가 출력한다. printer의 출력을 다시 파싱했을 때 같은 의미가 나오는 것이 일반적인 기대다.

### 무엇이 문제인가

두 revision에서 printer의 동작은 다음과 같다. 소스를 읽어 확인했고, 빌드나 실행으로 재현하지는 않았다.

| 항목 | 기준 revision `d52b1889e` (`feature/oos-merge`) | CBRD-27259 commit `e19d8c613` |
|---|---|---|
| `STORAGE` 값의 정의 | `PT_ATTR_STORAGE_PREFER_OUTLINE` 은 `PT_ATTR_STORAGE_DEFAULT` 의 별칭이다 (`src/parser/parse_tree.h:1962-1969`). | `PT_ATTR_STORAGE_DEFAULT` 와 `PT_ATTR_STORAGE_PREFER_OUTLINE` 이 서로 다른 값이다. `FORCE_INLINE` 이 추가되었다 (`src/parser/parse_tree.h:1962-1970`). |
| `pt_print_attr_def` 출력 | `prefer_inline` 과 `force_outline` 만 출력한다 (`src/parser/parse_tree_cl.c:7270-7277`). | `prefer_inline`, `force_outline`, `force_inline` 을 출력한다 (`src/parser/parse_tree_cl.c:7270-7281`). |
| 출력하지 않는 값 | `DEFAULT` (= `PREFER_OUTLINE`) | `DEFAULT`, `PREFER_OUTLINE` |

출력하지 않는 값은 절을 생략한 문장(`UNSET`)과 출력 결과가 같다. 그러나 두 값의 의미는 생략과 다르다.

1. **ALTER에서 정책 해제가 정책 유지로 바뀐다.** CBRD-27259 commit의 `build_attr_change_map` 은 절을 생략한 경우에만 기존 정책을 유지한다 (`src/query/execute_schema.c:12644`, `keeps_current_policy`). 예를 들어 `ALTER TABLE t MODIFY c VARCHAR(10) STORAGE DEFAULT` 는 `c` 의 기존 `PREFER_INLINE` 정책을 해제한다. 그런데 printer는 이 문장을 `STORAGE` 절이 없는 문장으로 출력하므로, 출력된 문장을 실행하면 `PREFER_INLINE` 이 유지된다. 기준 revision의 ALTER 정책 변경 처리는 이번에 따로 확인하지 않았다.
2. **고정 길이 컬럼에서 거부되어야 할 문장이 허용되는 문장으로 바뀐다.** CBRD-27259 commit에서 고정 길이 컬럼은 `DEFAULT` 와 `FORCE_INLINE` 만 허용하고 `PREFER_OUTLINE` 은 거부한다 (`src/query/execute_schema.c:8242`, `do_resolve_oos_storage_flag`). printer는 `c INT STORAGE PREFER_OUTLINE` 을 절이 없는 `c INT` 로 출력하므로, 출력된 문장은 오류 없이 실행된다.

같은 printer에서 `INVISIBLE` 도 `PT_ATTR_INVISIBLE` 만 출력하고 명시적 `VISIBLE` 은 출력하지 않는다 (`src/parser/parse_tree_cl.c:7265`, 기준 revision). `STORAGE` 와 같은 형태의 누락이다. 이 이슈의 범위에 포함할지는 ANALYSIS에서 정한다.

### 출력 결과의 소비 경로 조사

결함의 실제 영향은 printer 출력을 누가 쓰는지에 달려 있다. `e19d8c613` 의 소스에서 컬럼 정의를 포함할 수 있는 출력의 소비 경로를 다음과 같이 확인했다. 확인한 파일은 기준 revision과 내용이 같다.

| 소비 경로 후보 | 확인 결과 |
|---|---|
| HA 복제 (`do_replicate_statement`, `src/query/execute_statement.c:17012`) | 문장 원문 `sql_user_text` 를 복제한다 (17220행). 원문이 없으면 복제를 하지 않고 바로 반환하며, printer로 대신 만들지 않는다 (17029-17033행). printer는 클래스 이름 출력과 `CREATE/ALTER SERVER` 의 비밀번호 숨김(17229행)에만 쓴다. |
| CDC supplemental log (`do_supplemental_statement`, 16394행) | 복제와 같이 원문을 쓰고, 원문이 없으면 바로 반환한다 (16419행). |
| PL/CSQL static SQL (`src/method/method_callback.cpp:574`) | printer 출력을 컴파일된 코드에 넣고 실행 시점에 다시 파싱한다. 그러나 static SQL의 첫 단어는 `WITH`, `SELECT`, `INSERT`, `UPDATE`, `DELETE`, `REPLACE`, `MERGE`, `TRUNCATE` 로 한정되어 DDL이 들어오지 않는다 (`pl_engine/pl_server/src/main/antlr/PlcParser.g4:256-265`). DDL은 dynamic SQL로 실행하며, 이때는 사용자가 준 문자열을 쓴다. |
| trigger action과 condition (`src/parser/compile.c:1172`, `src/object/trigger_description.cpp`) | trigger action에는 DDL이 들어갈 수 없다. |
| `SHOW CREATE TABLE` (`src/object/object_printer.cpp:517-522`) | parse tree가 아니라 스키마에 저장된 속성 flag로 출력한다. |
| unloaddb (`src/executables/unload_schema.c:3086-3095`) | 스키마 flag로 출력한다. printer는 view query, 함수 기반 index 식 같은 부분 트리에만 쓴다. |
| 의미 검사 오류 메시지 (`pt_short_print`) | 컬럼 정의 전체를 출력하는 오류 메시지는 찾지 못했다. `STORAGE` 오류는 컬럼 이름만 출력한다 (`src/query/execute_schema.c:8244-8246`). |
| debug build 로그 (`src/query/execute_statement.c:4695`) | `CUBRID_DEBUG` 빌드에서만 printer 출력을 로그에 남긴다. 사람이 읽는 용도다. |

이 조사는 printer 호출 지점을 `grep` 으로 찾고 각 지점의 입력 노드를 읽어서 진행했다. 모든 호출의 입력을 실행으로 추적하지는 않았다. 정적 조사이므로 간접 호출이나 생성된 코드를 거치는 경로를 놓쳤을 수 있다.

### 분류와 우선순위 제안

| 항목 | 제안 | 근거 |
|---|---|---|
| JIRA 유형 | Sub-task, parent [CBRD-26978](http://jira.cubrid.org/browse/CBRD-26978) | CBRD-27259와 같은 OOS 후속 작업 묶음에 속한다. 문제 성격은 오류 수정(Correct Error)이다. printer 출력이 원래 문장의 의미를 보존한다는 기대와 다르다. |
| 문제 범주 | Correctness (잠재), Maintainability | 현재 확인된 소비 경로에서는 의미가 바뀌지 않는다. 앞으로 printer 출력을 다시 실행하는 경로가 생기면 의미가 바뀐다. |
| 컴포넌트 | parser (`parse_tree_cl.c`) | 수정 범위는 printer 하나로 예상한다. |
| 우선순위 | 낮음 (minor) | 위 조사에서 의미가 바뀌는 소비 경로를 찾지 못했다. |

이 이슈는 CBRD-27259의 결과물(`PT_ATTR_STORAGE_PREFER_OUTLINE` 분리, `FORCE_INLINE` 추가)에 의존한다. CBRD-27259가 병합되기 전에 수정하면 기준 revision에는 없는 enum 값을 다루어야 한다. 따라서 CBRD-27259가 병합된 뒤에 수정한다.

## Test Build

- 기준: `feature/oos-merge` 의 `d52b1889e907abcf84190ec504dde3bc93de260d` (`[CBRD-27860] Fix vacuum latch cycle with heap page allocation (#8350)`)
- 비교: CBRD-27259 branch의 `e19d8c613c581cde2350474fe3451c60ecb04c66` (`[CBRD-27259] Add STORAGE FORCE_INLINE and allow type-default STORAGE on fixed types`). 아직 병합되지 않은 commit이다.
- 두 revision 모두 빌드하지 않고 소스를 읽어서 확인했다.

## Repro

아직 실행하지 않은 재현 방안이다. SQL 문만으로는 printer 출력을 볼 수 없으므로, parser를 직접 호출하는 단위 테스트가 필요하다. OOS SQL 단위 테스트(`unit_tests/oos/sql/test_oos_sql_storage.cpp`)가 후보 위치다.

1. 다음 문장을 각각 `parser_parse_string` 으로 파싱한다.

```sql
CREATE TABLE t1 (c VARCHAR(100) STORAGE DEFAULT);
CREATE TABLE t2 (c VARCHAR(100) STORAGE PREFER_OUTLINE);
CREATE TABLE t3 (c INT STORAGE PREFER_OUTLINE);
ALTER TABLE t4 MODIFY c VARCHAR(100) STORAGE DEFAULT;
```

2. 각 트리를 `parser_print_tree` 로 출력한다.
3. 출력 문자열을 다시 파싱하고, 컬럼 정의 노드의 `attr_storage` 값을 원래 트리의 값과 비교한다.

## Expected Result

출력 문자열에 `STORAGE DEFAULT` 또는 `STORAGE PREFER_OUTLINE` 이 포함된다. 다시 파싱한 트리의 `attr_storage` 가 원래 값과 같다. 절을 생략한 문장은 계속 `STORAGE` 절 없이 출력된다.

## Actual Result

소스 확인에 따른 예상 결과이며, 실행으로 확인하지 않았다. 출력 문자열에 `STORAGE` 절이 없다. 다시 파싱한 트리의 `attr_storage` 는 `PT_ATTR_STORAGE_UNSET` 이다.

## Acceptance Criteria

1. 명시적으로 지정한 모든 `STORAGE` 값(`DEFAULT`, `PREFER_OUTLINE`, `PREFER_INLINE`, `FORCE_OUTLINE`, 그리고 병합된 경우 `FORCE_INLINE`)이 출력과 재파싱 후에 같은 `attr_storage` 값으로 보존된다.
2. `STORAGE` 절을 생략한 컬럼 정의의 출력에는 `STORAGE` 절이 없다.
3. 같은 형태의 누락인 `VISIBLE` 을 이 이슈에서 함께 고칠지 ANALYSIS에서 정하고, 그 결정을 이슈에 기록한다.
4. 출력과 재파싱을 비교하는 단위 테스트가 위 경우를 검증한다.

## Additional Information

- 상위 이슈: [CBRD-26978](http://jira.cubrid.org/browse/CBRD-26978) (OOS TODO epic). 선행 조건: CBRD-27259 병합.
- 관련 이슈: [CBRD-27259](http://jira.cubrid.org/browse/CBRD-27259) (`STORAGE FORCE_INLINE` 지원, 이 결함을 발견한 작업), [CBRD-26979](http://jira.cubrid.org/browse/CBRD-26979) (고정 길이 컬럼의 `STORAGE` 옵션 거부, [PR #7611](https://github.com/CUBRID/cubrid/pull/7611)), [CBRD-26835](http://jira.cubrid.org/browse/CBRD-26835) (OOS develop 병합 준비 epic, [PR #7803](https://github.com/CUBRID/cubrid/pull/7803)에서 `pt_print_attr_def` 의 `STORAGE` 출력 추가).
- 확인하지 못한 것: 실행 재현, 기준 revision의 ALTER 정책 변경 처리, 정적 조사로 찾지 못한 간접 소비 경로.
