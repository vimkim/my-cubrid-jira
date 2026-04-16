# [OOS] OOS 내부 API 가독성 개선 (변수명/함수명 리팩토링)

## Description

### 배경
OOS 내부 API의 변수명과 함수명이 모호하여 다른 개발자들이 코드를 이해하는 데 어려움이 있었다.
주요 혼란 포인트:

- **`total_size`**: "전체 크기"가 user data 길이인지, on-disk 크기(헤더 포함)인지 불분명
- **`rec_in` / `rec_out`**: 내부 helper 함수에서 사용되는 파라미터 이름으로, user data인지 on-page 레코드(헤더 포함)인지 구분 불가
- **`oos_make_oos_recdes`**: "oos"가 중복되고, 실제 동작(헤더 prepend)이 이름에서 드러나지 않음
- **`oos_pop_record_header`**: "pop"은 스택 연산을 연상시키지만 실제로는 헤더를 분리(strip)하는 동작

### 목적
OOS 코드의 두 가지 핵심 개념을 명확히 구분하여 가독성을 높인다:
- **`user_recdes`**: 순수 사용자 데이터 (OOS 헤더 미포함)
- **`page_recdes`**: 페이지에 저장되는 형태 (OOS 헤더 + 사용자 데이터)

---

## Implementation

### 구조체 필드 변경

| Before | After | 설명 |
|--------|-------|------|
| `oos_record_header::total_size` | `oos_record_header::total_data_length` | 전체 user data 길이 (OOS 헤더 제외)임을 명확히 표현 |

구조체 각 필드에 설명 주석 추가:
```cpp
struct oos_record_header
{
  int total_data_length;  /* total length of user data across all chunks (excluding OOS headers) */
  int chunk_index;        /* 0-based index of this chunk in the chain */
  OID next_chunk_oid;     /* OID of next chunk, or NULL OID if this is the last */
};
```

### 함수명 및 파라미터 변경

| Before | After | 설명 |
|--------|-------|------|
| `oos_make_oos_recdes(rec_in, header, rec_out)` | `oos_prepend_header(user_recdes, header, page_recdes)` | user data에 OOS 헤더를 붙여 on-page 레코드 생성 |
| `oos_pop_record_header(rec_in, header_out, rec_out)` | `oos_strip_header(page_recdes, header_out, user_recdes)` | on-page 레코드에서 헤더를 분리하여 user data 추출 |

### 내부 변수명 통일

| Before | After | 위치 |
|--------|-------|------|
| `oos_rec` | `page_recdes` | `oos_insert_within_page()` |
| `recdes_with_oos_header` | `page_recdes` | `oos_read_within_page()` |
| `recdes_with_header` | `page_recdes` | `oos_delete_chain()` |
| `peek_recdes` | `page_recdes` | `oos_get_length()` |
| `total_size` (로컬 변수) | `total_data_length` | `oos_insert_across_pages()`, `oos_read_across_pages()` |
| `total_inserted_size` | `total_inserted_length` | `oos_insert_across_pages()` |
| `total_read_size` | `total_read_length` | `oos_read_across_pages()` |

### 변경 범위

- **변경 파일**: `src/storage/oos_file.hpp`, `src/storage/oos_file.cpp`
- **Public API 변경 없음**: `oos_insert`, `oos_read`, `oos_delete`, `oos_get_length` 시그니처 유지
- **외부 호출 코드 변경 없음**: `locator_sr.c`, `heap_file.c` 등은 수정 불필요

---

## Acceptance Criteria

- [x] `oos_record_header::total_size` → `total_data_length` 로 변경
- [x] `oos_make_oos_recdes` → `oos_prepend_header` 로 변경 (파라미터명 포함)
- [x] `oos_pop_record_header` → `oos_strip_header` 로 변경 (파라미터명 포함)
- [x] 내부 변수명 `page_recdes` 로 일관되게 통일
- [x] 구조체 필드에 설명 주석 추가
- [x] 모든 OOS unit test (12개) 통과
- [x] Public API 시그니처 변경 없음

---

## Remarks

- PR: https://github.com/CUBRID/cubrid/pull/7059
- base branch: `feat/oos`
- 이번 변경은 순수 리팩토링으로, 동작 변경 없음 (rename-only)
