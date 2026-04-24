# [PL/SP] PL/CSQL 내부의 COMMIT 이 caller 의 outer 트랜잭션을 조용히 커밋하여, 후속 ROLLBACK 이 무효화됨

## Description

### 배경

CUBRID 11.4.5 에서 PL/CSQL 저장 프로시저 내부에 `COMMIT;` 문이 포함된 SP 를 outer 트랜잭션이 열린 상태에서 호출하면, **SP 의 COMMIT 이 outer 트랜잭션의 모든 미커밋 변경 사항까지 함께 커밋** 해버린다. 그 결과 caller 가 이후에 수행하는 `ROLLBACK;` 은 "Execute OK" 로 반환되지만 실제로는 **아무것도 undo 되지 않는** 조용한(silent) 데이터 커밋이 발생한다.

이는 저장 프로시저의 트랜잭션 스코프 경계가 문서화된 계약을 어기는 **트랜잭션 원자성(atomicity) 위반** 이다. CALL 을 큰 트랜잭션 안에 감싸고 실패 시 `ROLLBACK` 으로 전체 undo 하는 표준 패턴을 사용하는 모든 애플리케이션에서 **부분 커밋(partial commit) 데이터 손상** 이 silent 하게 발생할 수 있다.

### 목적

- PL/CSQL SP 내부의 `COMMIT` / `ROLLBACK` 동작을 수정 또는 명시적 에러로 차단하여 caller 트랜잭션의 원자성을 보장한다.
- 표준 옵션(택 1 이상):
  1. **Autonomous transaction** 의미론 도입 — SP 내부 COMMIT 은 SP 로컬 변경만 커밋 (Oracle 의 `PRAGMA AUTONOMOUS_TRANSACTION` 모델).
  2. Active outer transaction 존재 시 SP 내부 `COMMIT` / `ROLLBACK` 호출을 **runtime error 로 reject** (MySQL 의 `ER_COMMIT_NOT_ALLOWED_IN_SF_OR_TRG` 모델).
  3. 현재 동작 유지하되 문서에 명시하고 outer session 에 warning 을 올림 (최소 수준).

---

## Analysis

### Reproduction (100% 재현)

**Setup:**
```sql
CREATE TABLE tA (x INT);
INSERT INTO tA VALUES (1);
COMMIT;

CREATE OR REPLACE PROCEDURE sp_just_commit()
AS
BEGIN
  COMMIT;
END;
```

**공격 시나리오 (`csql --no-auto-commit`):**
```sql
UPDATE tA SET x=42;       -- outer txn 의 미커밋 UPDATE
CALL sp_just_commit();    -- SP 내부에서 COMMIT
ROLLBACK;                 -- outer 가 undo 를 의도

SELECT x FROM tA;         -- 42 (기대값: 1)
```

**Expected:** `ROLLBACK` 이 outer 의 `UPDATE tA SET x=42;` 를 되돌려 `x=1` 이 되어야 함.

**Observed:** `x=42`. SP 내부의 `COMMIT;` 이 **outer 트랜잭션 컨텍스트 전체** 를 커밋했고, 이후 `ROLLBACK;` 은 남은 미커밋 변경이 없어 no-op 로 성공 반환.

### 정확한 실행 순서

1. Outer txn: `UPDATE tA SET x=42;` — row lock 획득, 미커밋
2. `CALL sp_just_commit();` — SP 가 bare `COMMIT;` 실행
3. CUBRID 는 **현재 transaction context 전체** 를 커밋 — outer 의 미커밋 UPDATE 포함
4. `ROLLBACK;` — 미커밋 변경이 없어 silent success
5. `SELECT x FROM tA;` → `42` (3 단계에서 이미 커밋된 값)

**에러 코드:** 없음. `CALL` 도 `ROLLBACK` 도 `Execute OK` 반환. 데이터 손상이 **사용자/애플리케이션에 보이지 않음**.

### 재현 빈도

- 동일 스크립트 3회 연속 실행, 3회 모두 재현.
- 동일 root cause 로 다른 시나리오도 재현:
  - `sp_update_and_commit()` (UPDATE + COMMIT in SP): outer session 의 prior 미커밋 UPDATE 가 SP 의 COMMIT 에 함께 묻혀 커밋됨
  - `sp_self_deadlock()` (UPDATE tA + COMMIT): SP 의 COMMIT 이 outer 의 tA=50 UPDATE 를 SP 의 tA=51 로 덮어쓰며 함께 커밋, 자기 자신과의 deadlock 도 발생하지 않음 (동일 세션 동일 lock set)

### Impact

- **데이터 원자성 침해**: 애플리케이션이 `try/catch + ROLLBACK` 패턴을 쓰더라도, CALL 된 SP 안에 `COMMIT` 이 하나만 있어도 예외 직전까지의 변경이 저장됨.
- **조용한 실패**: 에러 / warning 없음. 애플리케이션 로그에는 정상 rollback 으로 기록됨.
- **부분 커밋 시나리오**: "outer UPDATE → SP CALL → 예외 발생 → ROLLBACK" 경로에서 outer UPDATE 와 SP 내부 UPDATE 가 쪼개진 채로 저장될 수 있어 데이터 정합성 깨짐.
- **감사 / 재현 곤란**: 에러 로그가 없으므로 사후 추적이 어렵다.

### 비교 (타 DB 동작)

