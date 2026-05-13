# [OOS] `oos_read` / `oos_insert` 를 `oos_buffer` (caller-owned span) API로 리팩터링

## Description

### 배경

CBRD-26630 에서 heap recdes 의 인라인 OOS 데이터 포맷을 `[OOS OID (8B) | OOS length (8B)]` 로 확장하여, **heap 레코드만 읽어도 OOS 값의 전체 길이를 알 수 있게** 되었다.

그럼에도 `oos_read()` 는 여전히 내부에서 출력 버퍼를 자체 할당하는 구조였다.

- `oos_read (thread_p, oid, recdes)` 가 `recdes_allocate_data_area()` 로 `recdes.data` 를 내부 할당
- 단일 청크 경로: `oos_read_within_page` 가 페이지 슬롯에서 PEEK 후, `oos_pop_record_header` 가 **별도 버퍼를 할당하고 payload 를 memcpy**
- 다중 청크 경로: `oos_read_across_pages` 가 전체 크기만큼 **한 번 더 별도 버퍼를 할당** 한 뒤, 청크마다 또 임시 recdes 를 할당해서 중간 memcpy
- 멀티 청크일 경우 첫 청크가 **중복 읽기** 됨 (먼저 `oos_read_within_page` 에서 한 번, 이후 `oos_read_across_pages` 루프에서 같은 OID 를 다시 한 번)

`oos_insert` 쪽도 마찬가지로 `RECDES &recdes` 를 받았는데, 내부적으로 사용하는 필드는 `.data`/`.length` 둘뿐이고 `.type`/`.area_size` 는 무시되거나 (insert) 잠시 가짜로 채워야 했다 (read 의 scratch fast path 에서 `area_size` 를 거짓말로 세팅). 즉, 두 API 모두 **"가변 바이트 영역"** 만 필요한데 RECDES 가 끼어들면서 area_size 책임이 모호해졌다.

결과적으로 호출자는 이미 크기를 아는데 호출자 <-> `oos_read`/`oos_insert` 사이에 한 단계 이상의 잉여 할당/복사와 RECDES area_size 거짓말이 발생했다.

### 목적

- `oos_read` / `oos_insert` 모두 **caller-owned byte span** 을 받도록 계약을 통일한다. RECDES area_size 거짓말 없이, 페이로드 길이는 span.size() 가 단일 진실원이 된다.
- 호출자가 버퍼를 직접 preallocate 하고, `oos_read` 는 **카피만 수행** 하도록 계약을 바꾼다.
- 중간 임시 recdes 할당/해제 경로를 제거하여 디스크 한 번 읽을 때 할당 건수를 줄인다.
- 멀티 청크에서 첫 청크의 중복 읽기를 제거한다.
- 멀티 청크 read 의 overflow 가드를 **하나의 cursor 객체** (`byte_span_writer`) 에 모아 invariant 위반을 구조적으로 차단한다.

---

## Spec Change

### `oos_buffer` 알리어스 (신규)

```cpp
// src/storage/oos_file.hpp
using oos_buffer = cubbase::span<char>;
```

`cubbase::span<char>` 의 named alias. 의도는 두 가지:

1. **의미 명시**: "OOS 페이로드 교환용 byte span" 임을 시그니처에서 바로 읽힌다. `oos_read` 가 dest 로, `oos_insert` 가 src 로 받는 동일 타입.
2. **C 포매터 회피**: `.c` 파일은 C++17 로 컴파일되지만 GNU `indent` 로 포매팅된다. `cubbase::span<char> (data, len)` 은 `< char >` 사이 공백 삽입으로 망가지지만 `oos_buffer (data, len)` 은 일반 함수 호출로 인식되어 안전.

길이 의미: `span.size()` 가 페이로드의 단일 진실원. `RECDES.area_size` 와 무관하므로 caller 는 더 큰 scratch 버퍼를 span 으로 좁혀 넘길 수 있고, area_size 를 거짓말로 채울 필요가 없다.

### `byte_span_writer` (신규)

```cpp
// src/base/byte_span_writer.hpp
class byte_span_writer { ... };
```

`cubbase::span<char>` 위에 append-only 커서를 얹은 작은 RAII 헬퍼. 멀티 청크 read 의 overflow 가드를 한 곳에 모으는 게 목적.

