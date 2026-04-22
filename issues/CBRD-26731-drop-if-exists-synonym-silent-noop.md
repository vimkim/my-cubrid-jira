# [DDL] `DROP IF EXISTS <synonym-name>` (타입 키워드 없음) 이 조용히 no-op 으로 종료

## Description

### 배경

CBRD-26541 이전에는 `DROP IF EXISTS <name>` 구문에서 `<name>` 이 시노님인 경우 **대상 테이블이 삭제되는** 심각한 버그가 있었다. 11.4.5 에서 이 동작은 수정되어 backing table 이 보존된다 (fix 의도대로). 그러나 부작용으로, 동일 구문이 **시노님 자체도 삭제하지 않고** `Execute OK` 로 조용히 종료된다.

결과적으로 고객/자동화 스크립트가 "DROP 성공" 으로 오인하고, 이후 `CREATE SYNONYM ...` 단계에서 `already exists` 오류로 실패할 수 있다.

### 목적

- `DROP IF EXISTS <synonym-name>` (타입 키워드 없음) 을 실행했을 때 사용자의 멘탈 모델과 일치하는 동작을 정의하고 구현한다.
- CBRD-26541 의 fix 로 backing table 을 보호한 후의 **2차 손실(silent no-op)** 을 제거한다.

---

## Analysis

### 재현 환경

- 브랜치: `bug-bounty-11.4.5` (HEAD `3df9de02b`)
- 빌드: `just build` (debug_clang)
- 클라이언트: `csql -udba testdb`
- 재현 로그: `/tmp/bugbounty11455/out_fu_26541.txt`

### 재현 스크립트

```sql
DROP TABLE IF EXISTS real_t;
CREATE TABLE real_t(id INT);
CREATE SYNONYM syn_for_real_t FOR real_t;

-- Before
SELECT 'before', (SELECT COUNT(*) FROM real_t) AS rows,
       (SELECT synonym_name FROM db_synonym WHERE synonym_name='syn_for_real_t') AS syn;

-- Ambiguous DROP (no type keyword)
DROP IF EXISTS syn_for_real_t;      -- Execute OK

-- After
SELECT 'after_ambig', (SELECT COUNT(*) FROM real_t) AS rows,
       (SELECT synonym_name FROM db_synonym WHERE synonym_name='syn_for_real_t') AS syn;
-- → rows=2, syn='syn_for_real_t'  (둘 다 그대로)
```

### 관찰

| 단계 | real_t 존재 | syn_for_real_t 존재 | 결과 코드 |
|---|---|---|---|
| Before | ✓ | ✓ | — |
| `DROP IF EXISTS syn_for_real_t;` | ✓ (보존, 정상) | ✓ (**삭제되지 않음**) | Execute OK |

비교를 위해 같은 세션에서 타입 키워드를 명시한 경우:
- `DROP SYNONYM IF EXISTS syn_for_real_t;` → 시노님 삭제 ✓
- `DROP syn_for_real_t;` (타입 없음, IF EXISTS 없음) → `ERROR: Class dba.syn_for_real_t does not exist.` (시노님 lookup 미실행)

즉 `DROP IF EXISTS <name>` 에서 "IF EXISTS + 타입 없음" 조합일 때만 시노님 lookup 이 skip 되는 패턴으로 보인다.

### 선택지

1. **Option A** — `DROP IF EXISTS <name>` (타입 없음) 를 시노님도 대상에 포함하도록 확장. 타입을 지정하지 않은 경우 TABLE → VIEW → SYNONYM 순서로 lookup 하고 찾으면 drop, 찾지 못하면 IF EXISTS 규칙에 의해 no-op.
2. **Option B** — 타입 없는 `DROP IF EXISTS <name>` 는 명확히 "ambiguous object kind" 오류로 처리하고, 시노님 삭제는 반드시 `DROP SYNONYM IF EXISTS` 사용하도록 유도.
3. **Option C** — 현재 동작(silent no-op) 을 유지하되 문서에 명시하고 경고 메시지 출력.

Option A 가 사용자 기대에 가장 부합. 기존에 `DROP IF EXISTS <table>` 가 되는 점을 고려하면 symmetry 유지.

### 의심 지점

- `src/parser/parser_support.c` 또는 `src/parser/semantic_check.c` 의 `DROP IF EXISTS` 처리 (object-kind resolution 로직).
- CBRD-26541 fix 커밋의 변경 범위 확인 후 시노님 삭제 경로 포함 여부 판단.

---

## Acceptance Criteria

- [ ] Option A 채택 시: `DROP IF EXISTS <synonym-name>` 이 해당 시노님이 존재하면 삭제하고, 없으면 no-op (에러 없음).
- [ ] Option B 채택 시: `DROP IF EXISTS <name>` 가 타입 키워드 없이 호출된 경우 명확한 에러 메시지로 reject.
- [ ] `DROP IF EXISTS <table-name>` 기존 동작은 회귀 없이 유지.
- [ ] `DROP IF EXISTS <view-name>` 기존 동작도 회귀 없이 유지.
- [ ] CBRD-26541 의 핵심 fix(backing table 보호) 동작은 유지.
- [ ] SQL 회귀 테스트 추가.

---

## Remarks

- 관련: CBRD-26541 (원래 fix), CBRD-26732 (DROP PROCEDURE/FUNCTION 등 `IF EXISTS` 미지원).
- 재현: `/tmp/bugbounty11455/t_26541_synonym_drop.sql`, `fu_26541_synonym.sql`.
- 상위 umbrella: CBRD-26730 (F3).
