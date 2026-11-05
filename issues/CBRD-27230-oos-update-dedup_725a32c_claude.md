# [OOS] 변경 없는 OOS 값 중복 적재 방지

**한 줄 요약**: 미할당 OOS 컬럼의 chain 재사용을 구현하되, 버린 chain의 알림은 승인된 commit 후 postpone(A')을 사용한다. 재사용 전체의 구현 일정은 PR #7990 develop 병합 이후로 유지한다.

## Issue Triage

**이슈 수행 목적**: UPDATE 문이 할당하지 않은 OOS (Out-of-row Storage — heap 의 큰 가변 컬럼을 별도 파일로 분리 저장하는 방식) 컬럼에 대해, 새 레코드 버전이 기존 OOS 값 체인을 그대로 재사용하도록 한다.

**이슈 수행 이유**:

- **AS-IS (현재 동작 / 배경)**: UPDATE 는 할당 여부와 무관하게 행의 모든 OOS 값을 다시 읽고(`oos_read`) 새 체인으로 다시 적재한다(`oos_insert`). 미할당 컬럼의 신호는 `heap_attrinfo_set_uninitialized` (`src/storage/heap_file.c:12156`) 가 값을 즉시 읽어들이는 순간 사라져, 이후 쓰기 경로는 할당된 값과 구분하지 못한다. 미할당 OOS 컬럼 하나당 `oos_read` 1회 + `oos_insert` 1회 + vacuum 전까지 남는 죽은 체인 1개가 발생하고, 복제 로그도 값 전체를 매번 재전송한다.
- **TO-BE (목표 상태 / 기대 동작)**: 미할당 OOS 컬럼의 inline stub (heap 레코드 안의 참조 — 현재 사양의 24 바이트) 을 새 레코드 버전에 그대로 복사해 체인을 재사용하고, 할당된 컬럼이 버린 옛 체인만 커밋 시점의 알림 로그로 vacuum 에 전달해 삭제한다.
- **영향**: 성능 저하 — 큰 OOS 값이 있는 행은 inline 컬럼 하나만 바꿔도 OOS 값 전체를 재적재·재복제한다. UPDATE 가 잦은 워크로드에서 I/O·복제 트래픽·OOS 파일 공간이 값 크기에 비례해 낭비된다.

**이슈 수행 방안** (확정 사항 — 계약 상세는 Specification Changes 참조):

1. **재사용 규칙**: "변경 없음" = UPDATE 문에 할당되지 않음. 값 비교는 하지 않는다 (비교하려면 없애려는 `oos_read` 가 필요).
2. **정리 아키텍처**: UPDATE 가 버린 체인 목록을 알림 로그 레코드로 vacuum 에 전달한다. 실제 `RVOOS_NOTIFY_VACUUM` 생산자·소비자와 필요한 복구 인덱스를 함께 정의한다. CBRD-27841의 미사용 예약 항목 정리와 구현 기준 revision을 대조한다.
3. **커밋 조건부 발행**: UPDATE가 버린 chain을 postpone에 기록하고 commit 확정 뒤 알림을 발행한다(A'). rollback된 변경의 postpone은 실행하지 않는다. CBRD-27237의 수명·회수 수정과 정합성을 맞춘다.
4. **forward-walk 제거**: UPDATE 로그의 undo image (변경 전 행 모습을 로그에 남긴 불변 스냅샷) 에서 옛 체인을 재유도해 삭제하던 `vacuum_forward_walk_reclaim_oos` 경로는 게이트가 아니라 제거한다. DELETE의 최종 회수 책임은 REMOVE에 두고, 실제 chunk 회수는 ADR-0008의 확정 뒤 postpone·redo-only 방식에 맞춘다.
5. **선행 필수**: CBRD-26950 (identity stamp — 슬롯 재사용을 감지하는 8 바이트 LOG_LSA). 두 이슈는 직교하며 모두 필요하다.
6. **소유권 불변식 교체**: "OOS 값 체인은 그것을 참조하는 가장 새로운 논리적 레코드 버전이 소유한다. 옛 버전들은 undo image 를 통한 차용 참조만 갖는다. 체인 해제는 정확히 한 번 — 체인을 버린 UPDATE 의 커밋(알림 레코드) 또는 vacuum 의 행 마지막 버전 제거(REMOVE 경로) 로만 일어난다. undo image 는 삭제 근거가 아니다."
7. **복제 프로토콜 변경 포함**: 재사용 컬럼용 marker 아이템 (재사용 사실만 표시하는 자리 항목) 과 replica 측 보정을 본 이슈 범위에 포함한다 (별도 이슈로 분리하지 않음).

---

## Meeting Decision (2026-11-05)

2026-11-05 공유된 미팅 결과에 따라 UPDATE 회수 알림은 commit 후 postpone(A')으로 확정했다. 아래의 기존 commit 전 hook 설계를 대체한다. postpone 시 MVCCID 전달·vacuum 입력과 복구 재실행은 새 구현에서 검증할 의무다.

[CBRD-27237](https://jira.cubrid.org/browse/CBRD-27237)·[CBRD-27781](https://jira.cubrid.org/browse/CBRD-27781)의 공통 수명·회수 수정과, 이 이슈의 미할당 컬럼 재사용·복제 marker 전체는 완료 범위를 구분한다. **이 이슈의 전체 구현은 PR #7990의 develop 실제 병합 이후 진행한다는 기존 일정을 유지한다.**

기존 문서의 generation은 현재 사양의 identity stamp를 뜻한다. 현재 inline stub은 head OOS OID 8B, 전체 길이 8B, packed identity stamp 8B의 24B다. 이 규격 정정과 방식 승인은 엔진 구현 완료를 뜻하지 않는다.

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다.

## Summary

- **변경 범위 / 영향**: 쓰기 경로 `src/storage/heap_file.c` (`heap_attrinfo_set_uninitialized`, disk layout, stub 기록), vacuum `src/query/vacuum.c` + `src/query/vacuum_oos.cpp` (forward-walk 제거, 알림 소비 신설), 커밋·postpone·복구 경로 `src/transaction/log_manager.c` 및 관련 로그 코드, 복제 `src/transaction/locator_sr.c` + `src/broker`/applylogdb 경로 (`log_applier.c`). SA_MODE의 옛/새 stub 차집합으로 공유 chain을 보존하는 규칙은 유지하고, 실제 회수 시점은 ADR-0008의 commit 뒤 postpone에 맞춘다. `feat/oos` 전용 변경이라 출시본 호환성 부담은 없다.

## Description

### 배경 — 왜 지금까지 항상 새 체인이었나

M1 설계는 "각 OOS 값 체인은 정확히 하나의 논리적 레코드 버전이 소유한다"는 불변식 위에 서 있다. UPDATE 는 항상 새 체인을 만들고, vacuum 의 forward-walk 는 UPDATE 로그의 undo image 에서 옛 체인의 head OOS OID 를 꺼내 삭제한다 (`vacuum_forward_walk_reclaim_oos`, `src/query/vacuum_oos.cpp:223`). 이 구조는 옛/새 참조가 다르다고 가정했지만, rollback 뒤 복원된 chain을 지우는 CBRD-27237 결함이 있어 undo image만으로 삭제를 결정할 수 없다.

체인을 재사용하는 순간 이 전제가 깨진다. 미할당 컬럼의 체인은 옛 버전과 새 버전이 공유하는데, forward-walk 는 undo image 에 등장하는 모든 체인을 지우므로 살아있는 행이 참조하는 체인까지 삭제한다 — 조용한 데이터 손실이다. 즉 재사용의 실제 비용은 쓰기 경로가 아니라 **정리(cleanup) 아키텍처의 교체** 다.

### PostgreSQL 대비 — 무엇이 이전되고 무엇이 안 되나

PostgreSQL TOAST 는 UPDATE 시 변경 없는 값의 포인터를 그대로 재사용하며, generation id 도 별도 로그도 없다. 이유는 결정 시점이다: PG 는 UPDATE 시점에 옛/새 이미지를 모두 손에 들고 "버린 값만 삭제" 를 그 자리에서 결정한다. CUBRID OOS 는 MVCC 때문에 삭제를 vacuum 으로 미루는데, vacuum 은 undo image 만 볼 수 있어 "무엇을 버렸나" 를 알 수 없다. 본 이슈의 알림 레코드는 정확히 그 UPDATE 시점 결정을 vacuum 이 소비할 수 있게 영속화한 것이다.

### 후보 아키텍처 비교

| 순위 | 후보 | 판정 / 고려사항 |
|------|------|---------------------|
| 1 | **알림 로그** — UPDATE 가 버린 체인 목록을 커밋 시 로그로 남기고 vacuum 이 소비 (채택) | forward-walk 와 undo image 파싱 기계 전체가 제거된다. 엔진에서 복구 외 목적으로 로그 바이트에서 heap 레코드 이미지를 재구성하는 유일한 지점이 사라지는 것이 정확성 이득만큼 큰 단순화다 |
| 2 | vacuum 시점 generation 비교 — undo image 의 stub 과 청크의 generation 이 같으면 삭제 | **성립 불가.** 재사용된 체인은 undo image 와 live stub 양쪽에 같은 (head OID, generation) 을 가지므로, 등가 비교는 지우면 안 되는 바로 그 경우에 삭제를 지시한다. 보완하려면 UPDATE 마다 재스탬프(체인당 OOS 페이지 쓰기 추가) 또는 vacuum 의 live 레코드 방문이 필요해 비용·복잡도가 역전된다 |
| 3 | pass-2 차집합 — vacuum 2 pass 가 이미 잡고 있는 live 레코드와 undo image 의 차집합 계산 | 동작은 하나 알림 로그보다 엄격히 복잡하고, 제거 대상인 로그 파싱 기계를 그대로 유지한다 |

## Specification Changes

### 1. 재사용 의미론

- UPDATE 문에 할당되지 않은 OOS 컬럼: 옛 레코드 버전의 24 바이트 stub (head OOS OID 8B + 전체 길이 8B + packed identity stamp 8B, CBRD-26950) 을 새 레코드 버전에 바이트 그대로 복사한다. `oos_read` 없음, `oos_insert` 없음. generation 도 그대로 복사한다 — 새로 발급하면 살아남은 체인을 이후 어떤 `oos_delete` 도 지우지 못하는 영구 누수가 된다.
- 할당된 OOS 컬럼: 기존대로 demote·적재하고, 버린 옛 체인이 알림 레코드의 삭제 목록에 오른다.
- 할당되었지만 값이 같은 컬럼은 재사용하지 않는다 (값 비교 없음 — 범위 밖).

### 2. 알림 레코드 `RVOOS_NOTIFY_VACUUM`

- **내용**: 실제로 버린 chain의 OOS VFID, head OOS OID와 기대 identity stamp를 postpone 의도로 기록한다. 버린 chain이 없으면 회수 알림을 남기지 않는다. MVCC 가시성 판정에 필요한 원래 UPDATE의 MVCCID 전달 방법을 명시하고 검증한다.
- **발행**: 문장·savepoint·트랜잭션 rollback은 해당 postpone을 취소한다. commit이 확정된 뒤 postpone이 `RVOOS_NOTIFY_VACUUM`을 남긴다. `logtb_complete_mvcc` 이전의 단순 commit hook 발행은 채택하지 않는다.
- **MVCC·복구**: 현행 commit 경로는 postpone 전에 MVCC 정보를 완료하므로, 명시적 MVCCID로 알림을 append하고 vacuum 입력을 구성할 경로를 구현해야 한다. commit-with-postpone 이후 crash와 복구 중 postpone 재실행에서도 알림을 잃거나 취소된 UPDATE를 회수하지 않는지 확인한다.
- **소비**: vacuum은 알림의 chain을 읽을 수 있는 오래된 snapshot이 끝난 뒤 ADR-0008의 redo-only 회수기로 정리한다. head 및 링크 identity를 검사하고 tail부터 삭제하며 오류·crash 뒤 남은 chunk를 재시도한다. callback 등록, recovery index, MVCC 및 TDE 분류를 실제 생산자·소비자와 함께 검증한다.

### 3. 제거 및 불변 항목

- 제거: `vacuum_forward_walk_reclaim_oos` 전체와 undo image 파싱 부속 (레코드 타입 가드, 로그 페이지 회전 대비 사본, undo 언패킹 화이트리스트의 OOS 태그들, `RVHF_DELETE_NEWHOME_NOTIFY_VACUUM` 특례). 해당 UPDATE 계열 rcvindex 는 일반 MVCC UPDATE 로 환원된다.
- DELETE의 역할: MVCC DELETE는 오래된 reader를 위해 chain을 유지한다. REMOVE가 heap 레코드 제거와 회수 의도를 같은 sysop에 기록하고, sysop commit 뒤 redo-only 회수한다. UPDATE 알림을 중복 생성하지 않는다. SA/non-MVCC eager 경로도 transaction commit 뒤 회수한다.

### 4. 복제 프로토콜

현재 복제 로그는 값이 아니라 OOS 값당 `RVREPL_OOS_INSERT` 아이템 (master 의 물리 `RVOOS_INSERT` WAL 레코드를 가리키는 LSA) 을 실어 보내고, replica 는 그 WAL 바이트로 자기 자신의 `oos_insert` 를 수행한 뒤 레코드의 OID 를 바꿔 쓴다 (`src/transaction/locator_sr.c:5287`, `:14166`). 아이템 수와 stub 수가 어긋나면 replica 는 오류로 적용을 중단한다 (`:14179`, `:14234`) — 즉 dedup 을 master 만 바꾸면 HA 가 시끄럽게 (조용한 불일치 없이) 멈춘다. 변경 사항:

- **marker 아이템**: 재사용된 컬럼 자리에 "이 컬럼은 기존 체인 재사용" 을 뜻하는 아이템을 넣어 위치·개수 계약을 유지한다.
- **replica 측 보정 (fixup)**: 재사용 컬럼의 OID·generation 은 replica 자신의 직전 행 버전 stub 에서 가져온다. 그 버전은 이미 fetch 하고 있으나 (`locator_sr.c:6943`) OOS 확장이 켜진 fetch 라 stub 원본이 필요한 이 용도에는 비확장 fetch 로 전환해야 한다.
- **replica 측 vacuum**: replica 도 같은 알림 레코드 구조로 동작하므로 master 와 동일한 보호를 받는다.
- **applylogdb**: sql.log 재구성 경로 (`log_applier.c:3845`) 가 재사용 컬럼을 처리하도록 갱신한다.

## Implementation

아래는 승인된 방향의 후속 구현 순서다. 코드 변경과 테스트 통과는 아직 완료하지 않았다.

1. 미할당 OOS 컬럼은 전체 24B stub을 보존하고, 할당된 컬럼은 새 chain과 실제로 버린 옛 chain을 구분한다.
2. heap UPDATE의 변경과 함께 버린 chain의 postpone 의도를 기록한다. 부분 rollback과 transaction rollback에서 그 의도가 취소되게 한다.
3. commit 확정 뒤 알림을 남기고, 명시적 MVCCID 전달과 vacuum 입력·restart 재실행을 연결한다.
4. vacuum의 undo image forward-walk를 제거하고, 알림·REMOVE·eager 경로를 승인된 회수기와 연결한다.
5. replica 재사용 marker·replica-local stub 보정 및 applylogdb를 함께 구현한다. master의 물리 OOS 참조를 replica 저장 참조로 사용하지 않는다.
6. CBRD-27237·CBRD-27781 수정이 반영된 같은 기준에서 rollback·snapshot·정상 회수·재시작·HA 검증과 성능 비교를 수행한다.

기존 `725a32c6e`의 파일·줄 근거는 과거 분석 범위다. 실제 구현 시작 시 최신 revision으로 다시 확인하며, 이 이슈의 재사용 전체는 develop 병합 이후 착수한다.

## Acceptance Criteria

- [ ] inline 컬럼만 할당하는 UPDATE 후, OOS 컬럼의 head OOS OID·generation 이 이전 버전과 동일하다 (debug oos.log 로 확인) — 값 판독 정상
- [ ] OOS 컬럼을 할당하는 UPDATE 후, 커밋 → vacuum 완료 시 옛 체인이 회수되고 새 체인은 유지된다
- [ ] UPDATE + ROLLBACK 후 vacuum 이 지나가도 원래 값이 판독된다 (CBRD-27237 시나리오)
- [ ] commit-with-postpone 이후 알림 전·후 crash와 재기동에서도 알림이 복구되고, snapshot 안전 시점 뒤 옛 chain이 회수된다
- [ ] UPDATE 미커밋 crash와 문장·savepoint·transaction rollback 뒤 원래 chain이 보존되고 취소된 변경의 postpone은 실행되지 않는다
- [ ] vacuum 블록 중단·재시도 (CBRD-26950 재현 절차) 에서 재사용 슬롯 오삭제 없음
- [ ] HA: 재사용 UPDATE 가 replica 에 적용되고 값 동등성 유지, applylogdb sql.log 정상
- [ ] SA_MODE: 공유 chain을 보존하고 실제로 버린 chain은 transaction commit 뒤 정리한다
- [ ] 비 OOS UPDATE 의 로그 볼륨 증가 없음

## Definition of done

- [ ] 위 A/C 충족
- [ ] QA 통과
- [ ] 문서/매뉴얼 반영 (OOS 설계 문서의 소유권 불변식 교체 포함)

## Remarks

- **선행 필수**: CBRD-26950 — 계약상 근거는 Specification Changes 2 참조.
- **선행 정합성**: CBRD-27237의 rollback 오삭제 수정과 CBRD-27781의 redo-only 회수. 설계 선택으로 수정 완료를 가정하지 않는다.
- **관련**: CBRD-26516 (UPDATE 시 중복 oos_read — 잔여분이 본 이슈로 해소), CBRD-26458 (unloaddb 성능 — 별개).
- 본 스펙은 소스 분석 (`feat/oos` @ `725a32c6e`) 과 PostgreSQL TOAST 메커니즘 비교 검증에 기반한다.