- 유일한 mutator 는 `append(src, len)` — bounds check 가 실패하면 `false` 를 반환하고 커서는 전진하지 않는다.
- invariant `0 <= written <= capacity` 하나로, 기존에 손으로 동기화하던 세 카운터 (`expected_length` / `remaining` / `bytes_written`) 를 대체.
- 리뷰 #7097 에서 지적된 `expected_length -= bytes_written` 누락 같은 손-동기화 버그를 구조적으로 차단.

### `oos_read` API 계약 변경

| 항목 | 기존 | 변경 후 |
|---|---|---|
| 시그니처 | `oos_read (thread_p, oid, RECDES &recdes)` | `oos_read (thread_p, oid, oos_buffer dest)` |
| 버퍼 소유권 | callee (`oos_read`) 가 할당 | caller 가 preallocate, span 으로 전달 |
| 입력 요구사항 | `recdes` (미초기화 가능) | `dest.data() != nullptr && dest.size() == OOS 전체 길이` |
| 길이 검증 | (없음) | `dest.size()` 와 OOS chain header 의 `total_data_length` 가 일치해야 하며, 불일치 시 corruption 으로 처리 |
| 해제 책임 | caller 가 `recdes_free_data_area` 호출 | caller 가 본인 버퍼 관리 (span 은 view 일 뿐) |

### `oos_insert` API 계약 변경 (oos_read 와 미러)

| 항목 | 기존 | 변경 후 |
|---|---|---|
| 시그니처 | `oos_insert (thread_p, vfid, RECDES &recdes, OID &oid)` | `oos_insert (thread_p, vfid, oos_buffer src, OID &oid)` |
| 입력 의미 | `recdes.data`/`recdes.length` 만 사용, `recdes.type`/`recdes.area_size` 는 호출자가 채워야 했지만 실제로는 무시됨 | `src.data()`/`src.size()` 만 사용 — 군더더기 필드 없음 |
| 호출자 측 부수효과 | replication apply 경로(`locator_sr.c`)는 OOS 헤더를 스킵하려고 caller `recdes->data`/`length`/`type` 을 in-place 로 mutate | span 오프셋 한 줄로 헤더 스킵 — caller RECDES 무손상 |

### 내부 헬퍼 시그니처 변경

| 함수 | 파일 | 변경 내용 |
|---|---|---|
| `oos_read_within_page` | `src/storage/oos_file.cpp` | `(RECDES &recdes, OOS_RECORD_HEADER &)` → `(byte_span_writer &writer, OOS_RECORD_HEADER &header_out)`. PEEK 한 payload 를 `writer.append()` 로 caller span 에 직접 복사하며, bounds 위반은 writer 가 차단 |
| `oos_read_across_pages` | `src/storage/oos_file.cpp` | `(oid, RECDES &recdes, header)` → `(next_oid, total_data_length, byte_span_writer &writer)`. 첫 청크는 이미 복사됐다는 전제로 **chunk index 1 부터** 순회 |
| `oos_insert_within_page` / `oos_insert_across_pages` / `oos_prepend_header` | `src/storage/oos_file.cpp` | `RECDES &recdes` → `oos_buffer src`. 특히 across_pages 의 청크 분할이 per-iteration `RECDES chunk_recdes{}` boilerplate → 1줄 span 생성으로 단순화 |
| `oos_pop_record_header` | `src/storage/oos_file.cpp` | **제거** (단 1곳에서만 사용되던 임시 버퍼 할당 helper) |

### 호출자 변경

