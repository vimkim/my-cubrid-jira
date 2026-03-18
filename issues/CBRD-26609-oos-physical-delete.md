# [OOS] `oos_delete` 구현 — UPDATE/DELETE 시 OOS 값 물리적 삭제

## Description

### 배경

Milestone 1에서 OOS insert/read는 구현되어 있으나, OOS 레코드를 물리적으로 삭제하는
`oos_delete` API가 구현되어 있지 않다.

이로 인해 아래 두 가지 경로에서 OOS 레코드가 영구히 잔존하는 문제가 있다.

| 경로 | 문제 |
|---|---|
| `UPDATE` | 이전 버전 OOS 레코드가 삭제되지 않고 남음 |
| `DELETE` + vacuum | vacuum이 heap record를 정리하더라도 OOS 레코드가 orphan으로 잔존 |

### 목적

`spage_delete` 를 통해 OOS 페이지의 슬롯을 물리적으로 삭제하고,
페이지의 `total_free` 를 회수하는 `oos_delete` API를 구현한다.
추후 `spage_compact` 를 통한 in-page compaction에서 이 free 공간을 재활용할 수 있다.

---

## Spec Change

### 신규 함수

| 함수 | 파일 | 설명 |
|---|---|---|
| `oos_delete` | `src/storage/oos_file.cpp` | OOS 레코드 물리 삭제 (신규) |
| `oos_log_delete_physical` | `src/storage/oos_file.cpp` | OOS 삭제 WAL 로깅 내부 헬퍼 (static) |

### 헤더 변경

`src/storage/oos_file.hpp` 에 `oos_delete` 선언 추가:

```cpp
extern int oos_delete (THREAD_ENTRY *thread_p, const VFID &oos_vfid, const OID &oid);
```

### 기존 인프라 활용

| 항목 | 내용 |
|---|---|
| `RVOOS_DELETE` (= 131) | 이미 `recovery.h` 에 정의됨 |
| `oos_rv_redo_delete` | 이미 구현됨 — `spage_delete` 수행 |
| `oos_rv_redo_insert` | 이미 구현됨 — undo 시 레코드 복원에 사용 |

---

## Implementation

### 함수 시그니처

```cpp
int oos_delete (THREAD_ENTRY *thread_p, const VFID &oos_vfid, const OID &oid);
```

### 동작 흐름 (단일 청크)

```
1. OID에서 VPID 추출
2. pgbuf_fix (WRITE latch)
3. spage_get_record (PEEK) → OOS_RECORD_HEADER 읽기
   - next_chunk_oid 확인 (multi-chunk 지원)
4. oos_log_delete_physical 호출 (RVOOS_DELETE, undo=원본 recdes, redo=없음)
5. spage_delete (슬롯 삭제 → total_free 증가)
6. pgbuf_set_dirty + pgbuf_unfix
```

### Multi-chunk 처리

OOS 레코드가 여러 페이지에 걸쳐 있는 경우(across-pages), 첫 번째 청크부터
`next_chunk_oid` 체인을 따라 모든 청크를 순서대로 삭제한다.

```
while (current_oid.pageid != NULL_PAGEID):
    PEEK → next_chunk_oid 확인
    log + spage_delete
    current_oid = next_chunk_oid
```

### WAL 로깅 설계

`RVOOS_DELETE` 로그 레코드 구성:

| 필드 | 내용 |
|---|---|
| `log_addr.pgptr` | 삭제 대상 OOS 페이지 |
| `log_addr.offset` | slotid (redo 시 `oos_rv_redo_delete` 가 이 값 사용) |
| undo data | 원본 RECDES (rollback 시 `oos_rv_redo_insert` 로 재삽입) |
| redo data | 없음 (slotid만으로 redo 가능) |

```cpp
log_append_undoredo_recdes (thread_p, RVOOS_DELETE, &log_addr, recdes_p, NULL);
```

recovery.c 테이블에 이미 등록된 핸들러:
- undo: `oos_rv_redo_insert` (원본 레코드 재삽입)
- redo: `oos_rv_redo_delete` (슬롯 삭제)

### 호출 경로

#### UPDATE 경로 (현재 M1 구현)

