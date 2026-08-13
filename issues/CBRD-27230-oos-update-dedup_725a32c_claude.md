# [OOS] 변경 없는 OOS 값 중복 적재 방지

## Issue Triage

**이슈 수행 목적**: UPDATE 문이 할당하지 않은 OOS (Out-of-row Storage — heap 의 큰 가변 컬럼을 별도 파일로 분리 저장하는 방식) 컬럼에 대해, 새 레코드 버전이 기존 OOS 값 체인을 그대로 재사용하도록 한다.

**이슈 수행 이유**:

- **AS-IS (현재 동작 / 배경)**: UPDATE 는 할당 여부와 무관하게 행의 모든 OOS 값을 다시 읽고(`oos_read`) 새 체인으로 다시 적재한다(`oos_insert`). 미할당 컬럼의 신호는 `heap_attrinfo_set_uninitialized` (`src/storage/heap_file.c:12156`) 가 값을 즉시 읽어들이는 순간 사라져, 이후 쓰기 경로는 할당된 값과 구분하지 못한다. 미할당 OOS 컬럼 하나당 `oos_read` 1회 + `oos_insert` 1회 + vacuum 전까지 남는 죽은 체인 1개가 발생하고, 복제 로그도 값 전체를 매번 재전송한다.
- **TO-BE (목표 상태 / 기대 동작)**: 미할당 OOS 컬럼의 inline stub (heap 레코드 안의 참조 — CBRD-26950 이후 20 바이트) 을 새 레코드 버전에 그대로 복사해 체인을 재사용하고, 할당된 컬럼이 버린 옛 체인만 커밋 시점의 알림 로그로 vacuum 에 전달해 삭제한다.
- **영향**: 성능 저하 — 큰 OOS 값이 있는 행은 inline 컬럼 하나만 바꿔도 OOS 값 전체를 재적재·재복제한다. UPDATE 가 잦은 워크로드에서 I/O·복제 트래픽·OOS 파일 공간이 값 크기에 비례해 낭비된다.

**이슈 수행 방안** (확정 사항 — 계약 상세는 Specification Changes 참조):

1. **재사용 규칙**: "변경 없음" = UPDATE 문에 할당되지 않음. 값 비교는 하지 않는다 (비교하려면 없애려는 `oos_read` 가 필요).
2. **정리 아키텍처**: UPDATE 가 버린 체인 목록을 알림 로그 레코드로 vacuum 에 전달한다. rcvindex 는 예약만 되어 있는 `RVOOS_NOTIFY_VACUUM` (`src/transaction/recovery.h:207`) 을 재활용한다.
3. **커밋 조건부 발행**: 알림은 커밋된 UPDATE 에 대해서만 발행한다 — rollback 된 UPDATE 의 옛 체인 오삭제 (CBRD-27237) 도 함께 해소된다.
4. **forward-walk 제거**: UPDATE 로그의 undo image (변경 전 행 모습을 로그에 남긴 불변 스냅샷) 에서 옛 체인을 재유도해 삭제하던 `vacuum_forward_walk_reclaim_oos` 경로는 게이트가 아니라 제거한다. DELETE 는 기존 REMOVE 경로 그대로 둔다.
5. **선행 필수**: CBRD-26950 (generation identity stamp — 체인 head 청크에 찍어 슬롯 재사용을 감지하는 4 바이트 스탬프). 두 이슈는 직교하며 모두 필요하다.
6. **소유권 불변식 교체**: "OOS 값 체인은 그것을 참조하는 가장 새로운 논리적 레코드 버전이 소유한다. 옛 버전들은 undo image 를 통한 차용 참조만 갖는다. 체인 해제는 정확히 한 번 — 체인을 버린 UPDATE 의 커밋(알림 레코드) 또는 vacuum 의 행 마지막 버전 제거(REMOVE 경로) 로만 일어난다. undo image 는 삭제 근거가 아니다."
7. **복제 프로토콜 변경 포함**: 재사용 컬럼용 marker 아이템 (재사용 사실만 표시하는 자리 항목) 과 replica 측 보정을 본 이슈 범위에 포함한다 (별도 이슈로 분리하지 않음).

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다.

