# [OOS] [M2] vacuum cleans up OOS (forward-walk redesign)

## Description

### 배경

OOS (Out-of-row Overflow Storage) M1에서는 DELETE/UPDATE 시 OOS 레코드를 즉시 삭제하지 않고, heap 레코드에 MVCC delete ID만 추가한다. 기존 OOS 레코드는 MVCC reader가 접근할 수 있으므로 vacuum이 heap 레코드를 정리할 때까지 유지되어야 한다.

그러나 M1에서는 vacuum이 heap 레코드를 제거할 때 해당 레코드가 참조하는 OOS 레코드를 함께 정리하는 로직이 구현되지 않았다. 이로 인해 DELETE/UPDATE 후 OOS 레코드가 영구적으로 남아 OOS 파일이 무한히 커지는 문제가 있다.

### 목적

Vacuum이 heap 레코드를 제거할 때, 그리고 MVCC UPDATE의 prev-version chain에 남아 있는 구버전을 처리할 때 연관 OOS OID를 추출하여 `oos_delete()` 를 호출함으로써 OOS 레코드를 함께 정리한다. 최종 설계는 vacuum의 기존 **forward log walk에 inline으로 OOS 정리를 편승** 시키는 방식을 채택한다. 초기 설계에 포함되었던 별도의 `prev_version_lsa` backward chain walker는 완전히 제거한다.

---

## Implementation Scope

본 이슈는 OOS 삭제 회수 경로를 mode별로 완성한다.

| # | 경로 | 대상 | 비고 |
|---|------|------|------|
| 1 | Vacuum forward log walk inline | MVCC UPDATE/DELETE가 참조하던 모든 과거 버전 OOS | 핵심 설계. `vacuum_process_log_block` 내 inline 정리 |
| 2 | Vacuum current record (INSID 경로) | 현재 heap 레코드가 여전히 참조하는 OOS | 기존 `vacuum_heap_oos_delete` 유지 |
| 3 | SA_MODE eager cleanup | Non-MVCC UPDATE (in-place overwrite) | `heap_update_home_delete_replaced_oos` 유지 |

부수적으로 OOS 검출 정확도를 개선하기 위해 다음 수정이 함께 들어갔다.

| # | 수정 | 필요 사유 |
|---|------|-----------|
| 4 | 클래스/카탈로그 레코드 VOT 4-byte 정렬 | `OR_GET_VAR_OFFSET()` 이 low 2 bits를 마스크 → 정렬되지 않은 offset이 OOS flag로 오인됨 (false positive) |
| 5 | `heap_recdes_check_has_oos` old-format 방어 | `OR_VAR_BIT_LAST_ELEMENT` 를 모르는 이전 버전 레코드에서 odd offset이 OOS로 오인되던 문제 |
| 6 | `heap_recdes_contains_oos` MVCC flag ↔ VOT scan cross-validation | debug 빌드에서 OOS flag/VOT 불일치 즉시 검출 |
| 7 | `RVOOS_NOTIFY_VACUUM` 을 `LOG_IS_MVCC_OPERATION` 에 추가 | vacuum worker가 OOS notify-vacuum 로그를 MVCC 연산으로 인식 |

---

## Implementation

### 변경 파일

| 파일 | 변경 요지 |
|------|-----------|
| `src/query/vacuum.c` | `VACUUM_HEAP_HELPER::oos_vfid` 필드, inline cleanup 블록, 신규 helper `vacuum_oos_vfid_cache_lookup`, `vacuum_forward_walk_delete_oos`. **`vacuum_cleanup_prev_version_oos` 및 REMOVE-path trigger 블록 삭제** |
| `src/storage/heap_file.c` | `heap_update_home` SA_MODE eager cleanup, `heap_recdes_contains_oos` cross-validation, `heap_recdes_check_has_oos` 재작성, 주석 업데이트 (chain walker → forward walk) |
| `src/object/transform_cl.c` | 클래스 메타 직렬화 VOT offset 4-byte 정렬 |
| `src/storage/catalog_class.c` | catcls VOT offset 4-byte 정렬 padding |
| `src/transaction/mvcc.h` | `LOG_IS_MVCC_OPERATION` 매크로에 `RVOOS_NOTIFY_VACUUM` 추가 |
| `unit_tests/oos/**` | SA_MODE eager cleanup 테스트 7건, SERVER_MODE 테스트 인프라 + 5개 신규 테스트 바이너리 |
| `unit_tests/oos/sql/test_oos_sql_vacuum.cpp` | SQL 수준 vacuum 통합 테스트 |

