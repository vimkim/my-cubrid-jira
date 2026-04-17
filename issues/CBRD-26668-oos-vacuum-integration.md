# [OOS] Vacuum 시 OOS 레코드 정리 연동

## Description

### 배경

OOS (Out-of-row Overflow Storage) M1에서는 DELETE/UPDATE 시 OOS 레코드를 즉시 삭제하지 않고, heap 레코드에 MVCC delete ID만 추가한다. 기존 OOS 레코드는 MVCC reader가 접근할 수 있으므로 vacuum이 heap 레코드를 정리할 때까지 유지되어야 한다.

그러나 M1에서는 vacuum이 heap 레코드를 제거할 때 해당 레코드가 참조하는 OOS 레코드를 함께 정리하는 로직이 구현되지 않았다. 이로 인해 DELETE/UPDATE 후 OOS 레코드가 영구적으로 남아 OOS 파일이 무한히 커지는 문제가 있다.

### 목적

Vacuum이 heap 레코드를 제거할 때 해당 레코드의 OOS OID를 추출하여 `oos_delete()` 를 호출함으로써 OOS 레코드를 함께 정리한다. 또한 MVCC UPDATE의 prev_version 체인에 남아 있는 구버전 OOS, SA_MODE 비-MVCC UPDATE에서 교체된 OOS도 연계하여 정리한다.

---

## Implementation Scope

본 이슈는 OOS 삭제 회수 경로를 mode별로 완성한다.

| # | 경로 | 대상 | 비고 |
|---|------|------|------|
| 1 | Vacuum current record | `REC_HOME` / `REC_RELOCATION` + OOS | 본 이슈 원 스코프 |
| 2 | Vacuum prev_version chain | MVCC UPDATE로 생긴 구버전 OOS | 신버전 recdes에는 새 OOS OID만 있고 구버전은 undo log에만 있음 → 별도 chain 순회 |
| 3 | SA_MODE eager cleanup | Non-MVCC UPDATE (in-place overwrite) | CBRD-26609에 기술된 UPDATE 시 `oos_delete`+`oos_insert` 경로를 mode 별로 분기. SA_MODE는 vacuum no-op 이므로 eager 유지, SERVER_MODE는 prev_version vacuum(경로 2)로 이관. |

부수적으로 OOS 검출 정확도를 개선하기 위해 다음 수정이 함께 들어갔다.

| # | 수정 | 필요 사유 |
|---|------|-----------|
| 4 | 클래스/카탈로그 레코드 VOT 4-byte 정렬 | `OR_GET_VAR_OFFSET()` 이 low 2 bits를 마스크 → 정렬되지 않은 offset 이 OOS flag로 오인됨 (false positive) |
| 5 | `heap_recdes_check_has_oos` old-format 방어 | `OR_VAR_BIT_LAST_ELEMENT` 를 모르는 이전 버전 레코드에서 odd offset이 OOS로 오인되던 문제 |
| 6 | `heap_recdes_contains_oos` MVCC flag ↔ VOT scan cross-validation | debug 빌드에서 OOS flag/VOT 불일치 즉시 검출 |
| 7 | `RVOOS_NOTIFY_VACUUM` 을 `LOG_IS_MVCC_OPERATION` 에 추가 | vacuum worker가 OOS notify-vacuum 로그를 MVCC 연산으로 인식 |

---

## Implementation

### 변경 파일

| 파일 | 변경 요지 |
|------|-----------|
| `src/query/vacuum.c` | `VACUUM_HEAP_HELPER::oos_vfid` 필드, `vacuum_heap_oos_delete`, `vacuum_cleanup_prev_version_oos` 신규, `vacuum_heap_record` 수정 |
| `src/storage/heap_file.c` | `heap_update_home` SA_MODE eager cleanup, `heap_recdes_contains_oos` cross-validation, `heap_recdes_check_has_oos` 재작성 |
| `src/object/transform_cl.c` | 클래스 메타 직렬화 VOT offset 4-byte 정렬 |
| `src/storage/catalog_class.c` | catcls VOT offset 4-byte 정렬 padding |
| `src/transaction/mvcc.h` | `LOG_IS_MVCC_OPERATION` 매크로에 `RVOOS_NOTIFY_VACUUM` 추가 |
| `unit_tests/oos/**` | SA_MODE eager cleanup 테스트 7건, SERVER_MODE 테스트 인프라 + 5개 신규 테스트 바이너리 |
| `unit_tests/oos/sql/test_oos_sql_vacuum.cpp` | SQL 수준 vacuum 통합 테스트 12건 |