## Summary

- **변경 범위 / 영향**: 쓰기 경로 `src/storage/heap_file.c` (`heap_attrinfo_set_uninitialized`, disk layout, stub 기록), vacuum `src/query/vacuum.c` + `src/query/vacuum_oos.cpp` (forward-walk 제거, 알림 소비 신설), 커밋 경로 `src/transaction/log_manager.c` (발행 훅), 복제 `src/transaction/locator_sr.c` + `src/broker`/applylogdb 경로 (`log_applier.c`). SA_MODE 는 eager 정리 경로 (`heap_oos_delete_unreferenced`, `src/storage/heap_oos.cpp:754`) 가 옛/새 stub 차집합을 이미 계산하므로 무변경. `feat/oos` 전용 변경이라 출시본 호환성 부담은 없다.

## Description

### 배경 — 왜 지금까지 항상 새 체인이었나

M1 설계는 "각 OOS 값 체인은 정확히 하나의 논리적 레코드 버전이 소유한다"는 불변식 위에 서 있다. UPDATE 는 항상 새 체인을 만들고, vacuum 의 forward-walk 는 UPDATE 로그의 undo image 에서 옛 체인의 head OOS OID 를 꺼내 삭제한다 (`vacuum_forward_walk_reclaim_oos`, `src/query/vacuum_oos.cpp:223`). 이 구조에서 옛/새 버전의 head OID 는 항상 서로소이므로, undo image 만 보고 지워도 안전했다.

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

- UPDATE 문에 할당되지 않은 OOS 컬럼: 옛 레코드 버전의 20 바이트 stub (head OOS OID 8B + 전체 길이 8B + 기대 generation 4B, CBRD-26950) 을 새 레코드 버전에 바이트 그대로 복사한다. `oos_read` 없음, `oos_insert` 없음. generation 도 그대로 복사한다 — 새로 발급하면 살아남은 체인을 이후 어떤 `oos_delete` 도 지우지 못하는 영구 누수가 된다.
- 할당된 OOS 컬럼: 기존대로 demote·적재하고, 버린 옛 체인이 알림 레코드의 삭제 목록에 오른다.
- 할당되었지만 값이 같은 컬럼은 재사용하지 않는다 (값 비교 없음 — 범위 밖).

### 2. 알림 레코드 `RVOOS_NOTIFY_VACUUM`

- **내용**: 버린 체인당 `(head OOS OID, 기대 generation)` 쌍 (CBRD-26950 의 `oos_chain_ref` 형태) + OOS 파일 식별자. 행 OID·MVCCID (트랜잭션별 MVCC 식별자)·청크 목록은 불필요 (블록 게이트가 가시성을, `oos_delete_chain` 이 체인 순회를 담당). 버린 체인이 없는 UPDATE 는 아무것도 발행하지 않는다 — 비 OOS UPDATE 의 로그 부담 0.
- **발행 (커밋 조건부)**: 불변식 — *알림 레코드는 UPDATE 가 커밋된 경우에만 디스크에 존재한다.* 단순 `log_append_postpone` 으로는 전달되지 않는다: vacuum 의 스트림은 MVCC undo 계열 append 만 소비하고 (`src/transaction/log_append.cpp:970-996`), `log_commit_local` 에서 `logtb_complete_mvcc` (`src/transaction/log_manager.c:5228`) 가 `log_tran_do_postpone` (`:5245`) 보다 먼저 실행되어 postpone 시점엔 스탬프할 MVCCID 가 없다. 따라서 **커밋 훅 방식을 채택한다**: `logtb_complete_mvcc` 직전에 `RVES_NOTIFY_VACUUM` 과 같은 꼴 (page 없는 MVCC undo append, `src/query/vacuum.c:8081-8103` 참조) 로 발행한다. 알림이 커밋 레코드보다 앞서 기록되므로 "커밋이 내구적이면 알림도 내구적" 이 성립하고, 커밋 전에 crash 하면 알림은 없지만 UPDATE 자체가 복구 시 롤백되어 버린 체인도 없다 — 어느 쪽이든 체인 누수가 없다.
- **소비**: `vacuum_process_log_block` 에 rcvindex 분기 신설. `RVOOS_NOTIFY_VACUUM` 은 이미 MVCC 연산으로 분류되어 있고 heap 연산은 아니므로 vacuum worker 에 도달하되 slot 수집 대상은 되지 않는다. 각 삭제는 기존 forward-walk 와 같은 레코드 단위 sysop (트랜잭션 안의 원자적 시스템 연산) 으로 수행한다. 재시도 안전성은 CBRD-26950 의 `oos_delete(expected_generation)` no-op 이 전담한다 — 알림 레코드 자체는 undo image 와 똑같이 불변·재독되므로 자체 멱등성이 없다.
- **복구 핸들러**: 양방향 no-op (페이지를 바꾸지 않는 순수 알림 — `RVES_NOTIFY_VACUUM` 과 동일).

