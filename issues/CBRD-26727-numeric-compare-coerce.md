# [NUMERIC] 비교 연산자에서 문자 리터럴 → NUMERIC 자동 형변환 precision 확장(15→38) 미적용

## Description

### 배경

CBRD-26652 에서 문자 리터럴과 비정수형 값을 `NUMERIC` 으로 auto-cast 할 때의 default precision 을 `DB_DEFAULT_NUMERIC_PRECISION`(15) → `DB_MAX_NUMERIC_PRECISION`(38) 로 확장하였다. 이 수정은 `src/parser/type_checking.c` 의 `pt_coerce_expression_argument()` 에 적용되었다(11.4.5 backport 커밋 `f3a600d87`).

그러나 11.4.5 빌드(testdb, debug_clang)로 재확인한 결과, **비교 연산자 경로**(`col > 'literal'`, `col = 'literal'` 등)에서는 여전히 기존 15 precision 기반 동작이 유지되고 있다. 동일한 문자 리터럴을 **산술 연산자 경로**(`col + 'literal'`)에 사용하면 정상적으로 38 precision 으로 cast 되어 동작한다.

즉, CBRD-26652 의 수정이 **산술 경로에만 적용되고 비교 경로에는 누락** 되어 있어, 고객이 기대하는 "15,9 → 38,9 precision 확장" 의 일관된 효과가 나지 않는다.

### 목적

- 비교 경로에서도 문자 리터럴 → NUMERIC auto-cast 시 precision 을 `DB_MAX_NUMERIC_PRECISION`(38) 으로 확장하여, 6자리 이상의 정수부를 가진 문자 리터럴을 `NUMERIC(38, 9)` 컬럼과 문제 없이 비교할 수 있도록 한다.
- CBRD-26652 의 fix intent 를 비교 연산자 경로까지 완결한다.

---

## Analysis

### 재현 환경

- 브랜치: `bug-bounty-11.4.5` (HEAD: `3df9de02b`)
- 빌드: `just build` (debug_clang preset)
- 서버: `cubrid server start testdb`
- 클라이언트: `csql -udba testdb`

### 재현 스크립트

```sql
DROP TABLE IF EXISTS tnum;
CREATE TABLE tnum(v NUMERIC(38,9));
INSERT INTO tnum VALUES (1.0);

-- 비교 경로: 정수부 6자리까지는 성공, 7자리부터 실패
SELECT COUNT(*) FROM tnum WHERE v > '1';              -- OK
SELECT COUNT(*) FROM tnum WHERE v > '999999';         -- OK  (정수부 6자리)
SELECT COUNT(*) FROM tnum WHERE v > '9999999';        -- ERROR: Cannot coerce '9999999' to type numeric.
SELECT COUNT(*) FROM tnum WHERE v > '9999999.5';      -- ERROR
SELECT COUNT(*) FROM tnum WHERE v > '99999999999999999';   -- ERROR (17자리)

-- 산술 경로: 동일한 문자 리터럴로 정상 동작
SELECT v + '9999999'  FROM tnum;   -- OK → 1.0e+07
SELECT v + '99999999' FROM tnum;   -- OK → 1.0e+08

-- 정수/실수 리터럴은 비교에서도 정상 동작 (참고: 문자 리터럴만 문제)
SELECT COUNT(*) FROM tnum WHERE v > 9999999;          -- OK
SELECT COUNT(*) FROM tnum WHERE v > 9999999.5;        -- OK
```

### 관찰된 경계값

| 리터럴 형태 | 예시 | 비교 경로 (`v > ...`) | 산술 경로 (`v + ...`) |
|---|---|---|---|
| 문자 리터럴, 정수부 6자리 | `'999999'` | OK | OK |
| 문자 리터럴, 정수부 7자리 | `'9999999'` | **ERROR** | OK |
| 문자 리터럴, 정수부 7자리 + 소수 | `'9999999.5'` | **ERROR** | OK |
| 문자 리터럴, 정수부 17자리 | `'99999999999999999'` | **ERROR** | OK |
| 정수 리터럴 | `9999999` | OK | OK |
| 실수 리터럴 | `9999999.5` | OK | OK |

경계값이 정확히 **정수부 6자리** 에서 끊긴다는 것은 비교 경로가 여전히 `NUMERIC(15, 9)`(전체 15, 소수 9 → 정수부 최대 6)을 중간 도메인으로 사용함을 강하게 시사한다. 이는 CBRD-26652 가 해결하고자 한 "default precision = 15" 문제 그대로이다.

