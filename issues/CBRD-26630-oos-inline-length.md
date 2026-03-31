# [OOS] Heap recdes에 OOS 길이 정보 인라인 저장

## Description

### 배경

현재 OOS 변수 속성이 heap recdes에 저장될 때, 인라인 데이터에는 OOS OID(8바이트)만 저장된다.

이로 인해 OOS 데이터의 실제 크기를 파악해야 하는 경우(예: midxkey 버퍼 크기 추정), `oos_get_length()` 를 호출하여 OOS 페이지를 읽는 **추가 I/O가 발생** 한다.

특히 `heap_midxkey_get_oos_extra_size()` 에서 OOS 컬럼마다 `oos_get_length()` 를 호출하므로, OOS 컬럼이 여러 개인 경우 불필요한 페이지 I/O가 누적된다.

### 목적

- OOS OID 옆에 OOS 데이터 길이(8바이트)를 함께 인라인으로 저장하여, **I/O 없이 OOS 데이터 크기를 파악** 할 수 있도록 한다.
- 인라인 OOS 데이터 포맷: `[OOS OID (8B) | OOS length (8B)]` = 16바이트 (`OR_OOS_INLINE_SIZE`)

---

## Spec Change

### 인라인 OOS 데이터 포맷 변경

| 항목 | 기존 | 변경 후 |
|---|---|---|
| 인라인 크기 | 8바이트 (`OR_OID_SIZE`) | 16바이트 (`OR_OOS_INLINE_SIZE`) |
| 인라인 내용 | OOS OID | OOS OID + OOS length |
| 레코드당 추가 비용 | — | OOS 컬럼당 8바이트 |

### 신규 매크로

| 매크로 | 파일 | 설명 |
|---|---|---|
| `OR_OOS_INLINE_SIZE` | `src/base/object_representation.h` | `OR_OID_SIZE + OR_BIGINT_SIZE` (= 16) |

### 변경 함수

| 함수 | 파일 | 설명 |
|---|---|---|
| `heap_attrinfo_determine_disk_layout()` | `src/storage/heap_file.c` | OOS 컬럼 크기 계산 시 `OR_OID_SIZE` → `OR_OOS_INLINE_SIZE` |
| `heap_attrinfo_insert_to_oos()` | `src/storage/heap_file.c` | OOS 삽입 후 길이 정보를 `oos_lengths` 벡터에 기록 |
| `heap_attrinfo_transform_variable_to_disk()` | `src/storage/heap_file.c` | OOS OID 기록 후 `or_put_bigint(buf, oos_length)` 로 길이도 기록 |
| `heap_attrinfo_transform_columns_to_disk()` | `src/storage/heap_file.c` | `oos_lengths` 벡터 전달 |
| `heap_attrinfo_transform_to_disk_internal()` | `src/storage/heap_file.c` | `oos_lengths` 벡터 선언 및 파이프라인 전달 |
| `heap_midxkey_get_oos_extra_size()` | `src/storage/heap_file.c` | `oos_get_length()` I/O 호출 제거, recdes 인라인 데이터에서 `or_get_bigint()` 로 직접 읽기 |

### 변경 불필요한 부분

- `heap_attrvalue_point_variable()`: `or_get_oid` 가 8바이트만 읽으므로 인라인 포맷 변경에 영향 없음
- `locator_fixup_oos_oids_in_recdes()`: `or_put_oid` 가 8바이트만 덮어쓰므로 뒤의 길이 필드는 보존됨

---

## Implementation

1. `object_representation.h` 에 `OR_OOS_INLINE_SIZE` 매크로 추가
2. `heap_attrinfo_determine_disk_layout()` 에서 OOS 컬럼 디스크 크기를 `OR_OOS_INLINE_SIZE` 로 계산
3. `heap_attrinfo_transform_to_disk_internal()` 에서 `oos_lengths` 벡터를 선언하고 변환 파이프라인에 전달
4. `heap_attrinfo_insert_to_oos()` 에서 `oos_insert` 수행 후 삽입된 데이터 길이를 `oos_lengths` 에 기록
5. `heap_attrinfo_transform_variable_to_disk()` 에서 OOS OID 기록 직후 `or_put_bigint(buf, oos_length)` 로 길이 기록
6. `heap_midxkey_get_oos_extra_size()` 에서 `oos_get_length()` 호출을 제거하고, recdes 인라인 데이터에서 `or_get_bigint()` 로 길이를 직접 읽도록 변경

---

## A/C

- [ ] OOS 컬럼을 포함하는 테이블의 INSERT/UPDATE 후 recdes 인라인 데이터가 `[OOS OID (8B) | length (8B)]` 포맷으로 저장된다.
- [ ] `heap_midxkey_get_oos_extra_size()` 에서 OOS 페이지 I/O가 발생하지 않는다.
- [ ] 다양한 크기(512B, 페이지 경계값, 160KB)에서 인라인 길이와 `oos_get_length()` 기반 길이가 일치한다.
- [ ] 기존 OOS insert / read / update / midxkey 기능 regression 없음.
- [ ] 단위 테스트 3건 통과:
  - `OosInlineFormatWriteAndReadBack`: 직렬화 라운드트립 검증
  - `OosInlineFormatWithRealOosInsert`: 실제 OOS 삽입 후 인라인 길이 일치 검증
  - `OosInlineLengthMatchesAcrossPages`: 다양한 크기에서 정확성 검증

---

## Remarks

- 레코드당 OOS 컬럼마다 8바이트 추가 사용 (기존 8B → 16B)
- CBRD-26565 에서 도입된 `heap_midxkey_get_oos_extra_size()` 의 `oos_get_length()` I/O를 제거하는 후속 최적화
- PR: https://github.com/CUBRID/cubrid/pull/6921
