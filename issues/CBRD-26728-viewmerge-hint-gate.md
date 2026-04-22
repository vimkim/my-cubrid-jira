# [PARSER] 단일 뷰 머지(single view merge) 시 ORDERED/LEADING 힌트 정제 로직이 동작하지 않음

## Description

### 배경

CBRD-26419 의 spec 은 **뷰 머지 시 힌트 처리 규칙** 을 다음과 같이 정의한다.

1. 부질의의 `LEADING(...)` 힌트는 주질의에 LEADING 이 없어서 **충돌이 발생하지 않는 경우에만** 머지된 질의로 복사한다.
2. 부질의의 `ORDERED` 힌트는 **뷰 머지 시 제거** 한다.

11.4.5 에는 CBRD-26419/26624 (backport `a33edd6fc`, `7e7f6310b`) 가 적용되어 있으나, 실제로 11.4.5 빌드에서 `SHOW TRACE` 로 rewritten query 를 확인하면 **단일 뷰 머지(single view merge)** 경로에서 위 두 규칙이 전혀 적용되지 않는다. 원인은 `mq_copy_sql_hint()` 의 gate 조건 때문이다.

### 목적

- 단일 뷰 머지 경로에서도 CBRD-26419 의 ORDERED 제거 / LEADING 충돌 무시 규칙이 일관되게 적용되도록 `mq_copy_sql_hint()` 의 gate 조건을 수정한다.
- CBRD-26419 의 spec 과 실제 구현 동작을 일치시킨다.

---

## Analysis

### 재현 환경

- 브랜치: `bug-bounty-11.4.5` (HEAD: `3df9de02b`)
- 빌드: `just build` (debug_clang preset)
- 서버: `cubrid server start testdb`
- 클라이언트: `csql -udba testdb`

### 재현 스크립트

```sql
DROP TABLE IF EXISTS t1;
DROP TABLE IF EXISTS t2;
CREATE TABLE t1(id INT, v INT);
CREATE TABLE t2(id INT, v INT);
INSERT INTO t1 SELECT ROWNUM, ROWNUM*2 FROM db_class LIMIT 50;
INSERT INTO t2 SELECT ROWNUM, ROWNUM*3 FROM db_class LIMIT 50;

SET TRACE ON;

-- Case A: 부질의 ORDERED 는 머지 시 제거되어야 함 (rule 3)
SELECT /*+ recompile */ *
FROM ( SELECT /*+ ORDERED */ a.v FROM t1 a, t2 b WHERE a.id = b.id ) v;
SHOW TRACE;

-- Case B: 주질의 LEADING 이 있으면 부질의 LEADING 은 복사되지 않아야 함 (rule 2)
SELECT /*+ recompile LEADING(V) */ *
FROM ( SELECT /*+ LEADING(b, a) */ a.v FROM t1 a, t2 b WHERE a.id = b.id ) V;
SHOW TRACE;
```

### 관찰된 결과

Case A `rewritten query`:
```
select /*+ ORDERED */ v.v from [dba.t1] v, [dba.t2] b where (v.id=b.id)
```
→ **`ORDERED` 가 그대로 남아있다** (제거되어야 함).

Case B `rewritten query`:
```
select /*+ LEADING(V, b, a) */ V.v from [dba.t1] V, [dba.t2] b where (V.id=b.id)
```
→ 주질의 `LEADING(V)` 에 **부질의 `LEADING(b, a)` 가 append** 되어 `LEADING(V, b, a)` 가 되었다. 부질의 LEADING 은 복사되지 **않아야** 한다.

### 규칙 별 기대값 vs 실측

| Case | 주질의 힌트 | 부질의 힌트 | 기대 rewritten | 실측 rewritten | 결과 |
|---|---|---|---|---|---|
| A | (없음) | `ORDERED` | (힌트 없음) | `/*+ ORDERED */` | ❌ |
| B | `LEADING(V)` | `LEADING(b, a)` | `/*+ LEADING(V) */` (부질의 무시) | `/*+ LEADING(V, b, a) */` | ❌ |
| C (참고) | (없음) | `LEADING(b, a)` | `/*+ LEADING(b, a) */` | `/*+ LEADING(b, a) */` | ✅ |

### 근본 원인

`src/parser/view_transform.c` 의 `mq_copy_sql_hint()` 는 힌트 정제 로직(ORDERED 제거, LEADING 충돌 무시)을 **`dest_query->from->next != NULL`** 조건 하에서만 수행한다.

```c
// src/parser/view_transform.c:14691-14720
static void
mq_copy_sql_hint (PARSER_CONTEXT * parser, PT_NODE * dest_query, PT_NODE * src_query)
{
  ...
  if (dest_query->node_type == PT_SELECT)
    {
      ...
      /* remove some hints if there are multiple tables.  */
      if (dest_query->info.query.q.select.from->next != NULL)      // ← 게이트
        {
          /* ignore ordered hint */
          if (src_query->info.query.q.select.hint & PT_HINT_ORDERED)
            {
              src_query->info.query.q.select.hint &= ~PT_HINT_ORDERED;
            }
          if (src_query->info.query.q.select.hint & PT_HINT_LEADING
              && dest_query->info.query.q.select.hint & PT_HINT_LEADING)
            {
              /* ignore leading hint */
              src_query->info.query.q.select.hint &= ~PT_HINT_LEADING;
            }
        }
      if (src_query->info.query.q.select.hint & PT_HINT_LEADING)
        {
          dest_query->info.query.q.select.leading =
            parser_append_node (parser_copy_tree_list (parser, src_query->info.query.q.select.leading),
                                dest_query->info.query.q.select.leading);
        }
      ...
```