### 1. Forward-walk inline OOS cleanup — `vacuum_process_log_block` 수정

**핵심 설계.** Vacuum의 기존 MVCC 로그 순회 루프 안에서 OOS를 발견할 때마다 즉시 정리한다. 별도의 per-record backward chain walk 불필요.

#### 진입 지점 — `vacuum_process_log_record` 가드 확장

```c
/* 기존 */
if (!LOG_IS_MVCC_BTREE_OPERATION (log_record_data->rcvindex)
    && log_record_data->rcvindex != RVES_NOTIFY_VACUUM)
  { return NO_ERROR; /* skip undo decode */ }

/* 현재 */
if (!LOG_IS_MVCC_BTREE_OPERATION (log_record_data->rcvindex)
    && !LOG_IS_MVCC_HEAP_OPERATION (log_record_data->rcvindex)
    && log_record_data->rcvindex != RVES_NOTIFY_VACUUM)
  { return NO_ERROR; }
```

MVCC heap 연산(`RVHF_UPDATE_NOTIFY_VACUUM`, `RVHF_MVCC_DELETE_MODIFY_HOME` 등)의 undo 페이로드를 디코드할 수 있게 가드를 연다.

#### Inline 블록 — `vacuum_process_log_block` 의 MVCC heap 분기 내

```text
for each MVCC heap log record in block:
    vacuum_collect_heap_objects(oid, heap_vfid)         // 기존 동작
    if (undo_data != NULL && undo_data_size > 0):
        bounds_check: undo_data_size <= 2 * IO_MAX_PAGE_SIZE
        defensive_copy(undo_data → stack buffer or db_private_alloc)
        if (heap_recdes_contains_oos(undo_recdes)):
            oos_vfid = vacuum_oos_vfid_cache_lookup(cache, heap_vfid)
            if (!VFID_ISNULL(oos_vfid)):
                log_sysop_start()
                err = vacuum_forward_walk_delete_oos(undo_recdes, oos_vfid)
                if (err == NO_ERROR): log_sysop_commit()
                else:                  log_sysop_abort()   // best-effort
```

#### 신규 helpers

```c
static bool
vacuum_oos_vfid_cache_lookup (THREAD_ENTRY *, VACUUM_OOS_VFID_CACHE_ENTRY *cache,
                              int *cache_size, const VFID *heap_vfid, VFID *out_oos_vfid);

static int
vacuum_forward_walk_delete_oos (THREAD_ENTRY *, const RECDES *undo_recdes,
                                const VFID *oos_vfid);
```

**`vacuum_oos_vfid_cache_lookup`**: block-local 16-entry 선형 스캔 캐시. 캐시 미스 시 `file_descriptor_get()` → `heap_oos_find_vfid()`. `VFID_NULL` sentinel로 "OOS 파일 없음" 음성 캐시. **일시적 실패(transient failure) 시 캐시하지 않음** — 블록 내 나머지 레코드의 OOS가 false-negative로 누수되는 것을 방지.

**`vacuum_forward_walk_delete_oos`**: `heap_recdes_get_oos_oids()` 로 OID 추출 후 `oos_delete()` 반복. caller가 sysop으로 감싸야 함.

#### Defensive undo data copy

