# [OPTIMIZER] View merge 시 서브쿼리의 RECOMPILE 힌트가 outer 로 누설되어 SHOW TRACE 출력이 사라짐

## Description

### 배경

CBRD-26419 / CBRD-26624 에서 view merge 시 hint 처리 규칙이 개선되었다. 서브쿼리의 `ORDERED` 힌트는 view merge 시 제거되도록 명시되었으며, 실제로 `mq_copy_sql_hint()` 에서 `PT_HINT_ORDERED` 는 exclusion set 에 포함되어 있다.

그러나 동일 함수의 다른 hint 비트들은 **bitwise OR 로 무조건 병합** 되어 있어, 서브쿼리에만 지정된 `/*+ RECOMPILE */` 이 outer 로 흘러 들어가는 문제가 있다. 그 결과 **`SHOW TRACE` 에서 `Query Plan` / `rewritten query` 섹션이 통째로 사라지는** 증상이 발생한다. DBA / 개발자의 plan 디버깅 체인을 깨뜨리는 영향.

### 목적

서브쿼리 스코프의 `RECOMPILE` 이 view merge 이후 outer 로 전파되지 않도록 `PT_HINT_RECOMPILE` 을 `mq_copy_sql_hint()` 의 exclusion set 에 추가한다. `PT_HINT_ORDERED` 와 대칭되게 처리.

---

## Analysis

### Reproduction

```sql
CREATE TABLE t1(id INT PRIMARY KEY, v INT);
CREATE TABLE t2(id INT PRIMARY KEY, v INT);
INSERT INTO t1 SELECT ROWNUM, ROWNUM*2 FROM db_class LIMIT 50;
INSERT INTO t2 SELECT ROWNUM, ROWNUM*3 FROM db_class LIMIT 50;

SET TRACE ON;

-- (1) Baseline — outer 에 RECOMPILE: Query Plan / rewritten query 정상 출력
SELECT /*+ RECOMPILE */ * FROM (SELECT a.v FROM t1 a, t2 b WHERE a.id=b.id) v;
SHOW TRACE;

-- (2) Bug — 서브쿼리에만 RECOMPILE: Query Plan / rewritten query 사라짐
SELECT * FROM (SELECT /*+ RECOMPILE */ a.v FROM t1 a, t2 b WHERE a.id=b.id) v;
SHOW TRACE;

SET TRACE OFF;
```

### Observed Output

| Query | `Query Plan` in SHOW TRACE | `rewritten query` in SHOW TRACE |
|---|---|---|
| `SELECT /*+ RECOMPILE */ * FROM (sub) v` | YES | YES |
| `SELECT * FROM (SELECT /*+ RECOMPILE */ ...) v` | **NO** | **NO** |

두 번째 쿼리의 `SHOW TRACE` 출력은 `Trace Statistics:` 섹션만 존재하고, 실행 계획 관련 섹션이 전부 누락된다.

### Why it looks like a bug — Root cause

`mq_copy_sql_hint()` (`src/parser/view_transform.c:14724`) 에서 hint 비트를 **무조건 bitwise OR 로 병합**:

```c
dest_query->info.query.q.select.hint =
    (PT_HINT_ENUM) (dest_query->info.query.q.select.hint
                    | src_query->info.query.q.select.hint);
```

`PT_HINT_RECOMPILE` (`1ULL << 8`) 은 exclusion 대상에 포함되어 있지 않다. 그래서 서브쿼리가 `/*+ RECOMPILE */` 을 갖고 있으면 view merge 이후 merged outer 가 `PT_HINT_RECOMPILE` 을 상속하게 되고, optimizer 는 이 merged query 를 recompilation 요청으로 취급한다. 그 결과 `SHOW TRACE` 의 plan 섹션이 출력되지 않는다.

사용자 의도는 **서브쿼리의 plan 을 recompile 하라** 이지, **outer 쿼리의 trace 가시성에 영향** 을 주려는 것이 아니다. 스코프 분리가 깨진다.

### 대칭 참고 (ORDERED 와의 차이)

같은 함수에서 `PT_HINT_ORDERED` 는 제대로 처리되고 있다 (line 14707 부근). 동일 패턴을 `PT_HINT_RECOMPILE` 에도 적용해야 한다.

### 참고 코드

