# [OOS] `oos_read` 를 caller-preallocated buffer API로 리팩터링

## Description

### 배경

CBRD-26630 에서 heap recdes 의 인라인 OOS 데이터 포맷을 `[OOS OID (8B) | OOS length (8B)]` 로 확장하여, **heap 레코드만 읽어도 OOS 값의 전체 길이를 알 수 있게** 되었다.

그럼에도 `oos_read()` 는 여전히 내부에서 출력 버퍼를 자체 할당하는 구조였다.

- `oos_read (thread_p, oid, recdes)` 가 `recdes_allocate_data_area()` 로 `recdes.data` 를 내부 할당
- 단일 청크 경로: `oos_read_within_page` 가 페이지 슬롯에서 PEEK 후, `oos_pop_record_header` 가 **별도 버퍼를 할당하고 payload 를 memcpy**
- 다중 청크 경로: `oos_read_across_pages` 가 전체 크기만큼 **한 번 더 별도 버퍼를 할당** 한 뒤, 청크마다 또 임시 recdes 를 할당해서 중간 memcpy
- 멀티 청크일 경우 첫 청크가 **중복 읽기** 됨 (먼저 `oos_read_within_page` 에서 한 번, 이후 `oos_read_across_pages` 루프에서 같은 OID 를 다시 한 번)

결과적으로 호출자는 이미 크기를 아는데 호출자 <-> `oos_read` 사이에 한 단계 이상의 잉여 할당/복사가 발생했다.

### 목적

- 호출자가 버퍼를 직접 preallocate 하고, `oos_read` 는 **카피만 수행** 하도록 계약을 바꾼다.
- 중간 임시 recdes 할당/해제 경로를 제거하여 디스크 한 번 읽을 때 할당 건수를 줄인다.
- 멀티 청크에서 첫 청크의 중복 읽기를 제거한다.

---

## Spec Change

### `oos_read` API 계약 변경

| 항목 | 기존 | 변경 후 |
|---|---|---|
| 버퍼 소유권 | callee (`oos_read`) 가 할당 | caller 가 preallocate |
| 입력 요구사항 | `recdes` (미초기화 가능) | `recdes.data != nullptr && recdes.area_size >= OOS 전체 길이` |
| 출력 | `recdes.data` 할당, `recdes.length` 설정 | `recdes.length` / `recdes.type` 만 설정 |
| 해제 책임 | caller 가 `recdes_free_data_area` 호출 | 동일 (caller 가 애초에 할당했으므로) |

### 내부 헬퍼 시그니처 변경

| 함수 | 파일 | 변경 내용 |
|---|---|---|
| `oos_read_within_page` | `src/storage/oos_file.cpp` | `(RECDES &recdes, OOS_RECORD_HEADER &)` → `(char *buf_out, int buf_cap, OOS_RECORD_HEADER &, int &bytes_written)`. 페이지에서 PEEK 한 payload 를 **caller 버퍼에 바로 memcpy** |
| `oos_read_across_pages` | `src/storage/oos_file.cpp` | `(oid, RECDES &recdes, header)` → `(next_oid, first_chunk_header, RECDES &recdes, int &bytes_written)`. 첫 청크는 이미 복사됐다는 전제로 **chunk index 1 부터** 순회 |
| `oos_pop_record_header` | `src/storage/oos_file.cpp` | **제거** (단 1곳에서만 사용되던 임시 버퍼 할당 helper) |

### 호출자 변경

| 함수 | 파일 | 변경 내용 |
|---|---|---|
| `heap_attrvalue_point_variable` | `src/storage/heap_file.c` | OOS OID 를 `or_get_oid` 로 읽은 뒤, 인라인 포맷의 8B 길이 필드를 `or_get_bigint` 으로 읽고, `recdes_allocate_data_area (raw, oos_len)` 로 preallocate 후 `oos_read` 호출 |

### 테스트 마이그레이션

heap 레코드 컨텍스트가 없는 단위 테스트를 위해 test-side 호환 헬퍼 추가.

