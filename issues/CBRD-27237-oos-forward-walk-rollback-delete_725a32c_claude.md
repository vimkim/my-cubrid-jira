# [OOS] rollback 된 UPDATE 의 옛 OOS 체인을 vacuum 이 삭제해 살아있는 행이 손상됨

## Issue Triage

**이슈 수행 목적**: ROLLBACK 으로 복원된 행의 OOS (Out-of-row Storage — heap 의 큰 가변 컬럼을 별도 파일로 분리 저장하는 방식) 값이 vacuum 이후에도 그대로 읽히도록 한다.

**이슈 수행 이유**:

- **AS-IS (현재 동작 / 배경)**: OOS UPDATE 의 옛 체인 회수(forward-walk, `vacuum_forward_walk_reclaim_oos`, `src/query/vacuum_oos.cpp:223`)는 UPDATE 로그의 undo image (변경 전 행 모습을 로그에 남긴 불변 스냅샷) 만 근거로 삭제하며, 그 UPDATE 가 커밋됐는지 확인하지 않는다. ROLLBACK 된 UPDATE 에서는 복원된 살아있는 행이 바로 그 undo image 의 체인을 참조하므로, vacuum 이 살아있는 값을 지우게 된다.
- **TO-BE (목표 상태 / 기대 동작)**: rollback 된 UPDATE 의 undo image 는 OOS 체인 삭제 근거가 되지 않는다.
- **영향**: 잠재 데이터 손실 (develop 머지 차단 사유) — `feat/oos` 미출시라 고객 장애는 아직 없지만, UPDATE + ROLLBACK 뒤 vacuum 이 지나가면 커밋된 행의 OOS 값이 오류·경고 없이 판독 불가가 된다 (CBRD-26950 과의 차이는 Additional Information 참조).

소스 분석으로 도출한 이슈이며 런타임 재현은 아직 수행하지 않았다 (CBRD-26950 의 PoC (재현 실험) 워크로드에는 ROLLBACK 이 없어 거기서는 발현될 수 없었다).

**이슈 수행 방안**:

| 순위 | 후보 | 고려사항 |
|------|------|---------------------|
| 1 | CBRD-27230 정리 아키텍처로 함께 해소 — UPDATE 가 버린 체인을 명시하는 알림 로그를 커밋 조건부로 발행하고 forward-walk 를 제거 | 결함의 원인 경로 자체가 사라진다. 아키텍처 확정은 CBRD-27230 에서 진행 중이며, 예약만 되어 있는 `RVOOS_NOTIFY_VACUUM` (`src/transaction/recovery.h:207`, 현재 emitter 없는 no-op 슬롯) 재활용이 후보다 |
| 2 | 단기 개별 수정 — forward-walk 진입 전에 해당 트랜잭션의 커밋 여부를 확인하는 게이트 추가 | forward-walk 기계를 유지한 채 최소 수정. 로그만으로 커밋 여부를 판정하는 비용·방법 검토 필요 |

선택: TBD - 합의 미확인.

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다.

## Summary

- **변경 범위 / 영향**: 수정 대상은 `src/query/vacuum.c` 의 forward-walk 분기(`:3591`, `:3730`)와 `src/query/vacuum_oos.cpp`. SA_MODE 무관 — SA_MODE 도 vacuum 을 수행하지만, 비-SERVER_MODE 에서는 heap UPDATE 가 MVCC 연산이 아니어서 (`HEAP_UPDATE_IS_MVCC_OP` 가 상수 false, `src/storage/heap_file.c:165`) `RVHF_UPDATE_NOTIFY_VACUUM` 이 기록되지 않고, 옛 체인은 갱신 시점에 즉시 회수된다 (`heap_file.c:24190`). `feat/oos` 전용 결함이라 출시본 호환성 부담은 없다.

## Description

vacuum (어떤 트랜잭션에게도 더 이상 보이지 않는 옛 레코드 버전을 회수하는 백그라운드 프로세스) 의 OOS 회수 경로 가운데 forward-walk 만 현재 페이지 상태를 다시 읽지 않는다. heap 회수 경로는 라이브 레코드를 재확인해 rollback 된 연산이면 no-op 하며, 주석에도 그렇게 적혀 있다 ("... it was rollbacked and reused", `src/query/vacuum.c:1812-1814`). 반면 forward-walk 는 UPDATE 로그 레코드의 undo image 에서 옛 head OOS OID 를 꺼내 그대로 삭제한다.

이 전제가 ROLLBACK 과 충돌한다. 소스에서 확인한 사실 네 가지:

