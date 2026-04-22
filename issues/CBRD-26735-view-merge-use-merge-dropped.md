# [OPTIMIZER] View merge 시 outer 의 USE_MERGE 힌트가 silent drop 되어 merge join 이 NL 로 폴백됨

## Description

### 배경

CBRD-26419 / CBRD-26624 에서 view merge 시 hint 처리 규칙이 개선되었다. LEADING / ORDERED 처리는 해당 티켓에서 다루었으나, **`USE_MERGE` 힌트** 에 대한 별도의 처리는 없었다.

검증 중, **outer SELECT 에 `/*+ USE_MERGE(view_alias, other_table) */` 을 지정해도 view merge 이후 힌트가 통째로 사라지는 현상** 을 발견했다. `USE_NL` 및 `USE_HASH` 는 동일 구조에서 정상 보존되어, `USE_MERGE` 한 종류만 선별적으로 깨져 있다.

### 목적

View merge 시 outer 의 `USE_MERGE` 힌트가 올바르게 보존되어 사용자가 지정한 merge join 계획이 실제로 적용되도록 수정한다.

---

## Analysis

### Reproduction

```sql
DROP TABLE IF EXISTS t1;
DROP TABLE IF EXISTS t2;
CREATE TABLE t1(id INT PRIMARY KEY, v INT);
CREATE TABLE t2(id INT PRIMARY KEY, v INT);
INSERT INTO t1 SELECT ROWNUM, ROWNUM*2 FROM db_class LIMIT 50;
INSERT INTO t2 SELECT ROWNUM, ROWNUM*3 FROM db_class LIMIT 50;

SET TRACE ON;
-- Outer 에 USE_MERGE, view alias (v) 사용 → merge 로 실행되어야 함
SELECT /*+ RECOMPILE USE_MERGE(v,b) */ *
FROM (SELECT a.v FROM t1 a, t2 b WHERE a.id=b.id) v;
SHOW TRACE;
SET TRACE OFF;
```

**Observed rewritten query:**
```
select v.v from [dba.t1] v, [dba.t2] b where (v.id=b.id)
```

`USE_MERGE(v,b)` 가 rewritten query 에서 완전히 제거되었고, 실행 계획은 nested loop 으로 fallback. `PT_HINT_USE_MERGE` 비트와 argument list 둘 다 사라짐.

### Counter-examples (정상 동작)

```sql
-- (1) View 없이 직접 join: USE_MERGE 정상 적용
SELECT /*+ RECOMPILE USE_MERGE(a,b) */ a.v FROM t1 a, t2 b WHERE a.id=b.id;
-- rewritten: select /*+ USE_MERGE(a, b) */ a.v ... → MERGE JOIN

-- (2) USE_NL(v) 및 USE_HASH(v) 는 view merge 후에도 살아남음
SELECT /*+ RECOMPILE USE_NL(v,b)   */ * FROM (SELECT a.v FROM t1 a, t2 b WHERE a.id=b.id) v;  -- OK
SELECT /*+ RECOMPILE USE_HASH(v,b) */ * FROM (SELECT a.v FROM t1 a, t2 b WHERE a.id=b.id) v;  -- OK
```

오직 **`USE_MERGE` 한 종류만** view merge 시 drop 된다.

### 추가 관찰

Outer 와 subquery 각각 다른 테이블에 `USE_MERGE` 를 걸면, **subquery 의 argument 만 살아남고 outer 의 것이 드롭됨**:
```sql
SELECT /*+ RECOMPILE USE_MERGE(b) */ *
FROM (SELECT /*+ USE_MERGE(a) */ a.v FROM t1 a, t2 b WHERE a.id=b.id) v;
-- rewritten: select /*+ USE_MERGE(a) */ v.v ...
-- outer USE_MERGE(b) 드롭, subquery USE_MERGE(a) 유지
```

### Why it looks like a bug — Root cause

`mq_copy_sql_hint()` (`src/parser/view_transform.c:14749`) 는 subquery 의 `use_merge` 노드 리스트를 `dest_query->info.query.q.select.use_merge` 에 무조건 append 한다. `PT_HINT_LEADING` 에는 line 14709–14714 에서 conflict guard 가 존재하지만, `use_merge` 에는 동등한 guard 가 없다.

문제의 핵심은 **spec_id 갱신 누락** 이다:

1. Outer query 의 기존 `use_merge` arg node 들은 view 의 spec 을 가리키는 `spec_id` 를 보유
2. `mq_substitute_select_for_inline_view()` 가 view spec 을 replace 하면서 `spec_id` 가 갱신되어야 함
3. `MQ_FIX_SPEC_ID` 순회 (`view_transform.c:1776`) 는 **새로 append 된 subquery 의 노드만** 다시 적는다
4. Outer 의 original `use_merge` 노드는 순회 대상이 아니라 stale `spec_id` 를 그대로 보유
5. Stale `spec_id` 는 나중에 resolver / printer 에서 인식되지 않아 hint 전체가 **조용히 생략** 됨