### 1. Vacuum current record 경로 — `vacuum_heap_record` 수정

#### `VACUUM_HEAP_HELPER` 구조체 확장

```c
VFID oos_vfid;  /* OOS file identifier (if any) */
```

`overflow_vfid` 와 동일 패턴으로 vacuum 대상 heap 파일의 OOS VFID를 캐시한다.

#### `vacuum_heap_prepare_record` — OOS VFID 조회

`REC_HOME` / `REC_RELOCATION` 레코드를 읽은 후 `heap_recdes_contains_oos()` 로 OOS flag 확인 → `heap_oos_find_vfid()` 로 OOS VFID 조회. 조회 실패는 false positive 가능성이 있으므로 `vacuum_er_log_warning` 로 기록만 하고 계속 진행한다.

#### `vacuum_heap_oos_delete` — OOS 삭제 헬퍼 (static)

```c
static int vacuum_heap_oos_delete (THREAD_ENTRY *thread_p, VACUUM_HEAP_HELPER *helper);
```

`heap_recdes_get_oos_oids()` 로 OOS OID 벡터 추출 → 각 OID에 대해 `oos_delete()` 호출. 단건 실패 시 즉시 error code 반환하여 상위에서 sysop abort가 가능하게 한다.

#### `vacuum_heap_record` — 레코드 타입별 처리

| Record type | 처리 |
|-------------|------|
| `REC_RELOCATION` + OOS | 기존 sysop 내에서 `log_sysop_commit()` 직전에 `vacuum_heap_oos_delete()` 호출 |
| `REC_HOME` + OOS | bulk 경로 대신 sysop 경로 사용 (`log_sysop_start` → page 변경 → 로그 → `vacuum_heap_oos_delete` → `log_sysop_commit`) |
| `REC_BIGONE` | OOS 처리 불필요 (overflow 레코드는 OOS flag가 설정되지 않음) |
| 실패 시 | `log_sysop_abort()` 로 원자적 롤백 |

```
vacuum_heap_record()
  ├─ has_oos = !VFID_ISNULL(oos_vfid) && (REC_HOME || REC_RELOCATION) && heap_recdes_contains_oos()
  │
  ├─ rel || big || has_oos → flush bulk + log_sysop_start
  │
  ├─ REC_RELOCATION + has_oos:
  │   └─ ... → oos_delete → log_sysop_commit (fail → log_sysop_abort)
  │
  ├─ REC_HOME + has_oos:
  │   └─ pgbuf_set_dirty → vacuum_log_redoundo_vacuum_record → oos_delete → log_sysop_commit
  │
  └─ REC_HOME (no OOS): 기존 bulk 경로 (변경 없음)
```

### 2. Prev_version chain 경로 — `vacuum_cleanup_prev_version_oos` (신규)

MVCC UPDATE는 신버전 heap record에 새 OOS OID를 쓰고, 구버전 OOS OID는 undo log에 기록된다. 따라서 `helper->record` 만 스캔하면 신버전 OOS만 보인다. 별도로 `prev_version_lsa` 체인을 순회하여 구버전의 OOS OID를 추출해 삭제해야 한다.

호출 지점: `vacuum_heap_record_insid_and_prev_version()` — `prev_version_lsa` 를 클리어하기 **직전**.

```c
if (MVCC_IS_HEADER_PREV_VERSION_VALID (&helper->mvcc_header) && !VFID_ISNULL (&helper->oos_vfid))
  {
    (void) vacuum_cleanup_prev_version_oos (thread_p, helper);
  }
```