| DB | SP 내부 COMMIT (outer txn 존재) | 동작 |
|---|---|---|
| Oracle | 기본 불가 — `PRAGMA AUTONOMOUS_TRANSACTION` 필요 | AUTONOMOUS 이면 SP 트랜잭션만 COMMIT, outer 영향 없음 |
| PostgreSQL | PL/pgSQL procedure 내 `COMMIT` 은 SP 호출 시 outer txn 종료 요구 (함수 내부 불가) | 애플리케이션이 명시적으로 scope 제어 |
| MySQL | Function / Trigger 내 `COMMIT` 은 에러 (`ER_COMMIT_NOT_ALLOWED_IN_SF_OR_TRG`); Procedure 에서는 outer txn 이 영향받음 | 함수 / 트리거 수준 차단 |
| CUBRID (현재 11.4.5) | **Procedure 에서 제한 없음** — outer txn 조용히 커밋 | **트랜잭션 경계 불명확** |

### 참고 소스

| 영역 | 후보 파일 |
|---|---|
| PL/CSQL 실행 브리지 | `src/sp/` (JNI 브리지), `pl_engine/` (Java PL 서버) |
| COMMIT 디스패치 | `src/transaction/` — `tran_server_commit` / `log_commit` 경유 |
| SP CALL → COMMIT 전파 | `src/method/` (method/SP invocation) |

**후속 조사 제안:** SP 바디에서 `COMMIT;` 구문이 어떻게 파싱되고 실행되는지, 그리고 current transaction descriptor (TDES) 가 SP 호출 컨텍스트와 caller 사이에서 어떻게 공유 / 분리되는지를 확인.

### 재현 스크립트

`/tmp/bugbounty11455/overnight_r2/b3/sp_commit_test.sql` (예정 — b3 worker 가 남긴 아티팩트)

---

## Implementation

### 수정 방향 (권장: 옵션 2 → 옵션 1 단계 적용)

**Step 1 (단기): Active outer txn 에서 SP 내부 COMMIT/ROLLBACK 을 error 로 reject**

- `src/sp/` 의 COMMIT/ROLLBACK 디스패치 경로에, 호출 시점의 `tdes->trid` 가 outer caller 의 transaction 과 동일하면 `ER_SP_COMMIT_IN_NESTED_TXN` (신규 에러 코드) 을 raise.
- 기존 외부 transaction 이 없는 standalone SP 호출은 기존 동작 유지.

**Step 2 (장기): Autonomous transaction 도입**

- SP 선언 시 `PRAGMA AUTONOMOUS_TRANSACTION` (Oracle 호환) 또는 CUBRID 고유 구문으로 마킹.
- 마킹된 SP 는 자체 TDES 를 갖고 caller 의 TDES 와 격리.
- 마킹되지 않은 SP 는 Step 1 rule 적용 (COMMIT/ROLLBACK 금지).

### 주 수정 대상 (단기 수정)

| 파일 | 변경 내용 |
|---|---|
| `src/base/error_code.h` | `ER_SP_COMMIT_IN_NESTED_TXN` 신규 에러 코드 추가 |
| `src/compat/dbi_compat.h` | client-visible copy |
| `msg/en_US.utf8/cubrid.msg`, `msg/ko_KR.utf8/cubrid.msg` | 메시지 추가 |
| `ER_LAST_ERROR` | 업데이트 |
| `src/sp/` 또는 `pl_engine/` | SP 내부 COMMIT/ROLLBACK 시점에 nested txn detection + error raise |

### Acceptance Test (단기 수정 기준)

```sql
-- 기대 동작 (수정 후)
UPDATE tA SET x=42;
CALL sp_just_commit();  -- ERROR: COMMIT is not allowed in a stored procedure during an active transaction
ROLLBACK;
SELECT x FROM tA;       -- 1 (outer 의 UPDATE 가 올바르게 rollback)
```

Standalone CALL (outer txn 없음) 은 기존과 동일하게 동작:
```sql
-- outer txn 없음 (auto-commit mode 또는 COMMIT 직후)
CALL sp_just_commit();  -- OK (no outer txn to violate)
```

---

## A/C (Acceptance Criteria)

- [ ] 재현 시나리오: `UPDATE` → `CALL sp_just_commit()` → `ROLLBACK` → `SELECT` 결과가 원래 값(1) 으로 복원됨
- [ ] SP 내부 `COMMIT` 이 active outer txn 존재 시 명확한 에러 (신규 에러 코드) 를 raise
- [ ] SP 내부 `ROLLBACK` 도 동일 규칙 적용
- [ ] standalone SP 호출 (outer txn 없음) 은 기존 동작 유지 (regression 없음)
- [ ] 기존 SP 단위 테스트 / 정적 SQL 테스트 regression 없음
- [ ] 애플리케이션 관점에서 `ROLLBACK` 이 의도한 모든 변경을 되돌리는 원자성 계약이 복원됨
- [ ] 에러 메시지(en_US / ko_KR) 일관성 검증

---

## Remarks

- 11.4.5 internal test overnight 세션에서 발견 (FINDINGS_11.4.5.md BUG 5, line 361).
- 재현 100%, 3 회 연속 동일 결과.
- Worker: worker-b3 (R2-B3 deadlock test 부산물). 원 task 는 deadlock detection 검증이었으나 SP 자체 deadlock 시도 중 본 버그 발견.
- 장기 로드맵으로 **Autonomous Transaction** 기능 (Oracle 호환) 을 별도 티켓으로 발의 가능.
- Umbrella: CBRD-26730 (11.4.5 internal test findings).
- **Priority**: 권장 **Major** — 데이터 원자성 위반이며 silent 하므로 고객 장애로 이어질 경우 식별 / 복구 비용이 크다.