| 함수 | 파일 | 변경 내용 |
|---|---|---|
| `heap_attrvalue_point_variable` / `heap_attrvalue_read_oos_inline` | `src/storage/heap_file.c` | OOS OID 를 `or_get_oid` 로 읽은 뒤, 인라인 포맷의 8B 길이 필드를 `or_get_bigint` 으로 읽고, scratch 버퍼 또는 `recdes_allocate_data_area` 로 preallocate 후 `oos_read (thread_p, oid, oos_buffer (raw->data, oos_len))` 호출. scratch fast path 에서 더 이상 `raw->area_size` 를 거짓말로 채우지 않음 (`span.size()` 가 길이 진실원) |
| heap insert path (OOS 쓰기) | `src/storage/heap_file.c` | RECDES 를 `heap_attrinfo_dbvalue_to_recdes` 로 채운 뒤, `oos_insert(thread_p, vfid, oos_buffer (recdes.data, recdes.length), oid)` 로 호출. RECDES 는 dbvalue→bytes 변환에만 사용되고 API 경계에서 span 으로 좁혀짐 |
| `locator_oos_insert_force` | `src/transaction/locator_sr.c` | 로그 레코드에서 받은 `recdes` 의 OOS 헤더 스킵을 **caller 의 `recdes->data`/`length`/`type` mutate** → **`oos_buffer (recdes->data + HDR, recdes->length - HDR)` 로 view 한 줄** 로 변경. caller 데이터 무손상 |

### 테스트 마이그레이션

heap 레코드 컨텍스트가 없는 단위 테스트를 위해 test-side 호환 헬퍼 추가.

| 항목 | 위치 | 설명 |
|---|---|---|
| `test_oos_utils::oos_read_with_alloc` | `unit_tests/oos/test_oos_common.hpp` | `oos_get_length()` 로 크기 조회 → `recdes_allocate_data_area` → `oos_read(span)` 순으로 호출하여 기존 "RECDES-out" 계약을 테스트 레벨에서 보존. 실패 시 `recdes.data` 를 `nullptr` 로 남김 |
| `test_oos_utils::oos_insert_from_recdes` | `unit_tests/oos/test_oos_common.hpp` | 테스트에서 자연스럽게 생성되는 `RECDES` 를 `oos_buffer (recdes.data, recdes.length)` 로 좁혀 `oos_insert` 호출. 4개 테스트 파일의 ~60개 직접 호출이 헬퍼 1개로 통일 |

`test_oos.cpp`, `test_oos_delete.cpp`, `test_oos_remove_file.cpp`, `test_oos_bestspace.cpp` 의 read 호출 24개와 insert 호출 60여 개를 각각 위 두 헬퍼로 치환.

---

## Implementation

### 1. `oos_read_within_page` 를 `byte_span_writer` 기반으로 재작성

```
pgbuf_fix
  -> spage_get_record (PEEK)
  -> memcpy(&header_out, peek.data, OOS_RECORD_HEADER_SIZE)
  -> payload_len = peek.length - OOS_RECORD_HEADER_SIZE
  -> writer.append(peek.data + OOS_RECORD_HEADER_SIZE, payload_len)
     (bounds check 는 writer 내부에서 — capacity 초과 시 false, 커서 unchanged)
```

중간에 `recdes_allocate_data_area` 호출이 **완전히 사라진다**. PEEK 로 얻은 페이지 데이터에서 caller span 으로 직접 memcpy 하며, overflow 가드는 `byte_span_writer` 의 구조적 invariant 가 담당.

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

### 3. 호출자 `heap_attrvalue_point_variable` 에서 inline 길이 소비 + span 으로 호출

```c
or_get_oid (&buf, &oos_oid);
DB_BIGINT oos_len = or_get_bigint (&buf, &rc);   /* M2 inline layout: OID(8B) + len(8B) */
assert (rc == NO_ERROR);
assert (oos_len > 0 && oos_len <= (DB_BIGINT) INT_MAX);

/* scratch fast path: oos_len 이 caller scratch 에 들어가면 alloc 생략.
 * span.size() 가 길이 진실원이므로 더 이상 area_size 를 거짓말로 채우지 않는다. */
if (oos_scratch != NULL && oos_len <= (DB_BIGINT) oos_scratch_size)
  {
    raw->data = oos_scratch;
    raw->area_size = oos_scratch_size;   /* truthful capacity, not the lie */
  }
else
  {
    recdes_allocate_data_area (raw, (int) oos_len);
  }
oos_read (thread_p, oos_oid, oos_buffer (raw->data, (std::size_t) oos_len));
```

### 4. `oos_insert` 미러 리팩터링 (oos_read 와 대칭)

`oos_read` 가 caller-owned span 으로 바뀐 김에, `oos_insert` 도 같은 모양으로 통일.