그런데 `mq_copy_sql_hint` 는 **치환이 일어나기 전** 에 호출된다 (`src/parser/view_transform.c:2597`, `2798`, `2838`). 이 시점의 `dest_query` 는 아직 뷰가 inline 되지 않았으므로, 단일 뷰 머지의 경우:

```
dest_query->info.query.q.select.from  = [ <view-spec> ]     // 한 개뿐
dest_query->info.query.q.select.from->next = NULL
```

→ gate 조건이 항상 거짓 → ORDERED 제거와 LEADING 충돌 guard 블록이 **skip** 된다. 이어지는 `parser_append_node` 는 무조건 실행되어 부질의의 LEADING 이 그대로 복사된다.

결과적으로 **단일 뷰 머지** 시 두 규칙이 완전히 비활성화된다. 여러 테이블을 이미 조인하고 있는 쿼리에서 추가로 inline view 를 머지하는 경우(`dest->from->next != NULL`)에만 규칙이 동작한다.

### 호출 컨텍스트

```
mq_translate_select
  └─ mq_copy_sql_hint(tmp_result, subquery)       // line 2597  (inline-view 머지 진입 직전)
  └─ mq_substitute_select_for_inline_view(...)    // line 2614  (여기서 FROM 리스트가 합쳐짐)
```

gate 가 검사해야 할 대상은 "머지 후의 outer FROM 테이블 수" 인데, 실제로는 "머지 전의 outer FROM 테이블 수" 를 검사하고 있다.

---

## Fix Direction

### 옵션 1. Gate 조건을 **src 기반** 으로 변경 (권장)

CBRD-26419 spec 은 "부질의의 ORDERED 는 뷰 머지 시 제거", "주질의 LEADING 이 있으면 부질의 LEADING 무시" 라는 단순한 규칙이므로, gate 는 `src` 가 여러 테이블을 가졌는지(즉 ORDERED 가 의미 있는지)로 바꾸는 것이 spec 에 맞다.

```c
if (src_query->info.query.q.select.from != NULL
    && src_query->info.query.q.select.from->next != NULL)
  {
    /* ignore ordered hint during view-merge */
    src_query->info.query.q.select.hint &= ~PT_HINT_ORDERED;

    if (dest_query->info.query.q.select.hint & PT_HINT_LEADING)
      {
        /* outer already has LEADING → drop inner LEADING */
        src_query->info.query.q.select.hint &= ~PT_HINT_LEADING;
      }
  }
```

### 옵션 2. 무조건 적용 (outer 가 단일 테이블 + 부질의 조인인 single-view 인 경우 항상 해당)

`dest->from->next != NULL` 검사 자체를 제거하고 항상 수행. 현재 테스트된 케이스는 모두 개선 방향에 부합.

옵션 1 쪽이 기존 의도(여러 테이블이 있어야 ORDERED 제거가 의미 있음)를 존중하면서 single-view 머지까지 커버한다.

### 의심 지점

- `src/parser/view_transform.c:14691-14714` `mq_copy_sql_hint()` — gate 조건
- `src/parser/view_transform.c:2597`, `2798`, `2838` — 호출 사이트 (head merge vs vclass merge 구분 필요)

---

## Impact

- `SELECT ... FROM (SELECT /*+ LEADING(...) */ ... )` 형태의 single-view 머지 쿼리에서 기대와 다른 조인 순서가 선택될 수 있다.
- 주질의 LEADING 을 신뢰하고 성능 튜닝한 고객 쿼리가 부질의의 LEADING/ORDERED 로 인해 **플랜이 바뀌고 성능이 역행** 할 수 있다.
- CBRD-26419 spec 이 내부 공지된 상태에서 일부 케이스만 동작하므로 QA 신뢰도 저하.

---

## Acceptance Criteria

- [ ] Case A `SELECT /*+ recompile */ * FROM (SELECT /*+ ORDERED */ ...) v` 의 rewritten query 에서 `ORDERED` 가 제거된다.
- [ ] Case B `SELECT /*+ recompile LEADING(V) */ * FROM (SELECT /*+ LEADING(b, a) */ ...) V` 의 rewritten query 에 부질의의 `LEADING(b, a)` 가 포함되지 않는다.
- [ ] Case C (주질의 LEADING 없음, 부질의 LEADING 존재) 의 기존 동작은 회귀 없이 유지된다 (부질의 LEADING 그대로 복사).
- [ ] 다중 테이블 outer (기존 gate 가 이미 동작하던 케이스) 의 동작도 회귀 없이 유지된다.
- [ ] 위 시나리오를 커버하는 SQL 회귀 테스트(`tests/sql/_issues/...`) 및 `SHOW TRACE` 기반 기대값 검증이 추가된다.

---

## Remarks

- 관련 fix: CBRD-26419 backport `a33edd6fc`, CBRD-26624 backport `7e7f6310b`.
- 관련 JIRA: CBRD-26419 (hint rule spec), CBRD-26624 (single view merge LEADING arg copy).
- 재현 스크립트/로그: `/tmp/bugbounty11455/fu_26624_strict.sql`, `/tmp/bugbounty11455/out_fu_26624_strict.txt`.
- 별건 이슈: CBRD-26727 (문자 리터럴 → NUMERIC auto-cast precision 미적용) 동일 11.4.5 internal test 세션에서 발견.