`oos_delete` 가 log page를 rotate하여 `undo_data` 포인터를 무효화할 수 있으므로, sysop 진입 전에 스택 버퍼(또는 크면 `db_private_alloc`)로 복사한다. 크기 상한은 `2 * IO_MAX_PAGE_SIZE` — 초과 시 `assert_release(false) + skip` 으로 손상 로그 대응.

### 2. Vacuum current record (INSID 경로) — 기존 유지

`vacuum_heap_record_insid_and_prev_version` 의 현재-레코드 OOS 정리(`vacuum_heap_oos_delete`)와 관련 헬퍼(`vacuum_ensure_oos_vfid_for_heap_record`, vacuum.c:2058 RELOC / 2173 HOME 호출)는 그대로 유지된다. INSID 경로는 여전히 live 레코드의 `oos_vfid` 에 의존한다.

### 3. Backward chain walker 제거

- `vacuum_cleanup_prev_version_oos` (약 250줄) 및 포워드 선언 **삭제**.
- `vacuum_heap_record` REMOVE 경로의 `need_prev_version_oos_cleanup` 트리거 블록 **삭제**.
- `bridge_vacuum_cleanup_prev_version_oos` 테스트 브릿지는 stub(`assert_release(false) + ER_FAILED`)으로 대체 — 기존 `DISABLED_*` 테스트의 링크 유지.

각 과거 버전은 자신의 MVCC heap 로그 레코드가 forward walk로 vacuum될 때 정리된다. 현재 heap 슬롯에 HAS_OOS 플래그가 있든 없든 독립적으로 동작.

### 4. SA_MODE eager cleanup — `heap_update_home` 내 블록 (기존 유지)

`heap_update_home_delete_replaced_oos` 가 `!is_mvcc_op` 분기에서 old/new OID 집합 차이를 삭제한다. SA_MODE는 vacuum이 no-op이므로 eager 유지.

### 5. Crash recovery — 새 WAL 레코드 없음

초기 제안된 `RVVAC_OOS_DELETE` 전용 redo record는 **double-replay hazard** 로 거부되었다 — redo handler에서 `oos_delete` 를 호출하면 log append(`RVOOS_DELETE` per-chunk)가 재귀적으로 발생하여 복구 규약 위반.

대신 `oos_delete_chain` 이 이미 청크 단위로 기록하는 `RVOOS_DELETE` undoredo와 sysop 원자성으로 복구를 보장한다.

| 상황 | 복구 동작 |
|------|-----------|
| 정상 경로 (sysop commit 성공) | per-chunk `RVOOS_DELETE` redo가 정상 replay |
| Sysop 중 crash (sysop end 미기록) | per-chunk undo로 자동 롤백, 다음 vacuum에서 재시도 |
| Sysop commit 직후 crash | redo로 commit 지점까지 복구 |

### 6. 안전성 불변식

**MVCC 임계값 불변식** (`vacuum.c:3477`, debug assert at `vacuum.c:3611-3618`):

```c
MVCCID threshold_mvccid = log_Gl.mvcc_table.get_global_oldest_visible ();
...
#if !defined (NDEBUG)
if (MVCC_ID_FOLLOW_OR_EQUAL (mvccid, threshold_mvccid)
    || MVCC_ID_PRECEDES (mvccid, data->oldest_visible_mvccid)
    || MVCC_ID_PRECEDES (data->newest_mvccid, mvccid))
  { assert (0); ... }
#endif
```

블록 내 모든 MVCCID가 임계값 미만임이 보장되므로, forward walk가 UPDATE 로그 레코드를 볼 때 해당 UPDATE의 MVCCID는 모든 활성 스냅샷 시야 밖이다. pre-image를 MVCC 재구성하려는 판독자가 존재할 수 없다.

**OID 분리성 불변식** (`heap_file.c:12408-12436`, `heap_file.c:12972-12981`): `heap_attrinfo_insert_to_oos` 는 매 transform마다 모든 OOS 컬럼에 fresh OID를 할당한다. UPDATE의 post-image는 pre-image OID를 재사용하지 않는다. 따라서 pre-image OID 삭제가 live 버전에 영향 없다.