```c
/* heap_file.c (insert path) */
heap_attrinfo_dbvalue_to_recdes (..., &recdes);   /* recdes 는 dbvalue→bytes 변환용 */
oos_insert (thread_p, oos_vfid,
            oos_buffer (recdes.data, (size_t) recdes.length), oos_oid);

/* locator_sr.c (replication apply) */
/* before: caller recdes 를 mutate 해서 헤더 스킵
 *   recdes->data   += OOS_RECORD_HEADER_SIZE;
 *   recdes->length -= OOS_RECORD_HEADER_SIZE;
 *   recdes->type    = REC_HOME;
 *   oos_insert (thread_p, oos_vfid, *recdes, oos_oid);
 * after: span 오프셋 한 줄, caller 데이터 무손상 */
oos_buffer payload (recdes->data + OOS_RECORD_HEADER_SIZE,
                    (size_t) (recdes->length - OOS_RECORD_HEADER_SIZE));
oos_insert (thread_p, oos_vfid, payload, oos_oid);
```

`oos_insert_across_pages` 내부의 청크 분할 루프도 매 iteration `RECDES chunk_recdes{}` boilerplate → `src.subspan (i * max, max)` 한 줄로 단순화. `subspan` 이 offset 의 bounds assert 와 마지막 청크의 tail clamping (`count > remaining` 이면 `remaining` 으로 좁힘) 을 모두 책임지므로 `std::min` 으로 손-계산하던 chunk_len 자체가 사라진다.

### 5. 불변식 / 어서션

- `oos_read` 진입 시: `dest.data() != nullptr`, `dest.size() > 0`
- `oos_read_within_page` 내부: `writer.append()` 의 capacity check (writer invariant: `0 <= written <= capacity`); 위반 시 `er_set(ER_GENERIC_ERROR)` + `assert`
- `oos_read` 종료 시: `writer.full()` (즉 `writer.written() == dest.size() == first_chunk_header.total_data_length`)
- `oos_insert` 진입 시: `src.data() != nullptr`, `src.size() > 0`

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
   └─ oos_read(thread_p, oos_oid, oos_buffer (raw.data, oos_len))
         │     ▲ caller-owned span, size() 가 길이 진실원
         │
         │ assert(dest.data() != nullptr && dest.size() > 0)
         │ byte_span_writer writer(dest)   ◄─ append-only cursor, invariant 0<=written<=cap
         │
         ├─ oos_read_within_page(oid, writer, header_out)
         │     │
         │     ├─ pgbuf_fix(page)
         │     ├─ spage_get_record(PEEK) ─► peek_recdes
         │     ├─ memcpy(&header_out, peek.data, HDR)
         │     └─ writer.append(peek.data + HDR, peek.length - HDR)  ◄─ caller span 로 직접
         │           ▲ alloc 없음, 임시 recdes 없음, bounds 위반은 writer 가 false 반환
         │
         ├─ assert (first_header.total_data_length == oos_len)   ◄─ chain header vs caller len
         │
         └─ if (first_header.next_chunk_oid != NULL)
               │
               └─ oos_read_across_pages(first_header.next_chunk_oid /* 청크 1 부터 */,
                                        total_data_length, writer)
                     │
                     └─ for chunk_idx in [1, 2, ..., N-1]:   ◄─ 청크 0 은 이미 끝
                           oos_read_within_page(next_oid, writer, header)
                           # writer 가 자체 커서로 다음 오프셋을 추적

assert(writer.full())   ◄─ writer.written() == dest.size() == oos_len
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

