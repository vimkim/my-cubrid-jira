# [CBRD-26979] 고정 길이 컬럼의 OOS STORAGE 옵션 지정 거부

## Issue Triage

**이슈 수행 목적**: `OOS` (Out-of-row Overflow Storage) 컬럼 정책을 실제 CLASS의 variable-layout normal
attribute에만 명시할 수 있도록 한다. CBRD-26979에서는 fixed-layout 타입의 네 가지 명시적 `STORAGE`
옵션을 모두 거부한다.

**이슈 수행 이유**:

| 구분 | 동작 및 영향 |
|---|---|
| **AS-IS (기준 브랜치)** | 고정 길이 `INT`에도 `PREFER_INLINE`, `PREFER_OUTLINE`, `DEFAULT`가 허용되고 `FORCE_OUTLINE`만 실패한다. 무효한 OOS 방향 정책이 schema와 `SHOW CREATE TABLE`에 남을 수 있다. |
| **TO-BE (CBRD-26979)** | fixed-layout normal attribute의 `PREFER_INLINE`, `PREFER_OUTLINE`, `FORCE_OUTLINE`, `DEFAULT`를 모두 semantic error로 거부한다. CLASS/SHARED/VCLASS attribute의 명시적 `STORAGE`도 계속 거부한다. |
| **후속 동작** | fixed-layout normal attribute에서 `DEFAULT`를 타입 기본값으로 허용하고 `FORCE_INLINE`을 추가하는 정책은 CBRD-27259에서 처리한다. |
| **영향** | 설계 의도 훼손 방지 - 현재는 적용할 수 없는 OOS 정책이 성공하거나, 같은 부적격 attribute가 DDL 경로에 따라 서로 다른 이유의 error를 반환할 수 있다. |