| 파일:라인 | 역할 |
|---|---|
| `src/parser/view_transform.c:14724` | `mq_copy_sql_hint()` — 모든 hint 비트 무조건 OR |
| `src/parser/view_transform.c:14707` 부근 | `PT_HINT_ORDERED` exclusion 구현 (참고 대칭) |
| `src/parser/parse_tree.h` | `PT_HINT_RECOMPILE = 1ULL << 8` 정의 |

### Impact

- 개발자 / DBA 가 `SET TRACE ON; SHOW TRACE;` 로 plan 을 디버깅할 때 **inline view 에 `RECOMPILE` 이 있으면 trace 가 비어 보임**
- Plan 분석 루틴이 깨져 성능 조사 / 회귀 진단이 오도됨
- Hint 스코프 격리 (subquery vs outer) 가 보장되지 않음 — 문서상 RECOMPILE 은 해당 쿼리 스코프에만 적용되어야 함

---

## Implementation

### 수정 방향

`mq_copy_sql_hint()` 에서 hint 비트 병합 전에 subquery 측의 `PT_HINT_RECOMPILE` 을 masking out 한다. `PT_HINT_ORDERED` 와 동일한 패턴을 그대로 복사 적용.

### Pseudo-diff

```c
// src/parser/view_transform.c:14724 부근
PT_HINT_ENUM src_hint = src_query->info.query.q.select.hint;

// ORDERED 처리 (기존)
src_hint = (PT_HINT_ENUM) (src_hint & ~PT_HINT_ORDERED);

// RECOMPILE 처리 (신규)
src_hint = (PT_HINT_ENUM) (src_hint & ~PT_HINT_RECOMPILE);

dest_query->info.query.q.select.hint =
    (PT_HINT_ENUM) (dest_query->info.query.q.select.hint | src_hint);
```

### 추가 확인 필요

`mq_copy_sql_hint()` 의 bitwise OR 분기에 포함되는 다른 hint 비트(예: `PT_HINT_QUERY_CACHE`, `PT_HINT_NO_HASH_AGGREGATE`)들에 대해서도 스코프 누설 리스크가 없는지 검증. 초기 조사에서 `NO_MERGE`, `QUERY_CACHE` 는 view merge 자체를 블록하므로 이 경로에 진입하지 않아 영향 없음.

### 주 수정 대상

| 파일 | 라인 | 변경 내용 |
|---|---|---|
| `src/parser/view_transform.c` | 14724 | `src_query` hint 비트 중 `PT_HINT_RECOMPILE` 을 mask-out 한 뒤 OR |

---

## A/C (Acceptance Criteria)

- [ ] `SELECT * FROM (SELECT /*+ RECOMPILE */ a.v FROM t1 a, t2 b WHERE a.id=b.id) v;` 에 대해 `SHOW TRACE` 출력에 `Query Plan` 섹션이 존재함
- [ ] 동 쿼리 `SHOW TRACE` 출력에 `rewritten query` 섹션이 존재함
- [ ] Outer 에 `/*+ RECOMPILE */` 을 건 기존 경로는 regression 없음 (기존과 동일하게 Plan / rewritten query 출력)
- [ ] 서브쿼리에서 사용한 `/*+ RECOMPILE */` 이 merged outer 의 optimizer 재컴파일 동작에 영향을 주지 않음
- [ ] `PT_HINT_ORDERED` 와의 대칭성이 보장됨 (둘 다 subquery 스코프에서 제거)
- [ ] `NO_MERGE`, `QUERY_CACHE` 등 view merge 자체를 차단하는 hint 동작 regression 없음

---

## Remarks

- 11.4.5 internal test 에서 발견 (FINDINGS_11.4.5.md BUG 4)
- 재현 스크립트: `/tmp/bugbounty11455/view_merge_hints/test_hints.sql`
- CBRD-26419 / CBRD-26624 의 hint 규칙 정비 연장으로 링크 필요
- 동반 발견 이슈 (별도 티켓): CBRD-26735 — outer `USE_MERGE` 가 view merge 시 drop 되는 문제 (동일 파일 `view_transform.c` 의 이웃 버그)
- 두 티켓(26735, 26736)은 동일 함수 `mq_copy_sql_hint()` 주변 버그이므로 동일 PR 로 묶어 수정 가능