1. 로그 레코드는 append 시점에 vacuum 용 MVCC 연산 체인에 연결되고 (`prev_mvcc_op_log_lsa` 연결, `src/transaction/log_append.cpp:1389` 이하), rollback 은 보상 레코드를 덧붙일 뿐 이미 연결된 UPDATE 레코드를 체인에서 빼지 않는다.
2. `vacuum_process_log_record` (`src/query/vacuum.c:4079` 이하) 에는 커밋/abort 필터가 없다. dropped file (`:4220` 부근) 과 rcvindex (로그 레코드에 붙는 복구 루틴 태그) 화이트리스트 (`:4233-4241` — `RVHF_UPDATE_NOTIFY_VACUUM` 포함) 만 거른다.
3. ROLLBACK 시 `RVHF_UPDATE_NOTIFY_VACUUM` 의 undo 함수 `heap_rv_undo_update` (`src/transaction/recovery.c:352-357`) 가 pre-image 를 라이브 레코드로 물리 복원한다 — OOS inline stub (heap 레코드 안에 남는 16 바이트 참조) 까지 바이트 동일하게. 같은 rollback 에서 UPDATE 가 새로 쓴 체인은 `RVOOS_INSERT` 의 undo (`oos_rv_redo_delete`, `src/transaction/recovery.c:875-880`) 로 제거된다. 결과적으로 undo image 가 가리키는 옛 체인이 곧 살아있는 행의 체인이 된다.
4. abort 한 트랜잭션의 MVCCID (트랜잭션별 MVCC 식별자) 도 커밋된 것과 같은 방식으로 은퇴하고 (더 이상 활성으로 간주되지 않음), oldest visible MVCCID 가 그 뒤로 전진하면 해당 로그 블록 (vacuum 이 로그를 소비하는 고정 크기 단위) 이 vacuum worker 에 배포된다. worker 는 같은 undo image 에서 같은 head OID 를 재유도한다.

사고 시퀀스:

```
1. UPDATE (OOS 행)   → 새 체인 기록, RVHF_UPDATE_NOTIFY_VACUUM 로그 (undo = pre-image)
2. ROLLBACK          → pre-image 물리 복원 (stub 그대로), 새 체인만 undo 로 제거
                       ★ 옛 체인 = 살아있는 행이 참조하는 체인
3. aborted MVCCID 은퇴 → 블록이 vacuum 에 배포
4. forward-walk 가 undo image 의 head OID 로 삭제
                       ★ 살아있는 행의 체인 삭제. 오류·경고 없음
```

기존 분석과의 관계: CBRD-26668 의 rollback 검토는 abort 진행 중 창 — visibility gate 와 abort 순서(`log_rollback` 이 `logtb_complete_mvcc` 보다 먼저) — 을 다뤄 vacuum 이 abort 도중에 끼어들 수 없음을 보였다. 그러나 abort 완료 후 창, 즉 MVCCID 가 은퇴한 뒤에도 같은 undo image 가 체인에 남아 있는 구간은 그 논증의 범위 밖이고, 이 구간에서 4 단계를 막는 메커니즘을 소스에서 찾지 못했다.

## Test Build

`feat/oos` @ `725a32c6e` (`origin/develop` 머지 포함, 2026-08-13 소스 분석 기준).

## Repro

분석에서 도출한 예상 시퀀스다 (debug 빌드, SERVER_MODE 기준).

```sql
-- 1. OOS 행 생성 후 커밋 (레코드가 OOS 이관 게이트 DB_PAGESIZE/4 —
--    src/storage/heap_file.c:12345, 현 16KB 페이지 기준 4,086 바이트 —
--    를 넘도록 5000 바이트 VARBIT 사용)
CREATE TABLE t (id INT PRIMARY KEY, b BIT VARYING);
INSERT INTO t VALUES (1, CAST(REPEAT('AA', 5000) AS BIT VARYING));
COMMIT;

-- 2. UPDATE 후 ROLLBACK
UPDATE t SET b = CAST(REPEAT('BB', 5000) AS BIT VARYING) WHERE id = 1;
ROLLBACK;

-- 3. vacuum 은 고정 크기 로그 블록 단위로 동작하므로, 해당 블록이 마감·배포되도록
--    별도 filler 테이블에 INSERT + COMMIT 을 수백 회 반복하고 대기
--    (블록 마감과 oldest visible MVCCID 전진 유도)

-- 4. 행 재조회
SELECT id, (b = CAST(REPEAT('AA', 5000) AS BIT VARYING)) FROM t WHERE id = 1;
```

## Expected Result

4 단계에서 `1, 1` — ROLLBACK 으로 복원된 원래 값이 그대로 읽힌다.

## Actual Result

(분석 예측 — 미실행) forward-walk 가 지나간 뒤에는 stub 이 가리키는 OOS 슬롯이 비어 있어 행 판독이 실패한다. CBRD-26950 재현에서 관찰된 증상 계열 (slot not allocated 오류 등) 로 예상한다.

## Additional Information

- CBRD-26950 — 같은 "forward-walk 가 로그 내용만 믿는다" 구조에서 발생하는 데이터 손실이지만 발동 조건이 다르다: 그쪽은 vacuum 블록 중단·재시도가 있어야 발현되고, 본 이슈는 재시도 없이 단일 정상 주행에서 발생한다. CBRD-26950 의 수정안인 generation stamp 로도 막히지 않는다 — rollback 케이스에서는 undo image 와 라이브 stub 의 (head OID, generation) 이 동일해 등가 비교가 삭제를 허용하기 때문이다.
- CBRD-27230 — 변경 없는 OOS 값 중복 적재 방지. 그쪽에서 검토 중인 알림 로그 아키텍처가 채택되면 forward-walk 자체가 제거되어 본 결함 경로도 함께 사라진다 (Issue Triage 방안 후보 1).
- CBRD-26668 — vacuum-OOS 통합 원 이슈. rollback 검토가 abort 진행 중 창만 다룬 경위는 Description 참조.