**Sysop 페어링 불변식**: 모든 `log_sysop_start` 는 forward-walk iteration 말미의 `!LOG_FIND_CURRENT_TDES(thread_p)->is_under_sysop()` assert(`vacuum.c:3893`) 이전에 `commit` 또는 `abort` 로 매칭된다. 모든 제어 경로(성공, error, alloc 실패)에서 검증됨.

### 7. VOT 4-byte 정렬

`OR_GET_VAR_OFFSET()` 이 low 2 bits를 flag 비트(`OR_VAR_BIT_OOS`, `OR_VAR_BIT_LAST_ELEMENT`)로 마스크하므로, VOT의 offset은 반드시 4-byte 정렬이어야 한다.

| 파일 | 수정 |
|------|------|
| `src/object/transform_cl.c` | `put_varinfo`, `object_size`, `put_attributes`, `domain_to_disk`, `methsig_to_disk`, … 모든 VOT writer에 `DB_ALIGN(offset, 4)` 및 writer측 `or_pad` 삽입 |
| `src/storage/catalog_class.c` | `catcls_put_or_value_into_buffer` 에서 variable 위치를 4-byte 경계로 padding |

### 8. 방어 로직

**`heap_recdes_check_has_oos` 재작성** (`heap_file.c`):
- 첫 VOT entry의 offset이 `[0, recdes->length - header_size]` 범위를 벗어나면 old-format으로 간주 → 즉시 `false`.
- `OR_VAR_BIT_LAST_ELEMENT` 를 만나기 전까지 스캔하며 OOS 플래그 축적.
- terminator 없이 스캔 종료 시 old-format으로 간주 → `false`.

**`heap_recdes_contains_oos` cross-validation** (debug 빌드): MVCC flag `OR_MVCC_FLAG_HAS_OOS` 와 VOT 스캔 결과를 비교. 불일치 시 VOT 덤프를 `stderr` 로 출력하고, `flag=true && vot=false` 면 `assert(false)`.

**`RVOOS_NOTIFY_VACUUM` 등록** (`mvcc.h`):

```c
#define LOG_IS_MVCC_OPERATION(rcvindex) \
  (LOG_IS_MVCC_HEAP_OPERATION (rcvindex) \
   || LOG_IS_MVCC_BTREE_OPERATION (rcvindex) \
   || ((rcvindex) == RVES_NOTIFY_VACUUM) \
   || ((rcvindex) == RVOOS_NOTIFY_VACUUM))
```

### 9. Phase 0 감사 결과

- **I1 (OID 분리성)**: CONDITIONAL PASS. `LOG_IS_MVCC_HEAP_OPERATION` 중 `RVHF_UPDATE_NOTIFY_VACUUM`(`heap_file.c:24534`)과 `RVHF_MVCC_DELETE_MODIFY_HOME`(`heap_file.c:20754`)만 prev-version recdes를 undo로 전달. 나머지 rcvindex는 zero-byte undo → inline 블록의 `undo_data_size > 0` 가드가 자연스럽게 skip.
- **I2 (oos_delete idempotency)**: PASS. `oos_delete` 는 recovery replay 중 호출되지 않음. `oos_rv_redo_delete`(`oos_file.cpp:1777`)는 physical `spage_delete` — idempotent by construction.

---

## Performance

**제거된 비용**:
- 버전당 `logpb_fetch_page` (log page I/O 또는 buffer search)
- 버전당 `LOG_CS` 획득 (전역 critical section)
- 버전당 undo record 디코드 + MVCC 헤더 파싱
- chain walker 함수 자체의 유지보수 비용

**추가된 비용**:
- forward walk 내 MVCC heap op당 undo 페이로드 디코드 — non-OOS 테이블에도 발생
- `LOG_REC_MVCC_UNDO` 헤더에 HAS_OOS 힌트 비트가 없어 pre-filter 불가
- 실제 OOS 없는 경우 `heap_recdes_contains_oos` 가 HAS_OOS 비트 1개 체크로 즉시 false 반환 → 이후 블록 skip

