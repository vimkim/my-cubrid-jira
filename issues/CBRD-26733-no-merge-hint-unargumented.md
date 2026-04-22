# [HINT] 인자 없는 `/*+ NO_MERGE */` 힌트의 동작 명세 확인 필요

## Description

### 배경

CUBRID 의 view-merge 관련 힌트로 `NO_MERGE(view_alias)` 가 존재한다. 11.4.5 internal test 중, **인자 없이** `/*+ NO_MERGE */` 를 outer query 에 사용한 경우에도 inline view 가 그대로 **view-merge** 되는 것으로 관측되었다. 이 동작이 (a) 의도된 것(= NO_MERGE 는 반드시 대상 view alias 지정 필수) 인지, (b) 버그(= 인자 없으면 전체 view 머지 차단)인지, (c) 단순 misspelled keyword 인지 불분명하다.

매뉴얼/문법 정리 및 사용자 기대에 맞춘 일관된 동작 정의가 필요하다.

### 목적

- 인자 없는 `/*+ NO_MERGE */` 의 동작을 명세한다.
- 실제 구현과 문서 간 일관성을 확보한다.
- 필요 시 parser 에서 syntax error 로 reject 하거나, 반대로 "전체 inline view 머지 차단" 으로 구현.

---

## Analysis

### 재현 환경

- 브랜치: `bug-bounty-11.4.5` (HEAD `3df9de02b`)
- 클라이언트: `csql -udba testdb`
- 재현 로그: `/tmp/bugbounty11455/out_fu_26624.txt`

### 재현 스크립트 및 관찰

```sql
DROP TABLE IF EXISTS t1; DROP TABLE IF EXISTS t2;
CREATE TABLE t1(id INT, v INT);
CREATE TABLE t2(id INT, v INT);
INSERT INTO t1 SELECT ROWNUM, ROWNUM FROM db_class LIMIT 30;
INSERT INTO t2 SELECT ROWNUM, ROWNUM FROM db_class LIMIT 30;

SET TRACE ON;
SELECT /*+ recompile NO_MERGE */ *
FROM ( SELECT /*+ ORDERED */ a.v FROM t1 a, t2 b WHERE a.id = b.id ) V;
SHOW TRACE;
```

관찰된 `Query Plan`:

```
NESTED LOOPS (inner join)
  TABLE SCAN (V)
  TABLE SCAN (b)
```

`rewritten query`:

```
select /*+ ORDERED NO_MERGE */ V.v from [dba.t1] V, [dba.t2] b where (V.id=b.id)
```

`FROM` 목록에 `[dba.t1] V, [dba.t2] b` 두 개의 테이블이 **flat 하게** 나열되어 있다. 즉 inline view `V` 가 **merged** 되었다. 동시에 `NO_MERGE` 힌트는 rewritten query 에 보존되어 있다 (의미 없이 유지됨).

### 기대 동작 (가설)

사용자 기대는 일반적으로 다음 중 하나:

1. `NO_MERGE` (무인자) → outer 에서 보이는 모든 inline view 머지를 차단.
2. `NO_MERGE` (무인자) → 의미 없음 / syntax error. 반드시 `NO_MERGE(view_alias)` 필요.
3. `NO_MERGE` (무인자) → 첫 번째 inline view 에만 적용.

CUBRID manual 의 NO_MERGE 표기는 `/*+ NO_MERGE(view_name[, view_name]*) */` 이므로 안전한 구현은 **option 2** (parser 에서 accept 하되 warning, 또는 syntax error 로 reject).

### 의심 지점

- `src/parser/csql_grammar.y`: hint argument list 파싱. 무인자 `NO_MERGE` 가 accept 되어 `PT_HINT_NO_MERGE` bit 만 set 될 가능성.
- `src/parser/view_transform.c`: `mq_translate_select` 경로에서 view merge 판단 시 `PT_HINT_NO_MERGE` bit 를 보고 차단해야 하는데, argument 가 없으면 target match 가 실패해 차단되지 않을 수 있음.
- 또는: `NO_MERGE` 는 현재 무인자를 허용하지 않지만 parser 가 관대하게 통과시키고 semantic check 에서 의미 없이 drop 하는 구조일 수 있음.

---

## Acceptance Criteria

- [ ] 인자 없는 `/*+ NO_MERGE */` 에 대한 **공식 동작** 이 명세된다.
  - 권장: syntax error 로 reject (Option 2).
- [ ] 권장 동작 채택 시 parser 에서 명확한 에러 메시지 출력.
- [ ] 기존 `NO_MERGE(view_alias)` 유효 동작은 회귀 없이 유지.
- [ ] CUBRID manual 의 NO_MERGE 섹션 업데이트.
- [ ] SQL 회귀 테스트 추가.

---

## Remarks

- 관련: CBRD-26624 / CBRD-26419 (view merge 룰), CBRD-26728 (단일 뷰 머지 hint 정제 미동작 버그).
- 상위 umbrella: CBRD-26730 (F5).
- 재현: `/tmp/bugbounty11455/fu_26624_each.sql`, `out_fu_26624.txt`.