동작:

```
current_lsa ← helper->mvcc_header.prev_version_lsa
while (!LSA_ISNULL(current_lsa)):
    logpb_fetch_page(current_lsa)
    log_get_undo_record(...)  → old_recdes
    if heap_recdes_contains_oos(old_recdes):
        heap_recdes_get_oos_oids(old_recdes) → oos_oids
        for each oid: oos_delete(oos_vfid, oid)
    or_mvcc_get_header(old_recdes) → old_mvcc_header
    current_lsa ← MVCC_GET_PREV_VERSION_LSA(old_mvcc_header)
```

설계 선택:

- **Best-effort**: 로그 페이지 fetch 실패(archived 등), undo record read 실패, 개별 `oos_delete` 실패는 `vacuum_er_log_warning` 로 남기고 진행/중단. vacuum blocking을 회피하고 현재 record 정리는 수행.
- **체인 진입 조건**: `prev_version_lsa` 유효 + 해당 heap에 OOS 파일이 존재할 때만. OOS 없는 heap에서는 로그 I/O 비용 회피.
- **SA_MODE 미적용**: SA_MODE UPDATE는 in-place overwrite로 prev_version_lsa 체인을 생성하지 않음 — 경로 3이 대신 처리.

### 3. SA_MODE eager cleanup 경로 — `heap_update_home` 내 블록

CBRD-26609에서 기술된 UPDATE 시 `oos_delete`(구버전) + `oos_insert`(신버전) 경로를 mode 별로 분기한 형태다. SERVER_MODE(MVCC)는 구버전을 읽는 concurrent reader를 위해 즉시 삭제를 금지하고 vacuum (경로 2)에 이관하며, SA_MODE는 concurrent reader가 없고 vacuum이 no-op 이므로 eager 삭제를 유지한다.

`heap_update_home()` 의 heap update 완료 직후 블록:

```c
if (!is_mvcc_op && context->home_recdes.type == REC_HOME && heap_recdes_contains_oos (&context->home_recdes))
  {
    OID_VECTOR old_oos_oids, new_oos_oids;
    heap_recdes_get_oos_oids (&context->home_recdes, old_oos_oids);  // 구버전 OID
    if (heap_recdes_contains_oos (context->recdes_p))
      heap_recdes_get_oos_oids (context->recdes_p, new_oos_oids);    // 신버전 OID

    VFID oos_vfid;
    if (heap_oos_find_vfid (thread_p, &context->hfid, &oos_vfid, false))
      {
        for each old_oid:
          if (old_oid not in new_oos_oids):   // 신버전에 재사용되지 않은 것만 삭제
            oos_delete (thread_p, oos_vfid, old_oid);
      }
  }
```

교차 체크로 신버전이 여전히 참조하는 OOS OID는 보존한다 (동일 OID 재사용 시나리오).

### 4. VOT 4-byte 정렬

`OR_GET_VAR_OFFSET()` 은 low 2 bits를 flag 비트(`OR_VAR_BIT_OOS`, `OR_VAR_BIT_LAST_ELEMENT`)로 마스크한다. 따라서 VOT에 쓰이는 offset 값은 반드시 4-byte 정렬이어야 한다.

기존 코드의 클래스/카탈로그 직렬화는 정렬을 보장하지 않아, 우연히 odd offset이 생기면 `OR_IS_OOS()` 가 false positive를 일으켰다. 수정 지점:

| 파일 | 수정 |
|------|------|
| `src/object/transform_cl.c` | `put_varinfo`, `object_size`, `put_attributes`, `domain_to_disk`, `methsig_to_disk`, ... 등 모든 VOT writer에 `DB_ALIGN(offset, 4)` 적용 및 writer측 `or_pad` 삽입 |
| `src/storage/catalog_class.c` | `catcls_put_or_value_into_buffer` 에서 variable 위치를 4-byte 경계로 padding |

신규 레코드는 4-byte 정렬된 offset으로 기록되며, 이전 버전으로 저장된 레코드에 대해서는 아래 (5)의 방어 로직으로 대응.

