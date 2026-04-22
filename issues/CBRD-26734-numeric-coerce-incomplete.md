# [NUMERIC] CBRD-26652 불완전 수정 — 비교/IN/BETWEEN/JOIN/CASE/COALESCE/HAVING 경로에서 여전히 (15,9) 기본 precision 사용

## Description

### 배경

CBRD-26652 에서 "문자 리터럴 및 비정수형 대상 numeric 자동 형변환 Precision 확장 (15,9 → 38,9)" 이 적용되었다. 릴리즈 노트에 따르면 문자 리터럴이 numeric 으로 자동 형변환될 때 이전의 `(15,9)` 상한(= 6 정수 자릿수)이 `(38,9)` 상한(= 29 정수 자릿수)으로 확장되어야 한다.

그러나 실제로는 **산술 연산 경로(`+`, `-`, `*`, `/`)와 호스트 변수 바인딩 경로(`INSERT VALUES`, `UPDATE SET`) 만** 수정되었고, **predicate / expression 계열 14개 경로는 여전히 `(15,9)` 기본 precision 을 사용** 하여 7자리 이상의 문자 리터럴에서 `"Cannot coerce 'NNNNNNN' to type numeric"` 에러가 발생한다.

### 목적

CBRD-26652 의 수정 범위를 predicate / case / coalesce / IN / BETWEEN / JOIN / EXISTS / HAVING-on-column 경로로 확장하여, 문서화된 `(38,9)` 동작을 전체 코드 경로에서 일관되게 제공한다. 특히 JDBC/ORM 에서 대용량 숫자를 문자열로 바인딩하는 운영 환경에서 **조용한(silent) regression** 이 발생하고 있어 긴급 수정이 필요하다.

---

## Analysis

### Reproduction

```sql
CREATE TABLE tnum(v NUMERIC(38,9));
INSERT INTO tnum VALUES (1.0);

-- 산술 경로: (38,9) 로 올바르게 동작 (CBRD-26652 에서 수정된 경로)
SELECT v + '9999999'  FROM tnum;   -- OK
SELECT v + '99999999' FROM tnum;   -- OK (8자리)
SELECT v + '9999999999999999999999999999' FROM tnum;  -- OK (28자리)

-- 비교 경로: 여전히 (15,9) 사용 → 7자리에서 실패
SELECT COUNT(*) FROM tnum WHERE v > '999999';    -- OK (6자리)
SELECT COUNT(*) FROM tnum WHERE v > '9999999';   -- ERROR: Cannot coerce '9999999' to type numeric
SELECT COUNT(*) FROM tnum WHERE v = '9999999';   -- ERROR
SELECT COUNT(*) FROM tnum WHERE v IN ('9999999');       -- ERROR
SELECT COUNT(*) FROM tnum WHERE v BETWEEN '1' AND '9999999';  -- ERROR
```

### 재현되는 Context 14종

각 context 에서 정수 자릿수 임계는 **6** 이며 (CBRD-26652 fix 이전과 동일), 7자리부터 `Cannot coerce` 에러가 발생한다. 기대 임계는 **29** (= 38 − 9).

