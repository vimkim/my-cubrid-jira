# [DDL] `IF EXISTS` 가 TRIGGER / INDEX / USER / PROCEDURE / FUNCTION 에서 syntax error

## Description

### 배경

CUBRID 는 `DROP TABLE / VIEW / SYNONYM / SERIAL` 에서 `IF EXISTS` 구문을 지원하지만, **TRIGGER / INDEX / USER / PROCEDURE / FUNCTION** 에서는 parser 가 `IF` 를 인식하지 못해 syntax error 를 발생시킨다. 이는 **idempotent DDL 스크립트** 작성 시 일관성 문제가 된다.

MySQL / PostgreSQL / Oracle 등 주요 RDBMS 는 위 객체들에 대해 `DROP ... IF EXISTS` 를 지원한다. 마이그레이션 / 배포 자동화 스크립트 (Flyway, Liquibase, dbmate 등) 는 이 구문을 사실상 표준으로 가정한다.

### 목적

- `IF EXISTS` 구문 지원을 TRIGGER / INDEX / USER / PROCEDURE / FUNCTION 까지 확장한다.
- 스크립트 idempotency 및 타 RDBMS 와의 호환성을 개선한다.

---

## Analysis

### 재현 환경

- 브랜치: `bug-bounty-11.4.5` (HEAD `3df9de02b`)
- 클라이언트: `csql -udba testdb`

### 재현 스크립트

```sql
DROP TABLE     IF EXISTS t;            -- OK
DROP VIEW      IF EXISTS v;            -- OK
DROP SYNONYM   IF EXISTS s;            -- OK
DROP SERIAL    IF EXISTS s1;           -- OK

DROP TRIGGER   IF EXISTS t1;           -- ERROR: Syntax error: unexpected 'IF'
DROP INDEX     IF EXISTS i1 ON tbl;    -- ERROR: Syntax error: unexpected 'IF'
DROP USER      IF EXISTS u1;           -- ERROR: Syntax error: unexpected 'IF'
DROP PROCEDURE IF EXISTS p1;           -- ERROR: Syntax error: unexpected 'IF'
DROP FUNCTION  IF EXISTS f1;           -- ERROR: Syntax error: unexpected 'IF'
```

### 관찰된 지원 매트릭스

| DDL | `IF EXISTS` 지원 | 현재 동작 |
|---|---|---|
| `DROP TABLE`     | ✅ | 없으면 no-op |
| `DROP VIEW`      | ✅ | 없으면 no-op |
| `DROP SYNONYM`   | ✅ | 없으면 no-op |
| `DROP SERIAL`    | ✅ | 없으면 no-op |
| `DROP TRIGGER`   | ❌ | Syntax error |
| `DROP INDEX`     | ❌ | Syntax error |
| `DROP USER`      | ❌ | Syntax error |
| `DROP PROCEDURE` | ❌ | Syntax error |
| `DROP FUNCTION`  | ❌ | Syntax error |

### 의심 지점

- `src/parser/csql_grammar.y`
  - `drop_stmt` 및 각 객체별 drop rule (drop_trigger_stmt, drop_index_stmt, drop_procedure_stmt, drop_function_stmt, drop_user_stmt) 에 `IF EXISTS` 옵션이 누락되어 있음. 기존 `drop_table_stmt` 와 `drop_view_stmt` 의 `opt_if_exists` non-terminal 재사용으로 대응 가능.
- 실행 단계: 각 drop handler 에서 "존재하지 않으면 no-op" 분기 추가.

### 영향 범위 추정

| 객체 | catalog / storage 변경 | 구현 난이도 |
|---|---|---|
| TRIGGER    | `_db_trigger` lookup by name | Low |
| INDEX      | `_db_index` + ON clause 와 조합 | Low~Medium |
| USER       | 사용자 존재 체크 (auth layer) | Low~Medium |
| PROCEDURE  | `_db_stored_procedure` lookup (owner.name) | Low |
| FUNCTION   | 동일 catalog, `sp_type=FUNCTION` | Low |

---

## Acceptance Criteria

- [ ] `DROP TRIGGER IF EXISTS <name>` 이 parser 에서 accept 되고, 존재하지 않으면 no-op.
- [ ] `DROP INDEX IF EXISTS <idx_name> ON <table>` 이 accept 되고 존재하지 않으면 no-op.
- [ ] `DROP USER IF EXISTS <name>` 이 accept 되고 존재하지 않으면 no-op.
- [ ] `DROP PROCEDURE IF EXISTS <name>` 이 accept 되고 존재하지 않으면 no-op (owner-qualified name 포함: `DROP PROCEDURE IF EXISTS dba.p`).
- [ ] `DROP FUNCTION IF EXISTS <name>` 동일.
- [ ] 기존 DROP 동작(`IF EXISTS` 없이) 회귀 없음.
- [ ] SQL 회귀 테스트 추가 (`tests/sql/_issues/...`).
- [ ] 매뉴얼(`en/sql/schema/*.rst`) 업데이트.

---

## Remarks

- 관련: F3 (CBRD-26731) `DROP IF EXISTS <synonym>` silent no-op.
- 상위 umbrella: CBRD-26730 (F4).
- 재현: `/tmp/bugbounty11455/out_26514.txt` (PROCEDURE), `out_fu_26541.txt` (다른 객체), 본 세션의 추가 probe 로그.