### 5. `heap_recdes_check_has_oos` 재작성 — old-format 방어

이전 버전 레코드는 `OR_VAR_BIT_LAST_ELEMENT` 플래그를 사용하지 않으므로, VOT를 끝까지 스캔해도 terminator가 없을 수 있다. 또한 odd offset이 섞이면 현재 `OR_IS_OOS` 가 false positive를 낸다. 재작성된 로직:

- 첫 VOT entry의 offset이 `[0, recdes->length - header_size]` 범위를 벗어나면 old-format으로 간주하고 즉시 `false` 반환.
- `OR_VAR_BIT_LAST_ELEMENT` 를 만나기 전까지 스캔하면서 OOS 플래그 축적.
- terminator 없이 스캔이 끝나면 old-format으로 간주하고 `false` 반환 (이전: assert).

### 6. `heap_recdes_contains_oos` cross-validation (debug 빌드)

MVCC flag의 `OR_MVCC_FLAG_HAS_OOS` 와 VOT 스캔의 `heap_recdes_check_has_oos` 결과를 비교. 불일치 시 VOT 덤프를 `fprintf(stderr)` 로 출력하고, `flag=true && vot=false` 인 경우 `assert(false)` 로 즉시 실패.

이는 위 (4)의 정렬 수정이 모든 writer를 커버하는지 확인하는 자가 검증 장치다.

### 7. `RVOOS_NOTIFY_VACUUM` MVCC 연산 등록

`src/transaction/mvcc.h`:

```c
#define LOG_IS_MVCC_OPERATION(rcvindex) \
  (LOG_IS_MVCC_HEAP_OPERATION (rcvindex) \
   || LOG_IS_MVCC_BTREE_OPERATION (rcvindex) \
   || ((rcvindex) == RVES_NOTIFY_VACUUM) \
   || ((rcvindex) == RVOOS_NOTIFY_VACUUM))
```

### 테스트

| 파일 | 유형 | 건수 | 설명 |
|------|------|------|------|
| `test_oos_sql_vacuum.cpp` | SA_MODE SQL | 12 | `DeleteSingleThenVacuum`, `DeleteMultipleThenVacuum`, `UpdateThenVacuum`, `DeleteVacuumReinsert`, `DeleteMultiChunkThenVacuum`, `MixedColumnsVacuum`, `MultipleUpdatesThenVacuum` 등 |
| `test_oos_sql_eager_cleanup.cpp` | SA_MODE SQL | 7 | `SingleUpdateCleansOldOos`, `MultipleUpdatesPagesBounded`, `MultiOosColumnUpdateCleanup`, `UpdateChurnStress`, `StepByStepLifecycleWithPageCounts`, `UpdateVaryingOosSizes`, `MixedColumnsUpdateOnlyOos` — SA_MODE eager cleanup 전용 |
| `test_oos_vacuum_server.cpp` | SERVER_MODE | 7+ | `bridge_vacuum_heap_oos_delete` 를 통해 실제 vacuum 코드 경로 검증 |
| `test_oos_mock_vacuum_server.cpp` | SERVER_MODE | 6 | OOS 삭제 mock (vacuum 흐름 시뮬레이션) |
| `test_oos_server.cpp` / `test_oos_delete_server.cpp` / `test_oos_remove_file_server.cpp` | SERVER_MODE | 다수 | SA_MODE 기존 테스트의 SERVER_MODE 미러 |
| `test_oos_server_common.hpp` | 공용 | — | SERVER_MODE boot 인프라 (msgcat_init, tz_load, boot_restart_server 포함) |

### 테스트 브릿지 함수 추가

```c
int bridge_vacuum_heap_oos_delete (THREAD_ENTRY *thread_p, const VFID *oos_vfid, RECDES *record);
```

`vacuum.c` 에 `static` 으로 선언된 `vacuum_heap_oos_delete` 를 외부에서 호출할 수 있게 래핑. 유닛테스트에서 crafted RECDES로 실제 코드 경로를 검증하기 위함.