| 항목 | 위치 | 설명 |
|---|---|---|
| `test_oos_utils::oos_read_with_alloc` | `unit_tests/oos/test_oos_common.hpp` | `oos_get_length()` 로 크기 조회 → `recdes_allocate_data_area` → `oos_read` 순으로 호출하여 기존 "RECDES-out" 계약을 테스트 레벨에서 보존. 실패 시 `recdes.data` 를 `nullptr` 로 남김 |

`test_oos.cpp`, `test_oos_delete.cpp`, `test_oos_remove_file.cpp`, `test_oos_bestspace.cpp` 의 총 24개 직접 호출을 `oos_read_with_alloc` 로 치환.

---

## Implementation

### 1. `oos_read_within_page` 를 raw buffer 기반으로 재작성

```
pgbuf_fix
  -> spage_get_record (PEEK)
  -> memcpy(&header_out, peek.data, OOS_RECORD_HEADER_SIZE)
  -> payload_len = peek.length - OOS_RECORD_HEADER_SIZE
  -> bounds check: buf_cap >= payload_len
  -> memcpy(buf_out, peek.data + OOS_RECORD_HEADER_SIZE, payload_len)
  -> bytes_written = payload_len
```

중간에 `recdes_allocate_data_area` 호출이 **완전히 사라진다**. PEEK 로 얻은 페이지 데이터에서 caller 버퍼로 직접 memcpy.

### 2. `oos_read_across_pages` 에서 첫 청크 중복 읽기 제거

기존 플로우:

```
oos_read
  oos_read_within_page(oid)         # 첫 청크 읽음 -> first_chunk_recdes 할당
  if multi-chunk:
    oos_read_across_pages(oid, ...)   # 첫 청크부터 다시 순회 (재할당, 재 memcpy)
    recdes_free_data_area(first_chunk_recdes)
```

변경 플로우:

```
oos_read
  oos_read_within_page(oid, recdes.data + 0, recdes.area_size)
    # 첫 청크를 caller 버퍼 오프셋 0에 직접 기록
  if multi-chunk:
    oos_read_across_pages(first_chunk_header.next_chunk_oid, ...)
    # chunk index 1부터 순회, 각 청크는 recdes.data + bytes_written 에 직접 기록
```

### 3. 호출자 `heap_attrvalue_point_variable` 에서 inline 길이 소비

```c
or_get_oid (&buf, &oos_oid);
DB_BIGINT oos_len = or_get_bigint (&buf, &rc);   /* M2 inline layout: OID(8B) + len(8B) */
assert (rc == NO_ERROR);
assert (oos_len > 0);

recdes_allocate_data_area (raw, (int) oos_len);
oos_read (thread_p, oos_oid, *raw);
```

기존에 `is_oos` 블록 바깥에서 caller 가 `raw` 를 해제하던 플로우는 그대로 유지되므로 (allocator 가 단지 callee → caller 로 이동했을 뿐) 상위 로직은 변경 불필요.

### 4. 불변식 / 어서션

- `oos_read` 진입 시: `recdes.data != nullptr`, `recdes.area_size > 0`
- `oos_read_within_page` 내부: `buf_cap >= payload_len`, 위반 시 `er_set(ER_GENERIC_ERROR)` + `assert`
- `oos_read` 종료 시: `bytes_written == first_chunk_header.total_size`, `recdes.area_size >= total_size`

---

## Before / After Flow (length가 어디서 오는가)

핵심: **length 는 누가, 언제, 어디에서 알아내는가**.

### Before (M1 직후)

length 는 OOS 페이지를 직접 읽고 나서야 알 수 있고, 그것도 `oos_read` 가 알아낸 길이로 자기 버퍼를 할당했다.

