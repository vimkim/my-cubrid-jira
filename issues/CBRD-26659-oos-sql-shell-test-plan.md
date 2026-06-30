# [OOS] [M2] 개발자 SQL/Shell 테스트 시나리오 계획

## Issue Triage

**이슈 수행 목적**: CBRD-26659 에서 작성할 OOS 개발자 SQL/Shell 테스트 범위를 확정한다. 실제 테스트 파일은 CUBRID testcase 관례에 맞춰 `cubrid-testcases` 쪽에 작성할 수 있도록 시나리오, 우선순위, harness 분리를 먼저 고정한다.

**이슈 수행 이유**:

- **현재 동작 / 배경**: CBRD-26659 는 M2 의 "개발자 SQL/Shell 테스트 생성" sub-task 이지만 본문 스펙이 비어 있다. 현재 OOS (Out-of-row Storage - heap 의 큰 가변 컬럼을 외부 OOS 파일로 분리하는 저장 방식) 트리거는 `DB_PAGESIZE/4` 를 넘는 레코드에서 `OR_OOS_INLINE_SIZE`(16B) 초과 가변 컬럼을 큰 값부터 내보내는 방식인데, 기존 임시 테스트 일부는 `DB_PAGESIZE/8` / 512B 기준을 전제로 한다.
- **영향**: QA 실패 위험 - SQL 테스트가 stale threshold 를 기준으로 작성되면 release regression 에서는 OOS 경로를 실제로 밟지 않았는데도 통과할 수 있다.

**이슈 수행 방안**: 사용자 인용: "I need to write sql test scenarios in /home/vimkim/gh/tc/cubrid-testcases as feat/oos branch." 이 요청에 맞춰 `cubrid-testcases` 의 SQL, isolation, shell harness 별로 시나리오를 나누고, C++ SQL unit test 는 참고 자료로만 사용한다. 정확한 파일 작성은 이 계획 확인 후 진행한다.

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: 대상 워크트리는 `/home/vimkim/gh/tc/cubrid-testcases` 다. 일반 SQL 회귀 테스트, isolation test, shell test 를 모두 건드릴 수 있으나 엔진 소스와 사용자 SQL 스펙은 바꾸지 않는다. 로컬 testcase 브랜치는 확인 시점에 `feature/oos-m2` 였고, 사용자 요청의 기준 브랜치는 `feat/oos` 다.

---

## Description

CBRD-26357 은 큰 컬럼을 heap 밖 OOS 파일에 분리해 불필요한 디스크 I/O 를 줄이는 epic 이다. CBRD-26583 M2 는 운영 품질 확보와 `develop` 머지를 목표로 하며, CBRD-26659 는 그 안에서 개발자 SQL/Shell 테스트를 맡은 sub-task 다.

현재 참고 가능한 SQL 성격 테스트는 `/home/vimkim/gh/cb/oos-storage/unit_tests/oos/sql` 아래 C++ Google Test 로 존재한다. 이 테스트들은 parser, executor, heap/OOS 경로를 지나므로 시나리오 발굴에는 유용하지만, CUBRID testcase repo 의 `.sql` / `.answer` 관례는 아니다. 또한 일부 값은 현재 OOS gate 보다 작아 단일 컬럼만으로는 OOS demotion 을 보장하지 못한다.

이번 계획의 기준은 다음과 같다.

| 기준 | 결정 |
|------|------|
| 데이터 타입 | 크기 예측이 가능한 `BIT VARYING` 사용. 문자열은 압축 때문에 OOS gate 테스트의 기준값으로 쓰지 않는다. |
| 값 생성 | `CAST(REPEAT('AA', N) AS BIT VARYING)` 또는 기존 testcase 관례의 `REPEAT(X'AA', N)` 중 실행 결과가 안정적인 형태를 선택한다. |
| 크기 확인 | `LENGTH` 는 bit 길이를 반환하므로 gate 검증 설명에는 쓰지 않는다. `.answer` 에서는 `DISK_SIZE` 또는 값 equality 를 우선 사용한다. |
| 물리 placement | release SQL 만으로 어떤 컬럼이 OOS 로 갔는지는 직접 볼 수 없다. largest-first placement 검증은 debug `oos.log` 또는 엔진 unit test 로 분리한다. |
| 임계치 | 현재 기준은 `DB_PAGESIZE/4` record gate 와 `OR_OOS_INLINE_SIZE`(16B) column floor 다. `DB_PAGESIZE/8` / 512B 는 과거 M1 기준으로만 언급한다. |