`USE_NL` / `USE_HASH` 가 동일 구조에서 살아남는 이유는 별도 노드 리스트(`use_nl`, `use_hash`)를 사용해서 spec 교체 시점이 다르거나, 다른 경로로 spec_id 를 재바인딩하기 때문으로 추정. 동일 메커니즘을 `use_merge` 에도 적용해야 함.

### 참고 코드

| 파일:라인 | 역할 |
|---|---|
| `src/parser/view_transform.c:14749` | `mq_copy_sql_hint()` — use_merge 무조건 append (conflict guard 없음) |
| `src/parser/view_transform.c:1776` | `MQ_FIX_SPEC_ID` — 새 append 노드만 순회, outer 원본은 미순회 |
| `src/parser/view_transform.c:14709-14714` | `PT_HINT_LEADING` conflict guard 구현 (참고용) |
| `src/parser/view_transform.c:1xxx` | `mq_substitute_spec_in_method_and_hints()` — outer 의 기존 hint 노드의 spec_id 갱신 주체로 보이나 `use_merge` 누락 |

### Impact

- `/*+ USE_MERGE(alias, ...) */` 를 inline view 의 outer SELECT 에 사용하는 쿼리 전체에서 힌트가 **조용히 무시됨**
- Optimizer 가 독자 판단으로 NL+index 등 다른 plan 선택 → 성능 regression 발생 가능
- `SHOW TRACE` 를 보지 않으면 발견 불가 — **silent plan divergence**
- LEADING/ORDERED 규칙(CBRD-26419) 정비의 연장선상에서 같은 파일의 이웃 코드 경로의 누락

---

## Implementation

### 수정 방향

두 가지 중 하나 또는 둘 다 적용:

**(A) MQ_FIX_SPEC_ID 순회 확장**
- `mq_substitute_spec_in_method_and_hints()` (view_transform.c:1776 부근) 가 `use_merge` 리스트의 outer 원본 노드까지 순회해 `spec_id` 를 갱신하도록 수정
- `use_nl`, `use_hash` 와 대칭되게 처리

**(B) mq_copy_sql_hint() 대칭 guard 추가**
- `PT_HINT_LEADING` 처럼 `PT_HINT_USE_MERGE` 에 대해서도 outer 가 이미 `use_merge` 를 가지면 subquery 것을 복사하지 않는 conflict guard 추가
- 단 본질은 (A) 의 spec_id 갱신 누락이므로 (A) 가 1차 해결

### 주 수정 대상

| 파일 | 라인 | 변경 내용 |
|---|---|---|
| `src/parser/view_transform.c` | 1776 부근 | `MQ_FIX_SPEC_ID` 또는 `mq_substitute_spec_in_method_and_hints()` 에서 `use_merge` outer 원본 노드까지 순회 |
| `src/parser/view_transform.c` | 14749 | `mq_copy_sql_hint()` 의 `use_merge` 분기에 `PT_HINT_LEADING` 대칭 guard (선택) |

---

## A/C (Acceptance Criteria)

- [ ] `SELECT /*+ RECOMPILE USE_MERGE(v,b) */ * FROM (SELECT a.v FROM t1 a, t2 b WHERE a.id=b.id) v;` 의 rewritten query 에 `USE_MERGE(v, b)` 가 보존됨
- [ ] 실행 계획이 MERGE JOIN 으로 나옴 (NL 아님)
- [ ] Outer `USE_MERGE(b)` + subquery `USE_MERGE(a)` 병용 시, outer 의 argument 가 드롭되지 않음
- [ ] `USE_NL`, `USE_HASH` 경로 regression 없음
- [ ] View 가 없는 직접 join 의 `USE_MERGE` regression 없음
- [ ] LEADING/ORDERED/NO_MERGE 등 CBRD-26419/26624 동작 regression 없음

---

## Remarks

- 11.4.5 internal test 에서 발견 (FINDINGS_11.4.5.md BUG 3)
- 재현 스크립트: `/tmp/bugbounty11455/view_merge_hints/test_use_merge.sql`
- CBRD-26419 / CBRD-26624 의 연장 규칙 정비 작업으로 링크 필요
- 동반 발견 이슈 (별도 티켓): CBRD-26736 — 서브쿼리 `RECOMPILE` 이 view merge 를 통해 outer 로 새는 문제 (동일 파일 `view_transform.c` 의 이웃 버그)
