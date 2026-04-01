# [OOS] Vacuum 시 OOS 레코드 정리 연동

## Description

### 배경

OOS (Out-of-row Overflow Storage) M1에서는 DELETE/UPDATE 시 OOS 레코드를 즉시 삭제하지 않고, heap 레코드에 MVCC delete ID만 추가한다. 기존 OOS 레코드는 MVCC reader가 접근할 수 있으므로 vacuum이 heap 레코드를 정리할 때까지 유지되어야 한다.

그러나 M1에서는 vacuum이 heap 레코드를 제거할 때 해당 레코드가 참조하는 OOS 레코드를 함께 정리하는 로직이 구현되지 않았다. 이로 인해 DELETE/UPDATE 후 OOS 레코드가 영구적으로 남아 OOS 파일이 무한히 커지는 문제가 있다.

### 목적

Vacuum이 heap 레코드를 제거할 때 해당 레코드의 OOS OID를 추출하여 `oos_delete()` 를 호출함으로써 OOS 레코드를 함께 정리한다.

---

## Implementation

### 변경 파일

| 파일 | 변경 내용 |
|------|----------|
| `src/query/vacuum.c` | `VACUUM_HEAP_HELPER` 에 `oos_vfid` 필드 추가, vacuum 경로에서 OOS 삭제 연동 |
| `unit_tests/oos/sql/test_oos_sql_vacuum.cpp` | Vacuum + OOS 연동 SQL 레벨 통합 테스트 7건 |
| `unit_tests/oos/sql/CMakeLists.txt` | 테스트 바이너리 등록 |

### 구현 상세

#### 1. `VACUUM_HEAP_HELPER` 구조체 확장

```c
VFID oos_vfid;  /* OOS file identifier (if any) */
```

`overflow_vfid` 와 동일한 패턴으로, vacuum 대상 heap 파일의 OOS VFID를 캐시한다.

#### 2. `vacuum_heap_prepare_record()` — OOS VFID 조회

`REC_HOME` 과 `REC_RELOCATION` 레코드를 읽은 후, `heap_recdes_contains_oos()` 로 OOS 플래그를 확인하고 `heap_oos_find_vfid()` 로 OOS VFID를 조회한다.

```
vacuum_heap_prepare_record()
  ├─ case REC_HOME:     → or_mvcc_get_header() → heap_recdes_contains_oos() → heap_oos_find_vfid()
  └─ case REC_RELOCATION: → or_mvcc_get_header() → heap_recdes_contains_oos() → heap_oos_find_vfid()
```

#### 3. `vacuum_heap_oos_delete()` — OOS 삭제 헬퍼

```c
static int vacuum_heap_oos_delete (THREAD_ENTRY *thread_p, VACUUM_HEAP_HELPER *helper)
```

`heap_recdes_get_oos_oids()` 로 레코드에서 OOS OID 목록을 추출하고, 각 OOS OID에 대해 `oos_delete()` 를 호출하여 OOS 레코드 체인을 삭제한다.

#### 4. `vacuum_heap_record()` — 레코드 타입별 처리

- **REC_HOME + OOS**: bulk 경로 대신 sysop 경로 사용 (다중 페이지 연산)
  - `vacuum_heap_page_log_and_reset()` → `log_sysop_start()` → `spage_vacuum_slot()` → `pgbuf_set_dirty()` → `vacuum_log_redoundo_vacuum_record()` → `vacuum_heap_oos_delete()` → `log_sysop_commit()`
- **REC_RELOCATION + OOS**: 기존 sysop 내에서 `log_sysop_commit()` 직전에 `vacuum_heap_oos_delete()` 호출
- **실패 시**: `log_sysop_abort()` 로 원자적 롤백

#### 호출 흐름

```
vacuum_heap_record()
  ├─ has_oos = heap_recdes_contains_oos() && !VFID_ISNULL(oos_vfid)
  │
  ├─ REC_HOME + has_oos:
  │   └─ flush bulk → sysop_start → vacuum_slot → log → oos_delete → sysop_commit
  │
  ├─ REC_RELOCATION + has_oos:
  │   └─ (기존 sysop 내) → ... → oos_delete → sysop_commit
  │
  └─ REC_HOME (no OOS):
      └─ (기존 bulk 경로, 변경 없음)
```

### 테스트 케이스

| TC | 설명 |
|----|------|
| DeleteSingleThenVacuum | 단일 OOS 레코드 삭제 → vacuum → 재삽입 검증 |
| DeleteMultipleThenVacuum | 5개 레코드 삭제 → vacuum → 재삽입 검증 |
| UpdateThenVacuum | UPDATE로 새 OOS 생성 → vacuum이 구버전 정리 |
| DeleteVacuumReinsert | 삭제 → vacuum → OOS 공간 재사용 검증 |
| DeleteMultiChunkThenVacuum | 64KB 멀티 청크 체인 삭제 → vacuum 정리 |
| MixedColumnsVacuum | OOS/non-OOS 혼합 컬럼 선택적 삭제 후 vacuum |
| MultipleUpdatesThenVacuum | 3회 UPDATE → vacuum이 3개 구버전 정리 |

---

## Acceptance Criteria

- [x] Vacuum이 `OR_MVCC_FLAG_HAS_OOS` 플래그가 있는 heap 레코드 제거 시 `oos_delete()` 호출
- [x] REC_HOME + OOS: sysop으로 원자적 처리
- [x] REC_RELOCATION + OOS: 기존 sysop 내에서 OOS 삭제
- [x] OOS 삭제 실패 시 `log_sysop_abort()` 로 롤백
- [x] 단위 테스트 7건 통과
- [x] 기존 OOS 테스트 전체 통과 (12/12)

---

## Remarks

- **REC_BIGONE** 은 OOS 처리 불필요: OOS의 목적이 레코드를 작게 유지하는 것이므로, overflow(BIGONE) 레코드에 OOS 플래그가 설정되는 경우는 없음
- OOS 페이지 자체의 deallocation은 이 이슈 범위 밖 (추후 vacuum 고도화에서 처리)
- `heap_oos_find_vfid()` 는 `PGBUF_UNCONDITIONAL_LATCH` 로 heap 헤더 페이지를 READ 고정 — latch ordering 이슈가 발생할 경우 `heap_ovf_find_vfid` 와 동일한 conditional latch 패턴으로 전환 필요
- 관련 이슈: CBRD-26517 (OOS 메인 트래킹)
- PR: `vimkim/cubrid` `oos-vacuum` 브랜치