> **요지**: CBRD-26659 의 SQL 테스트는 "OOS 파일에 실제로 들어갔는지" 를 release SQL 로 증명하려 들기보다, OOS demotion 이 필요한 크기의 레코드에서 값 round-trip, update/delete/rollback, raw-copy 계열 경로가 깨지지 않는지 반복 검증해야 한다. placement 자체는 별도 debug test 가 맡는다.

## Specification Changes

N/A. 이 이슈는 테스트 계획과 테스트 파일 작성 범위를 정의한다. 사용자 SQL 문법, OOS 디스크 포맷, system parameter 는 변경하지 않는다.

## Implementation

### 작성 위치

| 테스트 방식 | 계획 위치 | 목적 |
|-------------|-----------|------|
| SQL | `/home/vimkim/gh/tc/cubrid-testcases/sql/_36_guava/cbrd_26659/cases/*.sql` 및 `answers/*.answer` | 단일 세션에서 결정적으로 검증 가능한 OOS round-trip / DDL / DML 회귀 |
| Isolation | `/home/vimkim/gh/tc/cubrid-testcases/isolation/.../issues/cbrd_26517_oos` 또는 `cbrd_26659_oos` | 두 세션 MVCC visibility, lock conflict, snapshot old OOS read |
| Shell | `/home/vimkim/gh/tc/cubrid-testcases/shell/.../cbrd_26659_oos` | 서버 재시작, crash recovery, vacuum 유도, debug log 확인처럼 SQL 단독으로 안 되는 흐름 |

### SQL 시나리오 행렬

| 우선순위 | 파일 후보 | 검증 시나리오 | 핵심 SQL 형태 | 기대 검증 |
|----------|-----------|---------------|---------------|-----------|
| P0 | `01_oos_basic_roundtrip.sql` | INSERT 후 SELECT, `DB_PAGESIZE/4` 를 확실히 넘는 레코드에서 OOS value round-trip | `vc1=3000B`, `vc2=2000B` 이상 조합 | `DISK_SIZE(vc1)`, `DISK_SIZE(vc2)`, 값 equality 가 모두 원본과 일치 |
| P0 | `02_oos_update_rollback.sql` | OOS 컬럼 UPDATE 후 COMMIT/ROLLBACK 결과 | 원본 `AA`, 갱신 `BB`, rollback 후 원본 비교 | rollback 이 이전 OOS OID 를 통해 원본 값을 정상 복원 |
| P0 | `03_oos_delete_rollback.sql` | DELETE 후 COMMIT/ROLLBACK visibility | 삭제 전 OOS row, rollback 후 equality 재확인 | DELETE rollback 후 OOS 값이 손상 없이 다시 보임 |
| P0 | `04_oos_multichunk.sql` | 한 컬럼이 여러 OOS page chunk 로 나뉘는 값 | 32KB, 64KB 급 `BIT VARYING` | 대형 값의 `DISK_SIZE` 와 equality 가 유지 |
| P0 | `05_oos_raw_copy_paths.sql` | CTAS / `INSERT ... SELECT` 로 raw recdes 계열 경로 검증 | OOS source table 에서 target table 생성/삽입 | 대상 table 에서도 값 equality 유지. 해석되지 않은 OOS OID 노출 방지 |
| P1 | `06_oos_boundary_and_floor.sql` | record gate 와 column floor 주변 | 16B 이하 컬럼, 500B 컬럼 여러 개, 4KB 아래/위 레코드 | 작은 컬럼과 mid-size 컬럼 조합이 모두 정상 round-trip |
| P1 | `07_oos_ddl.sql` | ALTER ADD/DROP COLUMN, DROP/CREATE 재사용, TRUNCATE 후 재삽입 | OOS row 삽입 뒤 schema 변경 | 기존 값 유지, 삭제/재생성 후 새 값 정상 |
| P1 | `08_oos_index_scan.sql` | index predicate 로 row 를 찾고 OOS 컬럼을 읽는 경로 | `idx_col` index + OOS column | index scan 대상 row count 와 OOS 값 equality 유지 |
| P1 | `09_oos_null_empty.sql` | NULL, empty `BIT VARYING`, NULL <-> OOS update | NULL row 와 큰 row 혼합 | NULL 상태와 큰 값 상태가 서로 오염되지 않음 |
| P1 | `10_oos_bigone_reject.sql` | OOS + bigone 동시 사용 거부 | OOS 후보 가변 컬럼 + 큰 fixed `BIT(n)` filler | `ER_HEAP_OOS_OVERPASS_MAXOBJ_SIZE` 계열 에러가 발생하고 row 가 저장되지 않음 |
| P2 | `11_oos_bulk_stress.sql` | 100~1000 row bulk insert/update | 서로 다른 byte pattern 반복 | count, 집계값, 최종 값 검증 |