**순 효과**:
- 가장 비싼 vacuum 경로 하나 제거, 저렴한 inline 체크로 대체.
- `sql/_01_object/_09_partition/_001_create/cases/1189.sql` 성능 회귀(커밋 `0748432eb` → 임시 가드 `899d5b633`)의 **근본 원인 제거**.
- non-OOS undo 디코드 오버헤드는 T0.5 마이크로벤치마크로 정량화 예정(후속 작업).

---

## Review Findings Addressed

3-way 리뷰(Architect/Security/Code-review) 결과로 적용된 수정:

| 심각도 | 지적 | 대응 |
|--------|------|------|
| BLOCKER | `RVVAC_OOS_DELETE` 도입 시 double-replay hazard | 설계 거부, sysop 래핑으로 대체 |
| BLOCKER | `log_sysop_start` 이후 end-of-iteration assert 전 commit/abort 미보장 | 모든 경로(성공/error/alloc 실패)에서 명시적 페어링 |
| MAJOR | `heap_oos_find_vfid` API 시그니처 불일치 | `file_descriptor_get` 으로 HFID 복원 + block-local 캐시 |
| MAJOR | "zero overhead for non-OOS" 주장 과장 | "Predictable overhead proportional to MVCC heap op rate"로 정정, T0.5 벤치마크 계획 |
| MAJOR | `indent` 포맷터가 C++ range-for 스타일을 깨뜨림 | 프로젝트 관례에 맞춰 `for (x:y)` 형태로 정정 |
| HIGH | Transient failure 시 false-negative 캐시 → 블록 내 OOS 누수 | 실패 시 캐시 기록 안 함 |
| MEDIUM | `undo_data_size` 에 상한 가드 없음 (corrupt log에 취약) | `> 2 * IO_MAX_PAGE_SIZE` 에서 `assert_release(false) + skip` |

---

## Acceptance Criteria

- [x] Vacuum forward log walk가 MVCC heap op의 undo에서 HAS_OOS 감지 시 `oos_delete()` 호출
- [x] Sysop으로 multi-chunk OOS 삭제 원자성 보장
- [x] OOS 삭제 실패 시 `log_sysop_abort()` 로 롤백, 블록 내 다른 레코드 처리는 계속
- [x] `vacuum_cleanup_prev_version_oos` 및 REMOVE-path trigger 블록 삭제
- [x] `vacuum_ensure_oos_vfid_for_heap_record` 및 INSID 경로 호출 유지
- [x] 새 WAL 레코드 타입 도입 없이 기존 `RVOOS_DELETE` per-chunk redo로 crash recovery
- [x] SA_MODE UPDATE 시 교체된 OOS를 eager 삭제 (`heap_update_home_delete_replaced_oos`)
- [x] 클래스/카탈로그 레코드 VOT offset 4-byte 정렬 적용
- [x] Old-format 레코드에 대한 `heap_recdes_check_has_oos` false-positive 방어
- [x] Block-local 16-entry VFID 캐시로 `file_descriptor_get` 중복 호출 최소화
- [x] Transient failure 시 false-negative 캐시 금지
- [x] `undo_data_size` 상한 가드
- [x] Phase 0 invariant 감사 (I1 CONDITIONAL PASS, I2 PASS)
- [x] 3-way 리뷰 (Architect/Security/Code-review) 승인
- [x] 단위 테스트 통과: 18/18 (`OosEagerCleanup.*` 7건 포함)
- [x] 기존 OOS 테스트 regression 없음
- [ ] CircleCI `sql/medium` 통과 (in progress)
- [ ] Partition 워크로드(`1189.sql`) 성능 회귀 없음 (CI 검증)
- [ ] UPDATE-drops-all-OOS → DELETE 회귀 테스트 (`.ctl` isolation test, 후속)
- [ ] Crash-recovery 테스트 (sysop commit/abort 경로, 후속)
- [ ] T0.5 undo-decode 마이크로벤치마크 (후속, 오버헤드 >15% 시 per-file "has_oos" 힌트 검토)

