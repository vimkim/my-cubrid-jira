# [OOS] OOS 내부 API 가독성 개선 PR 종합 (`OOS_RECDES` alias + 명명 리팩토링)

## Description

### 배경

OOS 내부 API 의 변수명/함수명이 모호하여 코드 리뷰와 유지보수가 어려웠다.
구체적으로 다음 문제가 있었다.

- **`total_size`** — "전체 크기" 가 user data 길이인지 on-disk 크기(헤더 포함)인지 불분명
- **`rec_in` / `rec_out`** — helper 함수 파라미터가 user data 인지 on-page 레코드인지 구분 불가
- **`oos_make_oos_recdes`** — "oos" 가 중복되고, 실제 동작(header prepend)이 이름에서 드러나지 않음
- **`oos_pop_record_header`** — "pop" 은 스택 연산을 연상시키지만 실제 동작은 header strip
- **`RECDES`** — OOS 맥락에서 "헤더가 포함된 on-page 레코드" 와 "순수 user data" 두 가지 의미로 혼용됨

초기 리팩토링에서는 `user_` / `page_` 접두사를 도입했지만, maintainer 리뷰에서
"새 접두사 대신 익숙한 용어(`recdes`) 를 유지하고, 헤더가 포함된 경우만 `oos_` 로 구분하자"
는 피드백이 있어 최종적으로 `OOS_RECDES` type alias 방식으로 재조정하였다.

### 목적

- 혼동이 되던 두 가지 RECDES 개념을 **시그니처 레벨에서 문서화** 한다:
  - `RECDES` — OOS 헤더가 포함되지 않은 user data
  - `OOS_RECDES` — OOS 헤더가 앞에 붙은 on-page 레코드 (alias of `RECDES`)
- 함수명이 실제 동작(prepend / strip)과 일치하도록 rename 한다.
- 구조체 필드명과 로컬 변수명이 측정하는 대상(user data length vs on-disk size)을
  명확히 드러내도록 한다.
- Input 전용 파라미터에 `const` 를 적용하여 읽기/쓰기 의도를 명시한다.

---

## Implementation

본 PR 은 2 개의 커밋으로 구성된다.

| Commit | 내용 |
|--------|------|
| `06f1826d1` | `[CBRD-26714] Improve OOS API readability with clearer naming` — 1차 rename |
| `d55081aac` | `[CBRD-26714] Introduce OOS_RECDES alias for on-page records` — 리뷰 피드백 반영 |

### `OOS_RECDES` alias 도입

`src/storage/oos_file.hpp` 에 documentation-only alias 추가.

```cpp
/* Alias for a RECDES whose first OOS_RECORD_HEADER_SIZE bytes are the OOS header.
 * Documentation only — no compile-time distinction from RECDES. */
using OOS_RECDES = RECDES;
```

> **Note**: 이 alias 는 **문서화 목적** 이며 컴파일 타임 타입 검사를 제공하지 않는다.
> 강제 타입 분리가 필요해지면 `struct OOS_RECDES { RECDES inner; };` 형태로 승격 가능하나,
> 모든 call site 에 부담을 주므로 이번에는 alias 로 유지한다.

### 구조체 필드 변경

| Before | After | 설명 |
|--------|-------|------|
| `oos_record_header::total_size` | `oos_record_header::total_data_length` | 모든 chunk 를 합친 user data 길이 (OOS 헤더 제외) |

각 필드에 설명 주석 추가:

```cpp
struct oos_record_header
{
  int total_data_length;   /* total length of user data across all chunks (excluding OOS headers) */
  int chunk_index;         /* 0-based index of this chunk in the chain */
  OID next_chunk_oid;      /* OID of next chunk, or NULL OID if this is the last */
};
```

### 함수 시그니처 변경

| Before | After |
|--------|-------|
| `oos_make_oos_recdes(RECDES &rec_in, const OOS_RECORD_HEADER &, RECDES &rec_out)` | `oos_prepend_header(const RECDES &recdes, const OOS_RECORD_HEADER &, OOS_RECDES &oos_recdes)` |
| `oos_pop_record_header(RECDES &rec_in, OOS_RECORD_HEADER &, RECDES &rec_out)` | `oos_strip_header(const OOS_RECDES &oos_recdes, OOS_RECORD_HEADER &, RECDES &recdes)` |

주요 개선점:

- 함수명이 동작(prepend / strip)을 그대로 표현
- 헤더가 포함된 쪽은 `OOS_RECDES`, user data 쪽은 plain `RECDES` 로 표기
- Input 전용 파라미터에 `const` 적용

### 내부 변수명 통일

`spage_get_record` / `spage_insert` 호출 주변에서 사용되던 각기 다른 임시 이름들을
`oos_recdes` 로 일괄 통일하고 타입도 `OOS_RECDES` 로 선언.

| Before | After | 위치 |
|--------|-------|------|
| `oos_rec` | `oos_recdes` | `oos_insert_within_page()` |
| `recdes_with_oos_header` | `oos_recdes` | `oos_read_within_page()` |
| `recdes_with_header` | `oos_recdes` | `oos_delete_chain()` |
| `peek_recdes` | `oos_recdes` | `oos_get_length()` |
| `defer_oos_rec_free` | `defer_oos_recdes_free` | `oos_insert_within_page()` 의 `scope_exit` |
| `total_size` (지역변수) | `total_data_length` | `oos_insert_across_pages()`, `oos_read_across_pages()` |
| `total_inserted_size` | `total_inserted_length` | `oos_insert_across_pages()` |
| `total_read_size` | `total_read_length` | `oos_read_across_pages()` |

### 변경 범위

- **변경 파일**: `src/storage/oos_file.hpp`, `src/storage/oos_file.cpp`
- **diff 규모**: 2 files, +67 / −67 lines
- **Public API 시그니처 변경 없음**: `oos_insert`, `oos_read`, `oos_delete`, `oos_get_length` 유지
- **외부 호출 코드 변경 없음**: `locator_sr.c`, `heap_file.c` 등 수정 불필요
- **Functional 변경 없음**: 순수 rename + `const` 추가 + type alias

---

## Acceptance Criteria

- [x] `OOS_RECDES` alias 를 `oos_file.hpp` 에 정의
- [x] `oos_record_header::total_size` → `total_data_length` 로 변경 + 필드 주석 추가
- [x] `oos_make_oos_recdes` → `oos_prepend_header` 로 rename
- [x] `oos_pop_record_header` → `oos_strip_header` 로 rename
- [x] `oos_prepend_header` / `oos_strip_header` 시그니처에 `OOS_RECDES` 및 `const` 적용
- [x] 내부 임시 변수명을 `oos_recdes` 로 일관되게 통일 (타입도 `OOS_RECDES` 로 선언)
- [x] `total_*_size` 로컬 변수를 `total_*_length` 로 변경
- [x] 모든 OOS unit test (12 개) 통과
- [x] Public API 시그니처 변경 없음

---

## Remarks

- **Base branch**: `cub/feat/oos`
- **Commits**:
  - `06f1826d1` — 1차 rename (`user_` / `page_` prefix 도입)
  - `d55081aac` — 리뷰 피드백 반영 (`OOS_RECDES` alias 로 재조정)
- 관련 선행 이슈:
  - `CBRD-26714-oos-api-readability.md` (1차 리팩토링 기록)
  - `CBRD-26714-oos-recdes-alias-followup.md` (follow-up 기록)
- 순수 리팩토링이며 동작 변경 없음 (rename + alias + `const`).
- 향후 강한 타입 분리가 필요해지면 `OOS_RECDES` 를 wrapper struct 으로 승격 가능.