### Isolation 시나리오

기존 untracked isolation 테스트는 `cbrd_26517_oos` 아래 이미 존재한다. 다만 여러 파일이 `1700B` 와 `DB_PAGESIZE/8` 기준을 설명에 담고 있으므로, 현재 gate 에 맞게 조정하거나 CBRD-26659 에서 새 파일로 재작성해야 한다.

| 우선순위 | 시나리오 | 필요한 조정 |
|----------|----------|-------------|
| P0 | READ COMMITTED 에서 C1 uncommitted UPDATE, C2 old value read | 단일 `1700B` 값 대신 `3000B + 2000B` 조합 또는 `5000B` 이상 값으로 OOS gate 를 확실히 넘긴다. |
| P0 | REPEATABLE READ 에서 C1 committed UPDATE 후 C2 old snapshot read | C2 가 old OOS OID 를 따라 원본 값을 읽는지 equality 로 확인한다. |
| P0 | DELETE visibility | C1 이 OOS row 를 delete 해도 C2 snapshot 에서는 old value 가 정상이어야 한다. |
| P1 | same-row update conflict | lock conflict 자체와 OOS value 보존을 분리해서 answer 를 안정화한다. |
| P1 | different-row concurrent update | 서로 다른 OOS row 의 값이 섞이지 않는지 최종 equality 로 확인한다. |
| P1 | multi-chunk visibility | 20KB 이상 값으로 old/new multi-chunk chain 을 모두 읽어 본다. |

### Shell 시나리오

| 우선순위 | 시나리오 | Shell 로 분리하는 이유 |
|----------|----------|------------------------|
| P0 | COMMIT 후 서버 재시작 | SQL runner 한 파일 안에서는 서버 stop/start 를 자연스럽게 검증하기 어렵다. |
| P0 | uncommitted INSERT/UPDATE crash recovery | `kill -9` 또는 강제 종료 후 recovery redo/undo 확인이 필요하다. |
| P1 | DROP TABLE 후 OOS file cleanup smoke | SQL 에서는 FILE_OOS 존재 여부를 직접 볼 수 없으므로 파일/로그 관찰이 필요하다. |
| P1 | vacuum 후 old OOS cleanup smoke | vacuum 유도와 재시도, 장시간 대기, 로그 확인이 필요하다. |
| P2 | debug `oos.log` 기반 largest-first placement | release SQL 결과는 logical value 만 보이므로 placement 는 debug log 의 `oos_insert ... src.size=` 로 확인한다. |

### 제외하거나 별도 이슈로 둘 항목