**이슈 수행 방안**: CREATE/ADD/MODIFY/CHANGE가 같은 적격성 helper를 사용하도록 한다. CBRD-26979에서는
fixed-layout 타입에 명시한 네 옵션을 모두 거부하며, `STORAGE` 절을 생략한 호환 가능한 ALTER는 기존 정책을
정리한 뒤 성공시킨다. `ALTER ... MODIFY CLASS ATTRIBUTE`는 타입이 아니라 attribute kind 때문에 실패하므로
전용 메시지 339를 반환하고, 테스트도 메시지 339와 340을 구분해 검증한다. `DEFAULT` 예외, parse-tree enum
분리, `attr_storage` 확장 및 `FORCE_INLINE`은 [CBRD-27259](http://jira.cubrid.org/browse/CBRD-27259) 범위다.

---

## AI-Generated Context

> 아래는 AI가 CUBRID 소스, PostgreSQL 18.6 공식 소스와 문서, 실제 PostgreSQL 18.6 실행 결과 및 PR 리뷰를
> 분석해 작성한 상세 자료다. 빠른 triage에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현과 리뷰
> 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: CBRD-26979는 parser 및 schema 실행부의 attribute 적격성 검사, semantic error 선택,
  OOS STORAGE SQL 테스트를 다룬다. CBRD-27259의 grammar, schema flag, heap 배치 및 overflow 계약은 이
  티켓에서 구현하지 않는다.

## Description

OOS의 컬럼별 정책은 현재 `STORAGE PREFER_INLINE`, `FORCE_OUTLINE`, `PREFER_OUTLINE`, `DEFAULT` 문법으로
지정한다. 기준 브랜치에서는 옵션마다 검사가 달라 `FORCE_OUTLINE`만 fixed-layout 타입에서 실패했다.
CBRD-26979 구현은 네 spelling을 공통 helper로 검사하여 이 비대칭을 제거하고, fixed-layout 타입에서는
모두 거부한다.

```text
STORAGE 절 생략
  -> 성공

실제 CLASS의 normal attribute
  + variable layout
    -> 현재의 네 STORAGE clause 성공
  + fixed layout
    -> CBRD-26979: 네 clause 모두 실패
    -> CBRD-27259: DEFAULT 예외와 FORCE_INLINE 정책을 후속 처리

CLASS attribute / SHARED attribute / VCLASS attribute
  + 명시적 STORAGE clause
    -> 타입과 관계없이 실패
```

물리 분류는 SQL 타입 이름의 인상이 아니라 `pr_is_variable_type(TP_DOMAIN_TYPE(domain))`으로 결정한다.
예를 들어 CUBRID `CHAR`는 물리적으로 가변이므로 적격하지만, `BIT(n)`은 fixed layout이므로 CBRD-26979의
거부 규칙을 적용한다.

## Review Feedback

### 1. Fixed 타입의 STORAGE DEFAULT

`@lht1199` 임형태님은 inline/outline 방향을 지정하는 옵션이 fixed type에서 실패하는 것은 이해할 수
있지만, 일반적인 표현인 `STORAGE DEFAULT`까지 실패하면 사용자에게 혼란스럽다는 의견을 주셨다.
PostgreSQL 비교도 이 우려를 뒷받침한다.

다만 이 동작은 PR #7611의 merge 조건이 아니다. [PR 답변](https://github.com/CUBRID/cubrid/pull/7611#issuecomment-5325413832)에
따라 fixed 타입의 `DEFAULT` 허용과 `FORCE_INLINE` 정책은 CBRD-27259에서 구현한다. 따라서 현재 PR에서
`DEFAULT`가 error 340으로 실패하는 것은 CBRD-26979의 의도된 중간 상태다.

### 2. CLASS ATTRIBUTE의 error 선택

다음 ALTER는 `ca`가 variable type임에도 generic error 340을 반환한다.

```sql
CREATE TABLE tc (a INT, CLASS ca VARCHAR(100));
ALTER TABLE tc MODIFY CLASS ATTRIBUTE ca VARCHAR(4096) STORAGE PREFER_INLINE;
```

실패 원인은 variable/fixed 분류가 아니라 CLASS attribute라는 점이다. `csql_grammar.y`의
`alter_modify_clause_for_alter_list`는 `attr_def_one`을 처리한 뒤 `attr_type`을 `PT_META_ATTR`로 바꾼다.
그 결과 `attr_def_one` 안의 CLASS/SHARED STORAGE 검사와 전용 error 339가 실행되지 않고, 뒤의
`do_validate_oos_storage_setting()`이 generic error 340을 반환한다.

이 항목은 CBRD-26979에서 처리한다. parser 또는 공통 validator가 object kind를 정확히 분류해 error 339를
선택해야 하며, 어느 한 경로가 우연히 대신 거부하는 상태에 의존하면 안 된다.

현재 `expect_storage_attribute_error()`는 메시지 339와 340을 `||`로 허용한다. 이 helper를 그대로 쓰면
적격성 검사를 지우거나 잘못된 error 경로를 타도 일부 테스트가 통과할 수 있다. failure dimension마다
기대 메시지를 인자로 받도록 바꾸고, 위 ALTER를 독립 회귀 테스트로 추가해야 한다.

## PostgreSQL Comparison

이 비교는 CBRD-27259의 후속 정책 근거이며 CBRD-26979의 현재 PR 수락 조건은 아니다.

| PostgreSQL 컬럼 | STORAGE clause | 결과 | 최종 `attstorage` |
|---|---|---|---|
| `integer` | `PLAIN` | 성공 | `p` |
| `integer` | `DEFAULT` | 성공 | `p` |
| `integer` | `MAIN` | SQLSTATE `0A000` 실패 | 변경 없음 |
| `integer` | `EXTERNAL` | SQLSTATE `0A000` 실패 | 변경 없음 |
| `integer` | `EXTENDED` | SQLSTATE `0A000` 실패 | 변경 없음 |
| `char(10)` / `bpchar` | 다섯 모드 | 모두 성공 | 요청 모드, `DEFAULT`는 `x` |

PostgreSQL은 `DEFAULT`를 해당 타입의 `typstorage`로 먼저 해석한다. fixed-length `integer`는 `PLAIN`이
기본값이므로 `DEFAULT`를 허용하지만 `MAIN`/`EXTERNAL`/`EXTENDED`는 거부한다. 반면 `bpchar`는
`typlen=-1`, `typstorage=x`인 varlena라 다섯 모드를 모두 허용한다.

공식 근거:

- [PostgreSQL 18 ALTER TABLE - SET STORAGE](https://www.postgresql.org/docs/18/sql-altertable.html#SQL-ALTERTABLE-DESC-SET-STORAGE)
- [PostgreSQL 18 TOAST storage](https://www.postgresql.org/docs/18/storage-toast.html)
- [PostgreSQL REL_18_6 `GetAttributeStorage()`](https://github.com/postgres/postgres/blob/724edf9bde9d356724ad384a2e196edc3c9f80f7/src/backend/commands/tablecmds.c)
- [상세 비교 및 실행 기록](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-26979/CBRD-26979-storage-variable-type-validation_882f70f_codex.md)

## Follow-up Scope

CBRD-27259는 다음 정책과 구현을 함께 다룬다.

- fixed-layout normal attribute의 `STORAGE DEFAULT`를 타입 기본값으로 허용한다.
- `PT_ATTR_STORAGE_DEFAULT`와 `PT_ATTR_STORAGE_PREFER_OUTLINE`을 분리하고 `attr_storage`를 3비트로 넓힌다.
- `FORCE_INLINE`을 "해당 attribute value를 OOS inline stub으로 바꾸지 않음"으로 정의한다.
- fixed 타입의 효과상 `FORCE_INLINE` 기본값은 flag로 저장하거나 `SHOW CREATE TABLE`에 자동 출력하지 않는다.
- variable 타입의 explicit `FORCE_INLINE`만 schema override로 저장한다.
- non-OOS `REC_BIGONE`은 허용하고 mixed OOS+bigone은 기존 규칙대로 거부한다.

## Implementation

### CBRD-26979 범위

- `do_add_attribute()`와 `build_attr_change_map()`이 같은 `do_validate_oos_storage_setting()` 적격성 규칙을
  사용한다.
- fixed-layout normal attribute의 네 explicit clause는 모두 error 340으로 거부한다.
- CLASS/SHARED attribute는 물리 타입과 관계없이 error 339로 거부한다.
- VCLASS attribute의 explicit STORAGE는 행별 OOS 정책 대상이 아니므로 semantic error로 거부한다.
- omitted `STORAGE`로 variable 타입을 fixed 타입으로 바꾸면 기존 `PREFER_INLINE`/`FORCE_OUTLINE` flag를
  제거한다.
- 테스트 helper는 error 339와 340을 구분하고 `ALTER ... MODIFY CLASS ATTRIBUTE` 경로를 직접 검증한다.

### CBRD-27259 범위

- `DEFAULT`/`PREFER_OUTLINE` enum 분리 및 `attr_storage:2`의 3비트 확장
- fixed-layout normal attribute의 explicit `DEFAULT` 허용과 기존 override reset
- `FORCE_INLINE` grammar, schema flag, ALTER 전환 및 canonical DDL
- heap 후보 제외, `REC_BIGONE` 계약, recovery/replication 및 unload/load/LIKE 회귀 테스트

## Test Build

- 검토 대상: PR #7611 head `c47b70596b8e564f203497f0a2f381697fc56f74`
- 이 문서 수정에서는 CUBRID engine code를 변경하거나 build/test를 다시 실행하지 않았다.

## Repro

```sql
-- CBRD-26979: 네 문장 모두 실패해야 한다.
CREATE TABLE t_fixed_default (c INT STORAGE DEFAULT);
CREATE TABLE t_fixed_prefer_inline (c INT STORAGE PREFER_INLINE);
CREATE TABLE t_fixed_prefer_outline (c INT STORAGE PREFER_OUTLINE);
CREATE TABLE t_fixed_force_outline (c INT STORAGE FORCE_OUTLINE);

-- CBRD-26979 review item 2: 전용 error 339로 실패해야 한다.
CREATE TABLE tc (a INT, CLASS ca VARCHAR(100));
ALTER TABLE tc MODIFY CLASS ATTRIBUTE ca VARCHAR(4096) STORAGE PREFER_INLINE;

-- object-kind 회귀: 실패해야 한다.
CREATE VCLASS v_storage_default (c VARCHAR(4096) STORAGE DEFAULT);
```

## Expected Result

CBRD-26979에서는 fixed `INT`의 네 explicit STORAGE 문장이 모두 error 340으로 실패한다. CLASS attribute
ALTER는 전용 error 339로 실패해야 한다. CBRD-27259가 반영된 뒤에는 fixed normal attribute의
`STORAGE DEFAULT`만 성공하도록 기대 결과를 갱신한다.

## Actual Result

PR #7611 head `c47b70596b8e564f203497f0a2f381697fc56f74`는 fixed 타입의 네 문장을 모두 error 340으로
거부한다. fixed 타입 범위는 CBRD-26979의 현재 계약과 일치한다.

`ALTER ... MODIFY CLASS ATTRIBUTE`도 실패하지만 전용 error 339 대신 generic error 340을 반환한다.
따라서 review item 2의 parser/error-routing 수정과 정확한 메시지 회귀 테스트가 남아 있다.

## Additional Information

- JIRA: http://jira.cubrid.org/browse/CBRD-26979
- 후속 JIRA: http://jira.cubrid.org/browse/CBRD-27259
- 상위 이슈: https://jira.cubrid.org/browse/CBRD-26583
- PR: https://github.com/CUBRID/cubrid/pull/7611
- review: https://github.com/CUBRID/cubrid/pull/7611#pullrequestreview-4958687037
- scope 답변: https://github.com/CUBRID/cubrid/pull/7611#issuecomment-5325413832
- 현재 구현 commit: `c47b70596b8e564f203497f0a2f381697fc56f74`
- 핵심 코드: `src/parser/csql_grammar.y`, `src/parser/parse_tree.h`, `src/query/execute_schema.c`,
  `unit_tests/oos/sql/test_oos_sql_storage.cpp`