### 3. 제거 및 불변 항목

- 제거: `vacuum_forward_walk_reclaim_oos` 전체와 undo image 파싱 부속 (레코드 타입 가드, 로그 페이지 회전 대비 사본, undo 언패킹 화이트리스트의 OOS 태그들, `RVHF_DELETE_NEWHOME_NOTIFY_VACUUM` 특례). 해당 UPDATE 계열 rcvindex 는 일반 MVCC UPDATE 로 환원된다.
- 불변: DELETE 는 REMOVE 경로 (slot 제거와 같은 sysop 에서 live 레코드를 다시 읽는 `vacuum_heap_oos_delete_within_sysop`) 그대로. DELETE 는 체인을 버리지 않으므로 알림을 발행하면 오히려 이중 삭제가 된다.

### 4. 복제 프로토콜

현재 복제 로그는 값이 아니라 OOS 값당 `RVREPL_OOS_INSERT` 아이템 (master 의 물리 `RVOOS_INSERT` WAL 레코드를 가리키는 LSA) 을 실어 보내고, replica 는 그 WAL 바이트로 자기 자신의 `oos_insert` 를 수행한 뒤 레코드의 OID 를 바꿔 쓴다 (`src/transaction/locator_sr.c:5287`, `:14166`). 아이템 수와 stub 수가 어긋나면 replica 는 오류로 적용을 중단한다 (`:14179`, `:14234`) — 즉 dedup 을 master 만 바꾸면 HA 가 시끄럽게 (조용한 불일치 없이) 멈춘다. 변경 사항:

- **marker 아이템**: 재사용된 컬럼 자리에 "이 컬럼은 기존 체인 재사용" 을 뜻하는 아이템을 넣어 위치·개수 계약을 유지한다.
- **replica 측 보정 (fixup)**: 재사용 컬럼의 OID·generation 은 replica 자신의 직전 행 버전 stub 에서 가져온다. 그 버전은 이미 fetch 하고 있으나 (`locator_sr.c:6943`) OOS 확장이 켜진 fetch 라 stub 원본이 필요한 이 용도에는 비확장 fetch 로 전환해야 한다.
- **replica 측 vacuum**: replica 도 같은 알림 레코드 구조로 동작하므로 master 와 동일한 보호를 받는다.
- **applylogdb**: sql.log 재구성 경로 (`log_applier.c:3845`) 가 재사용 컬럼을 처리하도록 갱신한다.

## Implementation

쓰기 경로 (모두 `src/storage/heap_file.c`, 커밋 `725a32c6e` 기준):