### 기존 수정의 범위

CBRD-26652 (11.4.5 backport, `f3a600d87`) 에서 변경된 한 줄:

```diff
--- a/src/parser/type_checking.c
+++ b/src/parser/type_checking.c
@@ -4815,7 +4815,7 @@ pt_coerce_expression_argument (PARSER_CONTEXT * parser, PT_NODE * expr, PT_NODE
 
        default:
-         precision = DB_DEFAULT_NUMERIC_PRECISION;
+         precision = DB_MAX_NUMERIC_PRECISION;
          scale = DB_DEFAULT_NUMERIC_DIVISION_SCALE;
          break;
        }
```

`pt_coerce_expression_argument()` 는 `pt_eval_expr_type()` 과 `pt_eval_between()` 경로에서 **PT_PLUS/PT_MINUS/PT_TIMES/…/PT_BETWEEN** 등 여러 연산자의 인자를 coerce 할 때 사용된다. 그러나 일반 **비교 연산자**(`PT_GT`, `PT_GE`, `PT_LT`, `PT_LE`, `PT_EQ`, `PT_NE`)의 문자 리터럴 처리는 이 함수를 거치지 않거나, 거치더라도 별도 경로(예: `pt_wrap_with_cast_op`, 런타임 `tp_value_coerce`)에서 domain 을 재결정하면서 default `(15, 9)` 가 재사용될 가능성이 있다.

### 의심 지점

- `src/parser/type_checking.c`
  - `pt_coerce_expression_argument()` 내부 `default` 분기: CBRD-26652 에서 수정된 위치. 비교 연산자 경로가 이 함수를 호출하는지 확인 필요.
  - `pt_wrap_with_cast_op()`: wrap-cast 시 domain 의 precision 지정 부분.
  - `pt_character_to_numeric_coercion()` 혹은 유사한 helper 에서 string → numeric 기본 precision 을 `DB_DEFAULT_NUMERIC_PRECISION` 으로 하드코딩한 곳이 있는지 grep 필요.
- `src/query/numeric_opfunc.c`, `src/base/numeric.c`: 런타임 cast 시 target domain 이 좁게 잡혀 오는지 확인.
- `src/compat/db_value_printer.cpp` / `tp_value_coerce()`: 비교 전에 값 레벨 cast 가 수행될 때의 target domain.

---

## Impact

- `NUMERIC(38, 9)` 같은 **큰 precision 컬럼** 을 사용하는 고객이 문자 리터럴로 비교 predicate 를 작성하면, 값 크기가 작더라도(7자리 이상) 런타임 에러를 받는다.
- JDBC `PreparedStatement` 로 `BigDecimal` 을 바인딩하지 않고 문자열로 바인딩하는 애플리케이션, 또는 ORM 이 큰 숫자를 string 으로 내보내는 경우가 직격탄.
- CBRD-26652 가 "해결 완료" 로 내부 공지된 상태에서 일부 경로만 동작하므로 고객 혼선 및 QA 신뢰도 저하 우려.

---

## Acceptance Criteria

- [ ] `SELECT COUNT(*) FROM tnum WHERE v > '9999999';` 이 ERROR 없이 성공한다 (`v NUMERIC(38, 9)` 기준).
- [ ] `SELECT COUNT(*) FROM tnum WHERE v > '99999999999999999';` (17자리) 도 성공한다.
- [ ] `SELECT COUNT(*) FROM tnum WHERE v > '9999999.5';` 도 성공한다.
- [ ] 산술 경로(`v + '…'`) 의 기존 동작은 회귀 없이 유지된다.
- [ ] 정수/실수 리터럴 비교 경로의 기존 동작도 회귀 없이 유지된다.
- [ ] 위 시나리오를 커버하는 SQL 회귀 테스트(`tests/sql/_issues/...`)가 추가된다.

---

## Remarks

- 원래 수정: CBRD-26652, 11.4.5 backport 커밋 `f3a600d87` (`src/parser/type_checking.c` 한 줄 변경).
- 같은 세션의 view-merge 힌트 처리 관련 동작 이슈(`/*+ ORDERED */`, 외부 `LEADING` 과 내부 `LEADING` 충돌)는 별도 JIRA 로 추적 예정.
- 재현 스크립트: `/tmp/bugbounty11455/fu_26652_strict.sql`, `/tmp/bugbounty11455/out_fu_26652_strict.txt` 에 원본 결과 포함.