| Context | 예시 | 현재 임계 | 기대 임계 |
|---|---|---|---|
| `>`, `>=`, `<`, `<=` | `WHERE v > '9999999'` | 6 | 29 |
| `=`, `!=`, `<=>` (null-safe) | `WHERE v = '9999999'` | 6 | 29 |
| `IN (literal, ...)` | `WHERE v IN ('9999999')` | 6 | 29 |
| `NOT IN (literal, ...)` | `WHERE v NOT IN ('9999999')` | 6 | 29 |
| `BETWEEN 'a' AND 'b'` | `WHERE v BETWEEN '1' AND '9999999'` | 6 | 29 |
| `NOT BETWEEN` | `WHERE v NOT BETWEEN '1' AND '9999999'` | 6 | 29 |
| `JOIN … ON / WHERE a.v = 'lit'` | `a,b WHERE a.v=b.v AND a.v='9999999'` | 6 | 29 |
| `CASE WHEN v='lit'` (predicate) | `WHERE (CASE WHEN v='9999999' THEN 1 END)=1` | 6 | 29 |
| `CASE WHEN v='lit'` (SELECT list) | `SELECT CASE WHEN v='9999999' THEN 1 END FROM tnum` | 6 | 29 |
| `COALESCE(v, 'lit')` | `SELECT COALESCE(v,'9999999') FROM tnum` | 6 | 29 |
| `NVL(v, 'lit')` | `SELECT NVL(v,'9999999') FROM tnum` | 6 | 29 |
| `IFNULL(v, 'lit')` | `SELECT IFNULL(v,'9999999') FROM tnum` | 6 | 29 |
| `EXISTS` with `b.v='lit' AND b.v=a.v` | correlated EXISTS | 6 | 29 |
| `GROUP BY v HAVING v='lit'` | `GROUP BY v HAVING v='9999999'` | 6 | 29 |

### 영향받지 않는 Context (정상: 29자리까지 통과, 30자리에서 overflow)

| Context | 예시 | 임계 |
|---|---|---|
| Arithmetic | `SELECT v + '9999…9' FROM tnum` | 29 (CBRD-26652 에서 수정됨) |
| `INSERT INTO tnum VALUES ('lit')` | host-value bind | 29 |
| `UPDATE tnum SET v='lit'` | host-value bind | 29 |
| Session variable | `SET @s='9999999'; WHERE v > @s` | 29 |
| `HAVING MAX(v) > 'lit'` | aggregate-result 경로 | 29 |
| `v = (SELECT 'lit')` | scalar subquery | 29 |
| `v IN (SELECT 'lit')` | IN-subquery | 29 |
| `UNION` / `EXCEPT` / `INTERSECT` | reconciliation | 29 |
| Explicit `CAST('lit' AS NUMERIC(38,9))` | 사용자 workaround | 29 |

### Decisive Evidence — Root cause

`NUMERIC(15,9)` 컬럼과 `NUMERIC(38,9)` 컬럼에서 **동일하게 6자리 임계** 를 확인. 이는 failing 경로가 컬럼의 선언된 precision 을 무시하고 전역 상수 `DB_DEFAULT_NUMERIC_PRECISION = 15` 를 사용한다는 결정적 증거이다.

```sql
CREATE TABLE t15(v NUMERIC(15,9));   -- 선언된 precision 15
CREATE TABLE t38(v NUMERIC(38,9));   -- 선언된 precision 38
-- 두 경우 모두 WHERE v > '9999999' → Cannot coerce (동일 에러)
```

### 참고 코드 (15 기본값 사용 지점)

| 파일 | 라인 | 역할 |
|---|---|---|
| `src/compat/dbtype_def.h` | 576 | `#define DB_DEFAULT_NUMERIC_PRECISION 15` |
| `src/object/object_domain.c` | 308 | 전역 `tp_Numeric_domain` 을 `DB_DEFAULT_NUMERIC_PRECISION` / `DB_DEFAULT_NUMERIC_SCALE` 로 구성 |
| `src/parser/type_checking.c` | 11294, 11341 | predicate-coercion 분기에서 `arg1_prec` / `arg2_prec` 이 `data_type` 부재 시 `DB_DEFAULT_NUMERIC_PRECISION` 으로 fallback |
| `src/parser/xasl_generation.c` | 7490 | XASL 생성이 `DB_DEFAULT_NUMERIC_PRECISION` 을 scale 로 사용 |
| `src/parser/parse_dbi.c` | 1594 | `tp_domain_construct(…, DB_DEFAULT_NUMERIC_PRECISION, DB_DEFAULT_NUMERIC_SCALE, NULL)` |
| `src/query/string_opfunc.c` | 15810, 16020 | string → numeric 경로도 15 default 사용 |