```
heap recdes (variable area, 한 OOS 컬럼)
  ┌──────────────────────────┐
  │ OOS OID (8B)             │   <- length 정보 없음
  └──────────────────────────┘

heap_attrvalue_point_variable(recdes, attrepr, raw, &is_oos)
   │
   │   length unknown — caller 는 크기 모름
   ▼
oos_read(thread_p, oid, RECDES &recdes /* uninit */)
   │
   ├─ oos_read_within_page(oid, RECDES &out, header)
   │     │
   │     ├─ pgbuf_fix(page)
   │     ├─ spage_get_record(PEEK) ─► peek_recdes (page에 있는 raw)
   │     │                            └─ peek.length = HDR + payload
   │     │                                  ▲
   │     │                                  └── length 를 여기서 알아냄
   │     │
   │     └─ oos_pop_record_header(peek_recdes, header, out)
   │           ├─ recdes_allocate_data_area(out, peek.length - HDR)   ◄─ alloc #1
   │           └─ memcpy(out.data, peek.data + HDR, payload_len)      ◄─ memcpy #1
   │
   ├─ if (next_chunk != NULL)
   │     │
   │     ├─ recdes_allocate_data_area(recdes, header.total_size)      ◄─ alloc #2
   │     │     ▲ length 를 header.total_size 에서 다시 가져옴
   │     │
   │     └─ oos_read_across_pages(oid /* 첫 OID 부터 다시! */, ...)
   │           │
   │           └─ for chunk in [0, 1, 2, ...]:        ◄─ 첫 청크 중복 읽기
   │                 oos_read_within_page(...)        ◄─ alloc #3..N (청크당)
   │                 memcpy(recdes.data + off, chunk.data, len)  ◄─ memcpy #2..N
   │                 recdes_free_data_area(chunk)
   │
   └─ caller 는 raw->data 로 받음 → 사용 후 recdes_free_data_area(raw)

비용 요약 (multi-chunk N개일 때):
  - alloc 횟수: 2 + N  (페이로드 임시 1 + 최종 1 + 청크별 N)
  - memcpy 횟수: 1 + N  (첫 청크 두 번 읽힘)
  - 페이지 fix: N + 1   (첫 청크 fix 가 두 번)
```

### After (이 PR)

length 는 **heap recdes 인라인 (CBRD-26630)** 에 8B 로 들어 있어, OOS 페이지를 단 한 번도 만지기 전에 caller 가 안다.

```
heap recdes (variable area, 한 OOS 컬럼)
  ┌──────────────────────────┬──────────────────────────┐
  │ OOS OID (8B)             │ OOS full_length (8B)     │
  └──────────────────────────┴──────────────────────────┘
                                    ▲
                                    └── length 를 여기서 바로 읽음 (zero I/O)

heap_attrvalue_point_variable(recdes, attrepr, raw, &is_oos)
   │
   ├─ or_get_oid(&buf, &oos_oid)            ─► OID
   ├─ oos_len = or_get_bigint(&buf, &rc)    ─► length  ◄── inline에서 바로
   │
   ├─ recdes_allocate_data_area(raw, oos_len)         ◄─ alloc 단 1회 (caller 측)
   │     ▲ caller 가 정확한 크기로 미리 할당
   │
   └─ oos_read(thread_p, oos_oid, *raw /* preallocated */)
         │
         │ assert(raw.data != nullptr && raw.area_size >= oos_len)
         │
         ├─ oos_read_within_page(oid, raw.data + 0, raw.area_size, header, &written)
         │     │
         │     ├─ pgbuf_fix(page)
         │     ├─ spage_get_record(PEEK) ─► peek_recdes
         │     ├─ memcpy(&header, peek.data, HDR)
         │     └─ memcpy(raw.data + 0, peek.data + HDR, peek.length - HDR)  ◄─ caller buf로 직접
         │           ▲ alloc 없음, 임시 recdes 없음
         │
         └─ if (header.next_chunk_oid != NULL)
               │
               └─ oos_read_across_pages(header.next_chunk_oid /* 청크 1 부터 */, ...)
                     │
                     └─ for chunk_idx in [1, 2, ..., N-1]:   ◄─ 청크 0 은 이미 끝
                           oos_read_within_page(
                               next_oid,
                               raw.data + written,           ◄─ 같은 caller buf, 오프셋만 이동
                               raw.area_size - written,
                               header, &chunk_bytes)
                           written += chunk_bytes

assert(written == header.total_size == oos_len)
   ▲
   └── caller 가 인라인에서 미리 읽은 oos_len 과
       OOS 페이지 헤더의 total_size 가 일치해야 함 (corruption check)

비용 요약 (multi-chunk N개일 때):
  - alloc 횟수: 1   (caller 가 한 번에 정확한 크기로)
  - memcpy 횟수: N  (청크당 1회, 임시 버퍼 경유 없이 caller 버퍼로 직접)
  - 페이지 fix: N   (첫 청크 중복 fix 제거)
```