---

## Remarks

### 해결된 엣지 케이스

이전 커밋 `899d5b633` (`!VFID_ISNULL(&helper->oos_vfid)` 가드)에서 known-limitation으로 문서화했던 **"UPDATE가 모든 OOS 컬럼을 non-OOS로 교체 후 DELETE"** 누수는 forward-walk 재설계로 자동 해소됨. 각 과거 버전은 자신의 UPDATE 로그 레코드가 vacuum될 때 정리되므로, 현재 tombstone의 HAS_OOS 플래그 여부와 무관.

| 시나리오 | 구 설계 (chain walker + VFID 가드) | 신 설계 (forward walk) |
|----------|-----------------------------------|------------------------|
| INSERT + DELETE | OK | OK |
| INSERT + UPDATE + DELETE (OOS 유지) | OK | OK |
| INSERT + UPDATE (OOS drop) + DELETE | **누수** (L1) | OK |
| 여러 UPDATE + DELETE | OK | OK |

### 설계 범위 및 한계

- **REC_BIGONE 제외**: OOS의 목적이 레코드를 작게 유지하는 것이므로 overflow 레코드에 OOS 플래그가 설정되는 경우는 없음. Debug `assert` 만 존재. Release build에서도 트랩하려면 `assert_release` 로 전환 필요 (후속).
- **SA_MODE DELETE → OOS leak**: SA_MODE는 vacuum이 no-op이며 `heap_update_home` eager cleanup은 UPDATE만 커버. SA_MODE DELETE로 지워진 heap 레코드가 참조하던 OOS는 영구 orphan으로 잔존. 현 설계에서 허용 여부를 확정할 필요가 있음. 후속 JIRA로 분리 고려.
- **OOS 페이지 deallocation 범위 밖**: 본 이슈는 OOS 슬롯 회수(`spage_delete`/`total_free`)까지만 담당. 빈 OOS 페이지의 파일 축소는 추후 vacuum 고도화에서 처리.
- **Best-effort 경로 관측성**: forward walk 내 `oos_delete` 실패는 warning 로그만 남기고 블록 처리를 계속. perfmon 카운터(`PSTAT_OOS_VACUUM_*`) 추가로 운영 탐지 가능성 확보는 후속 과제.

### 리뷰 지적 및 대응 이력

- 초기 구현에는 `locator_delete_oos_force()` (DELETE 시점 eager OOS 삭제)가 포함되었으나, vacuum 경로와의 이중 삭제 및 crash-recovery 원자성 문제로 제거 (commit `23036a18b`).
- `heap_oos_find_vfid()` 실패 시 `(void)` 캐스트로 무시하던 코드는 `vacuum_er_log_warning` 로 기록하도록 수정 (commit `23036a18b`).
- VOT odd-offset collision 이슈는 commit `a3a3673f4`, `116b9a1eb`, `7103f9119`, `39c566df1` 일련에서 해결.
- 성능 회귀(`0748432eb`) → 임시 VFID 가드(`899d5b633`, 엣지 누수 허용) → **forward walk 재설계(`f912b720c`)** 로 근본 해결.

### 관련

- 관련 이슈: CBRD-26517 (OOS 메인 트래킹), CBRD-26583 (OOS M2 epic), CBRD-26609 (`oos_delete` 구현)
- PR: [CUBRID/cubrid#6986](https://github.com/CUBRID/cubrid/pull/6986) (`vimkim/cubrid` 의 `oos-vacuum` 브랜치, base `feat/oos`)
- 주요 커밋:
  - `f912b720c` refactor(oos): replace prev_version chain walker with forward-walk OOS cleanup
  - `31e6e9dc6` style(vacuum): match indent formatter on range-for and joined if
- 리뷰 참고 문서: [vimkim/my-cubrid-docs/pr-6986](https://github.com/vimkim/my-cubrid-docs/tree/main/pr-6986)