- [x] `oos_read` 는 caller 가 `dest.data() != nullptr && dest.size() > 0` 을 충족하지 않으면 assert 로 실패한다 (`oos_buffer` 시그니처).
- [x] `oos_read` 의 OOS chain header `total_data_length` 와 caller `dest.size()` 가 불일치하면 corruption 으로 처리한다.
- [x] `heap_attrvalue_point_variable` 가 인라인 포맷의 8B 길이로 buffer 를 preallocate 하고 `oos_buffer (raw->data, oos_len)` 로 호출한다. scratch fast path 에서 `area_size` 를 더 이상 거짓말로 채우지 않는다.
- [x] 단일 청크 / 다중 청크 OOS 값 모두 read 가 정상 동작한다 (value equality).
- [x] 다중 청크 경로에서 첫 청크가 더 이상 중복 읽히지 않는다 (코드 경로상 `oos_read_within_page` 호출은 첫 청크 1회 + 나머지 청크 N-1회).
- [x] `oos_pop_record_header` 가 제거되어도 빌드 경고/링크 에러가 없다.
- [x] `oos_insert` 도 `oos_buffer src` 를 받도록 통일된다. caller 의 `RECDES.type`/`area_size` 책임이 사라진다.
- [x] `locator_oos_insert_force` (`locator_sr.c`) 는 caller 의 `*recdes` 를 mutate 하지 않고 span 오프셋으로 헤더를 스킵한다.
- [x] `byte_span_writer` 는 단일 `append()` mutator + invariant `0 <= written <= capacity` 만으로 멀티 청크 read 의 overflow 가드를 책임진다. 7개의 단위 테스트 (`test_byte_span_writer`) 통과.
- [x] 기존 OOS 단위 테스트 (`test_oos`, `test_oos_delete`, `test_oos_remove_file`, `test_oos_bestspace`) 가 `oos_read_with_alloc` / `oos_insert_from_recdes` 헬퍼로 마이그레이션되어 모두 통과한다.
- [x] OOS SQL 단위 테스트 (`test_oos_sql_crud`, `test_oos_sql_ddl`, `test_oos_sql_delete`, `test_oos_sql_boundary`, `test_oos_sql_update_delete`, `test_oos_sql_txn`) 모두 통과한다.
- [x] `just build-test` 결과 100% 통과 (13 / 13, byte_span_writer 추가 포함).

---

## Remarks

- 선행 조건: CBRD-26630 (OOS inline length, 8B) — 인라인에 길이가 저장되어야만 caller 가 preallocate 할 크기를 알 수 있음.
- M1 제약 사항 목록의 **"No PEEK mode for OOS reads — Always COPY semantics, extra memcpy"** 중 "extra memcpy" 를 줄이는 중간 단계. 완전한 PEEK 모드 (`oos_insert(OID)` → `oos_read(PAGE_PTR, slotid, PEEK/COPY)` 리팩터링, DB_VALUE zero-copy) 는 여전히 후속 작업.
- 테스트 헬퍼 `oos_read_with_alloc` / `oos_insert_from_recdes` 는 단위 테스트 전용이며 프로덕션 코드에서는 사용하지 않는다. 프로덕션은 heap 레코드의 인라인 길이 (read) 와 dbvalue→bytes 변환 결과 (insert) 가 자연스럽게 span 의 source/dest 가 된다.
- `oos_buffer` 가 mutable `cubbase::span<char>` 인 이유는 단일 알리어스로 read dest / insert src 양방향을 모두 커버하기 위함. `oos_insert` 는 시그니처상 받아도 본문에서 절대 mutate 하지 않음을 시그니처 코멘트로 명시했다. 별도 `oos_view = span<const char>` 알리어스를 두는 안은 C-file indent 포매터의 angle-bracket 망가짐을 두 번 처리해야 해서 보류.
- PR: https://github.com/CUBRID/cubrid/pull/7097

---

## 참고 코드

- `src/storage/oos_file.hpp` — `oos_buffer` alias, `oos_read` / `oos_insert` 선언, `oos_get_length` 선언
- `src/storage/oos_file.cpp` — `oos_read` / `oos_read_within_page` / `oos_read_across_pages`, `oos_insert` / `oos_insert_within_page` / `oos_insert_across_pages` / `oos_prepend_header`
- `src/base/byte_span_writer.hpp` — `cubbase::byte_span_writer` (신규)
- `src/base/span.hpp` — `cubbase::span<T>` (기존, `oos_buffer` 의 기반)
- `src/storage/heap_file.c` — `heap_attrvalue_point_variable`, `heap_attrvalue_read_oos_inline`, OOS insert 경로
- `src/transaction/locator_sr.c` — `locator_oos_insert_force` (replication apply)
- `src/base/object_representation.h` — `OR_OOS_INLINE_SIZE`, `or_get_bigint`
- `unit_tests/oos/test_oos_common.hpp` — `test_oos_utils::oos_read_with_alloc`, `test_oos_utils::oos_insert_from_recdes`
- `unit_tests/oos/test_byte_span_writer.cpp` — `byte_span_writer` 단위 테스트 (overflow / 0-cap / 회복 / off-by-one)