---

## Acceptance Criteria

- [x] Vacuum이 `OR_MVCC_FLAG_HAS_OOS` 플래그가 있는 heap 레코드 제거 시 `oos_delete()` 호출
- [x] `REC_HOME` + OOS: sysop으로 원자적 처리
- [x] `REC_RELOCATION` + OOS: 기존 sysop 내에서 OOS 삭제
- [x] OOS 삭제 실패 시 `log_sysop_abort()` 로 롤백
- [x] MVCC UPDATE의 prev_version chain을 순회하여 구버전 OOS 정리 (`vacuum_cleanup_prev_version_oos`)
- [x] SA_MODE UPDATE 시 교체된 OOS를 eager 삭제 (`heap_update_home`)
- [x] 클래스/카탈로그 레코드 VOT offset 4-byte 정렬 적용
- [x] Old-format 레코드에 대한 `heap_recdes_check_has_oos` false-positive 방어
- [x] 단위 테스트 통과: SQL vacuum 12건, SA_MODE eager 7건, SERVER_MODE 5 바이너리
- [x] 기존 OOS 테스트 regression 없음
- [ ] SA_MODE DELETE 경로 OOS leak 수용 여부 문서화 (Remarks 참조)

---

## Remarks

### 설계 범위 및 한계

- **REC_BIGONE 제외**: OOS의 목적이 레코드를 작게 유지하는 것이므로 overflow 레코드에 OOS 플래그가 설정되는 경우는 없음.
- **OOS 페이지 deallocation 범위 밖**: 본 이슈는 OOS 슬롯 회수(`spage_delete`/`total_free`)까지만 담당. 빈 OOS 페이지의 파일 축소는 추후 vacuum 고도화에서 처리.
- **SA_MODE DELETE → OOS leak**: SA_MODE는 vacuum이 no-op이며 `heap_update_home` eager cleanup은 UPDATE만 커버. SA_MODE DELETE로 지워진 heap 레코드가 참조하던 OOS는 영구 orphan으로 잔존한다. 현 설계에서 허용 여부를 확정할 필요가 있음.
- **Best-effort 경로 관측성**: `vacuum_cleanup_prev_version_oos` 및 SA_MODE eager cleanup은 실패 시 warning 로그만 남긴다. perfmon 카운터(`PSTAT_OOS_VACUUM_*`) 추가로 운영 탐지 가능성을 확보하는 것을 후속 과제로 고려.

### 잠재적 latch ordering

`heap_oos_find_vfid()` 는 `PGBUF_UNCONDITIONAL_LATCH` 로 heap 헤더 페이지를 READ 고정한다. vacuum 경로에서 heap 슬롯 페이지와 OOS 파일 헤더를 동시에 fix하는 상황이 생기면 latch ordering 이슈가 발생할 가능성이 있다. 발생 시 `heap_ovf_find_vfid` 와 동일한 conditional latch 패턴으로 전환 필요.

### 리뷰 지적 및 대응 이력

- 초기 구현에는 `locator_delete_oos_force()` (DELETE 시점 eager OOS 삭제) 가 포함되었으나, vacuum 경로와의 이중 삭제 및 crash-recovery 원자성 문제로 제거됨 (commit `23036a18b`).
- `heap_oos_find_vfid()` 실패 시 `(void)` 캐스트로 무시하던 코드는 `vacuum_er_log_warning` 로 기록하도록 수정됨 (commit `23036a18b`).
- VOT odd-offset collision 이슈는 commit `a3a3673f4`, `116b9a1eb`, `7103f9119`, `39c566df1` 일련에서 해결됨.

### 관련

- 관련 이슈: CBRD-26517 (OOS 메인 트래킹), CBRD-26583 (OOS M2 epic), CBRD-26609 (`oos_delete` 구현)
- PR: [CUBRID/cubrid#6986](https://github.com/CUBRID/cubrid/pull/6986) (`vimkim/cubrid` `oos-vacuum` 브랜치, base `feat/oos`)