### Length 흐름 한눈에

| 단계 | Before | After |
|---|---|---|
| caller 가 length 를 인지하는 시점 | 알 수 없음 (callee 가 알려줌) | `or_get_bigint` 직후 (heap recdes 만 보고) |
| length 의 source | `header.total_size` (OOS 페이지 fix 후) | heap recdes 인라인 8B (zero I/O) |
| 버퍼 할당 주체 | callee (`oos_read`) | caller (`heap_attrvalue_point_variable`) |
| 버퍼 할당 횟수 (N-청크) | `2 + N` | `1` |
| 검증 어서션 | 없음 | `oos_len == header.total_size == bytes_written` |

---

## A/C

- [ ] `oos_read` 는 caller 가 `recdes.data` / `recdes.area_size` 를 세팅하지 않으면 assert 로 실패한다.
- [ ] `heap_attrvalue_point_variable` 가 인라인 포맷의 8B 길이로 buffer 를 preallocate 한 뒤 `oos_read` 를 호출한다.
- [ ] 단일 청크 / 다중 청크 OOS 값 모두 read 가 정상 동작한다 (value equality).
- [ ] 다중 청크 경로에서 첫 청크가 더 이상 중복 읽히지 않는다 (코드 경로상 `oos_read_within_page` 호출은 첫 청크 1회 + 나머지 청크 N-1회).
- [ ] `oos_pop_record_header` 가 제거되어도 빌드 경고/링크 에러가 없다.
- [ ] 기존 OOS 단위 테스트 (`test_oos`, `test_oos_delete`, `test_oos_remove_file`, `test_oos_bestspace`) 가 `oos_read_with_alloc` 헬퍼로 마이그레이션되어 모두 통과한다.
- [ ] OOS SQL 단위 테스트 (`test_oos_sql_crud`, `test_oos_sql_ddl`, `test_oos_sql_delete`, `test_oos_sql_boundary`, `test_oos_sql_update_delete`, `test_oos_sql_txn`) 모두 통과한다.
- [ ] `just test` 결과 100% 통과 (12 / 12).

---

## Remarks

- 선행 조건: CBRD-26630 (OOS inline length, 8B) — 인라인에 길이가 저장되어야만 caller 가 preallocate 할 크기를 알 수 있음.
- M1 제약 사항 목록의 **"No PEEK mode for OOS reads — Always COPY semantics, extra memcpy"** 중 "extra memcpy" 를 줄이는 중간 단계. 완전한 PEEK 모드 (`oos_insert(OID)` → `oos_read(PAGE_PTR, slotid, PEEK/COPY)` 리팩터링, DB_VALUE zero-copy) 는 여전히 후속 작업.
- 테스트 헬퍼 `oos_read_with_alloc` 는 단위 테스트 전용이며 프로덕션 코드에서는 사용하지 않는다. heap 레코드가 없는 테스트 특성상 `oos_get_length()` I/O 로 크기를 얻어야 하기 때문.
- PR: (추가 예정)

---

## 참고 코드

- `src/storage/oos_file.cpp` — `oos_read`, `oos_read_within_page`, `oos_read_across_pages`
- `src/storage/oos_file.hpp` — `oos_read`, `oos_get_length` 선언
- `src/storage/heap_file.c` — `heap_attrvalue_point_variable`, `heap_attrinfo_get_variable_oos_length`
- `src/base/object_representation.h` — `OR_OOS_INLINE_SIZE`, `or_get_bigint`
- `unit_tests/oos/test_oos_common.hpp` — `test_oos_utils::oos_read_with_alloc`