CBRD-26652 의 수정은 arithmetic result promotion 만 `(38,9)` 로 올렸고(올바름), predicate 계열 coercion 은 여전히 전역 `tp_Numeric_domain` / `DB_DEFAULT_NUMERIC_PRECISION` 을 경유한다.

### Impact

- JDBC `PreparedStatement.setString(idx, largeNumber.toString())` 또는 ORM(Hibernate 등)이 큰 수를 문자열로 바인딩 시, **7자리 이상에서 모든 predicate 가 하드 에러**
- 고객 관점에서 11.4.5 로 업그레이드 후 **조용한 regression** — 이전 11.4.x 대비 실패율이 증가
- Workaround 는 존재하나 매우 번거로움: `CAST('lit' AS NUMERIC(38,9))` 를 모든 predicate 에 수동 삽입

### 재현 스크립트

`/tmp/bugbounty11455/numeric_coerce/` (14개 context 별 독립 파일)

---

## Implementation

### 수정 방향

Predicate / expression coercion 경로에서 `DB_DEFAULT_NUMERIC_PRECISION` fallback 을 사용하는 대신, **대응하는 컬럼/인수의 선언된 precision** 을 사용하도록 변경.

### 주 수정 대상

| 파일 | 변경 내용 |
|---|---|
| `src/parser/type_checking.c:11294,11341` | `arg1_prec` / `arg2_prec` 이 `data_type` 부재 시 `DB_DEFAULT_NUMERIC_PRECISION` 으로 fallback 하는 로직을, 상대 인자의 domain precision 을 참조하도록 변경 (산술 경로와 동일한 방식) |
| `src/query/string_opfunc.c:15810,16020` | string → numeric 변환 경로에서 기본 15 대신 target domain 을 전달 |
| `src/parser/xasl_generation.c:7490` | predicate 계산용 XASL 생성 시 target 의 precision 을 사용 |

### 수정 원칙

산술 경로(CBRD-26652 에서 올바르게 수정됨)는 이미 target domain 의 precision 을 사용한다. 동일한 방식을 predicate / case / coalesce 경로에 확장 적용한다. 즉 "target domain 이 결정 가능하면 그것을, 불가능하면 `(38,9)` 로" 라는 규칙을 모든 문자-리터럴 → numeric 자동 형변환 경로에 일관되게 적용.

---

## A/C (Acceptance Criteria)

- [ ] 아래 14개 context 전부에서 `NUMERIC(38,9)` 컬럼 대비 7~29 정수 자리의 문자 리터럴이 에러 없이 동작
  - [ ] `>`, `>=`, `<`, `<=`, `=`, `!=`, `<=>`
  - [ ] `IN (literal, ...)`, `NOT IN (literal, ...)`
  - [ ] `BETWEEN 'a' AND 'b'`, `NOT BETWEEN`
  - [ ] `JOIN … ON / WHERE a.v = 'lit'`
  - [ ] `CASE WHEN v='lit'` (predicate / SELECT list)
  - [ ] `COALESCE(v,'lit')`, `NVL(v,'lit')`, `IFNULL(v,'lit')`
  - [ ] correlated `EXISTS` with `b.v='lit'`
  - [ ] `GROUP BY v HAVING v='lit'`
- [ ] 30자리 이상의 문자 리터럴은 깔끔한 `Data overflow` 에러로 거부됨 (현재 산술 경로와 동일)
- [ ] 산술 / INSERT / UPDATE / CAST / session var / subquery 경로는 regression 없음 (29자리 유지)
- [ ] `NUMERIC(15,9)` 컬럼은 기존과 동일하게 (15,9) 제한 유지 — 컬럼 자체의 precision 이 존중되는지 검증

---

## Remarks

- CBRD-26652 의 incomplete fix 로 링크 필요
- 11.4.5 internal test 에서 발견됨 (FINDINGS_11.4.5.md BUG 1)
- 재현 스크립트: `/tmp/bugbounty11455/numeric_coerce/`
- JDBC / ORM 대량 regression 가능성으로 **Priority: Major** 또는 **Blocker** 권장