```
heap_attrinfo_set_uninitialized (:12156)
 ★ 현재: 미할당 컬럼도 heap_attrvalue_read → oos_read (:12158, :10482) 로 값 자체를 적재
 ★ 변경: 미할당이면서 옛 VOT (레코드의 가변 컬럼 오프셋 테이블) 의 OR_IS_OOS 비트
    (해당 컬럼이 OOS 로 나가 있음을 표시) 가 켜진 컬럼은 옛 stub (head OID, length, generation) 만 캡처
    │
heap_attrinfo_determine_disk_layout (:12382)
 ★ 변경: 컬럼 계획(heap_oos_column_plan)의 selected 를 "stub 만 기록" / "새 체인 할당" 으로 분리
    │        같은 pass 에서 삭제 목록 (할당됨 + 옛 OR_IS_OOS) 산출
heap_attrinfo_prepare_oos_insert_requests (:12633)
 ★ 변경: 재사용 컬럼 건너뜀 (oos_insert 요청 생성 안 함)
    │
stub 기록 (:13039-13050)  — 무변경 (캡처된 옛 stub 이 그대로 직렬화됨)
    │
heap_log_update_physical (:24145 / :23906; :23588 은 bigone 경로 —
    OOS+bigone 거부(:13295)로 목록이 항상 빈 값이나 일관성 위해 동일 처리)
 ★ 변경: 직전에 삭제 목록을 트랜잭션 로컬로 등록 (커밋 훅이 소비)
    │
log_commit_local (log_manager.c)
 ★ 신설: logtb_complete_mvcc (:5228) 직전 커밋 훅이 RVOOS_NOTIFY_VACUUM 발행
```

vacuum 소비 측: `vacuum_process_log_block` 에 분기 신설, 쌍마다 `oos_delete (vfid, head_oid, expected_generation)` 를 레코드 단위 sysop 으로 실행. generation 불일치·slot 부재는 no-op.

경계 확인 (분석 완료):

- 재사용 stub 때문에 레코드가 OOS 이관 게이트 (`DB_PAGESIZE/4`, `heap_file.c:12345`) 아래로 내려가도 문제 없다 — 게이트는 `heap_attrinfo_determine_disk_layout` 안에서만 쓰이고, 읽기·vacuum·복구·복제 어느 경로도 레코드 크기에서 "OOS 있음" 을 유도하지 않는다 (stub 은 VOT 의 `OR_IS_OOS` 비트와 MVCC 헤더 플래그로만 식별). 재사용은 레코드를 키우지 않으므로 OOS+bigone 거부 (`:13295`) 도 새로 발동할 수 없다.
- 향후 개선안 "oos_insert 를 attrinfo_force 로 이동" (기존 검토 항목) 과는 상충 없음 — 오히려 같은 커밋 창으로 모이는 시너지.

## Acceptance Criteria

- [ ] inline 컬럼만 할당하는 UPDATE 후, OOS 컬럼의 head OOS OID·generation 이 이전 버전과 동일하다 (debug oos.log 로 확인) — 값 판독 정상
- [ ] OOS 컬럼을 할당하는 UPDATE 후, 커밋 → vacuum 완료 시 옛 체인이 회수되고 새 체인은 유지된다
- [ ] UPDATE + ROLLBACK 후 vacuum 이 지나가도 원래 값이 판독된다 (CBRD-27237 시나리오)
- [ ] UPDATE 커밋 직후 crash → 재기동 → vacuum: 옛 체인 회수 (알림 내구성)
- [ ] UPDATE 미커밋 crash → 재기동: 옛 체인 유지, 새 체인 회수 (알림 부재)
- [ ] vacuum 블록 중단·재시도 (CBRD-26950 재현 절차) 에서 재사용 슬롯 오삭제 없음
- [ ] HA: 재사용 UPDATE 가 replica 에 적용되고 값 동등성 유지, applylogdb sql.log 정상
- [ ] SA_MODE: UPDATE 시 즉시 정리 경로가 공유 체인을 보존
- [ ] 비 OOS UPDATE 의 로그 볼륨 증가 없음

## Definition of done

- [ ] 위 A/C 충족
- [ ] QA 통과
- [ ] 문서/매뉴얼 반영 (OOS 설계 문서의 소유권 불변식 교체 포함)

## Remarks

- **선행 필수**: CBRD-26950 — 계약상 근거는 Specification Changes 2 참조.
- **함께 해소**: CBRD-27237 (rollback 된 UPDATE 의 옛 체인 vacuum 오삭제).
- **관련**: CBRD-26516 (UPDATE 시 중복 oos_read — 잔여분이 본 이슈로 해소), CBRD-26458 (unloaddb 성능 — 별개).
- 본 스펙은 소스 분석 (`feat/oos` @ `725a32c6e`) 과 PostgreSQL TOAST 메커니즘 비교 검증에 기반한다.