```
heap_update
  → heap record를 PEEK/COPY로 읽어 이전 recdes 획득
  → recdes 내 OOS OID 필드에서 이전 OOS OID 추출
  → oos_delete (이전 OOS 레코드 물리 삭제)
  → oos_insert (새 OOS 레코드 삽입)
  → heap record에 새 OOS OID 기록
```

**이전 버전 읽기 메커니즘:**
`heap_update` 진입 시 대상 heap record를 `spage_get_record`(PEEK)로 읽어 현재 recdes를 획득한다.
이 recdes의 OOS OID 필드(heap record 내 고정 위치)에서 기존 OOS 레코드의 위치(VPID + slotid)를 추출하여 `oos_delete` 에 전달한다.

**추후 개선 가능성 — OOS 컬럼 변경 유무에 따른 최적화:**
현재 M1 구현은 OOS 컬럼 변경 여부와 무관하게 항상 `oos_delete` → `oos_insert` 를 수행한다.
만약 UPDATE가 OOS 대상 컬럼을 변경하지 않는 경우(예: inline 컬럼만 변경), OOS 레코드는 그대로 유효하므로 `oos_delete` + `oos_insert` 를 생략하고 기존 OOS OID를 그대로 유지할 수 있다.
이 최적화를 적용하면 OOS 페이지 I/O 및 WAL 로깅을 줄여 UPDATE 성능을 개선할 수 있다.

**MVCC와 OOS 이전 버전 접근:**
UPDATE 시 `oos_delete` 로 이전 OOS 레코드를 즉시 물리 삭제하더라도 MVCC 가시성에는 문제가 없다.
오래된 트랜잭션이 이전 버전을 읽어야 하는 경우, heap record의 LSA(log sequence address)를 통해 로그에서 이전 버전의 heap record를 복원한다.
복원된 heap record에는 이전 OOS OID가 그대로 포함되어 있으므로, 해당 OOS 레코드에 접근할 수 있다.

단, 이는 `oos_delete` 의 undo 로그에 원본 OOS recdes가 기록되어 있기 때문에 가능하다.
로그 기반 복원 경로에서 이전 OOS 레코드가 필요하면, undo 로그를 통해 OOS 레코드 자체도 복원된다.

이 이전 버전 OOS 레코드는 해당 버전을 참조하는 활성 트랜잭션이 모두 종료된 후, vacuum에 의해 최종적으로 정리된다.

**OOS delete 컨텍스트:**
`oos_delete` 는 OOS 페이지에서 슬롯을 `spage_delete` 로 물리 삭제하여 `total_free` 를 회수한다.
Multi-chunk 레코드의 경우 `next_chunk_oid` 체인을 따라 모든 청크를 순차 삭제한다.
삭제 시 undo 로그에 원본 recdes를 기록하므로, rollback 시 `oos_rv_redo_insert` 로 원본을 복원할 수 있다.
회수된 free 공간은 추후 `spage_compact` 또는 새로운 `oos_insert` 시 재활용된다.

#### DELETE + vacuum 경로 (M2 Story 4)

```
vacuum_heap
  → heap record 정리 시
  → (OOS OID 추출)
  → oos_delete 호출
```

---

## Acceptance Criteria

- [ ] `UPDATE` 수행 후 이전 OOS 레코드가 OOS 페이지에서 물리적으로 삭제된다.
- [ ] `spage_delete` 호출 이후 해당 페이지의 `total_free` 가 삭제된 레코드 크기만큼 증가한다.
- [ ] Multi-chunk OOS 레코드(across-pages) 삭제 시 모든 청크가 삭제된다.
- [ ] crash → recovery 후 OOS 페이지 정합성이 유지된다 (undo/redo 정상 동작).
- [ ] 기존 OOS insert / read 기능 regression 없음.

---

## 참고 코드

- `src/storage/oos_file.cpp` — `oos_rv_redo_delete`, `oos_rv_redo_insert`, `oos_log_insert_physical`
- `src/storage/oos_file.hpp` — 함수 선언
- `src/transaction/recovery.h` — `RVOOS_DELETE = 131`
- `src/transaction/recovery.c` — RVOOS_DELETE undo/redo 핸들러 등록 확인
- `src/storage/slotted_page.h` — `spage_delete`