| 항목 | 이유 |
|------|------|
| OOS compression | 현재 M2 구현 범위가 아니다. 향후 type serialization layer 쪽 결정 후 별도 테스트가 필요하다. |
| OOS OID reuse | M3 취소 후 future improvement 로 밀렸다. 현재 UPDATE 는 새 OOS OID 를 만든다는 전제를 테스트한다. |
| replication full matrix | CBRD-26659 에 smoke 를 둘 수는 있으나, master/slave OOS OID 는 다를 수 있으므로 값 equality 기준의 별도 HA test 로 분리하는 편이 맞다. |
| 물리 page count exact assertion | `spacedb`/`diagdb` 가 OOS 공간을 release build 에서 충분히 보여주지 못한다. debug 또는 engine test 로 넘긴다. |

## Acceptance Criteria

- [ ] SQL 테스트는 `BIT VARYING` 을 사용하고, OOS trigger 설명에 `DB_PAGESIZE/4` 와 `OR_OOS_INLINE_SIZE`(16B) 를 기준으로 적는다.
- [ ] 일반 SQL `.answer` 는 값 equality, `DISK_SIZE`, row count 처럼 release build 에서 안정적인 출력만 기대값으로 둔다.
- [ ] 두 세션이 필요한 MVCC/lock 테스트는 SQL 회귀 테스트가 아니라 isolation test 로 분리한다.
- [ ] restart/crash/vacuum/debug-log 테스트는 shell test 로 분리한다.
- [ ] 기존 `1700B` / `DB_PAGESIZE/8` / 512B 설명을 새 테스트에 복사하지 않는다.
- [ ] C++ `unit_tests/oos/sql` 의 시나리오는 참고하되, 크기와 예상 출력은 현재 OOS spec 기준으로 다시 산정한다.

## Definition of done

- [ ] `sql/_36_guava/cbrd_26659/cases` 와 `answers` 에 P0 SQL 파일이 모두 작성돼 CTP SQL runner 에서 통과한다.
- [ ] isolation P0 파일이 현재 gate 크기로 갱신되거나 새 CBRD-26659 경로에 작성돼 통과한다.
- [ ] shell P0 파일이 restart/crash recovery smoke 를 검증한다.
- [ ] P1/P2 항목은 구현 여부를 체크리스트로 남기고, 범위 밖 항목은 별도 JIRA 후보로 분리한다.

## Remarks

### 참고한 자료

| 자료 | 사용한 내용 |
|------|-------------|
| CBRD-26357 | OOS 전체 목표: 큰 컬럼을 heap 밖으로 분리해 불필요한 I/O 를 줄임 |
| CBRD-26583 | M2 목표: 운영 품질 확보, develop 머지, CBRD-26659 를 테스트 sub-task 로 포함 |
| CBRD-26659 | 개발자 SQL/Shell 테스트 생성 sub-task. 본문 스펙은 없음 |
| `/home/vimkim/gh/cubrid-oos-context/OOS-CONTEXT.md` | 현재 OOS gate, largest-first demotion, MVCC/vacuum invariants, test principles |
| `/home/vimkim/gh/cb/oos-storage/unit_tests/oos/sql` | CRUD, update/delete, txn, boundary, DDL, eager cleanup 시나리오 후보 |

### 사전 검토 결과

| 질문 | 결론 |
|------|------|
| release SQL 로 OOS placement 를 직접 검증할 수 있는가? | 아니다. logical value 만 안정적으로 보이므로 placement 는 debug log 또는 engine test 로 둔다. |
| 기존 C++ 테스트의 `1024B`, `1700B` 값을 그대로 옮겨도 되는가? | 아니다. 현재 `DB_PAGESIZE/4` gate 에서는 단일 1700B 값이 OOS 를 보장하지 않는다. |
| CBRD-26659 의 산출물을 SQL 하나로 끝낼 수 있는가? | 아니다. MVCC 두 세션, crash recovery, restart 는 isolation/shell 로 나눠야 한다. |
