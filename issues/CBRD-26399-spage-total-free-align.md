# [SPAGE] slotted_page total_free / spage_max_record_size 정렬 처리 정합성 수정

> **TL;DR**: `spage_initialize()` 는 `total_free` 를 `DB_ALIGN`(올림)으로 계산하고, `spage_max_record_size()` 는 정렬을 전혀 고려하지 않는다. 두 값 모두 페이지에 실제로 저장 가능한 바이트 수를 **과대 보고** 할 수 있어 호출자가 신뢰할 수 없는 상한을 받게 된다. 보수적으로 `DB_ALIGN_BELOW`(내림)와 정렬 인지(alignment-aware) 계산으로 통일해야 한다.

## Summary

- **문제**: `total_free` 는 올림(`DB_ALIGN`)으로 초기화되고, `spage_max_record_size()` 는 정렬/낭비(waste) 바이트를 무시한다.
- **원인 / 배경**: 페이지에 저장 가능한 "여유 바이트"는 정렬에 의해 항상 **내림** 되어야 한다. 올림은 실제 사용 가능량을 부풀려 보고하는 것과 같다.
- **제안 / 변경**: (1) `spage_initialize()` 내 `total_free` 계산을 `DB_ALIGN_BELOW` 또는 `SPAGE_DB_PAGESIZE - DB_ALIGN(sizeof(SPAGE_HEADER), alignment)` 형태로 교정. (2) `spage_max_record_size()` 도 보수적으로 동작하도록 정렬에 따른 헤더 정렬 패딩과 레코드 waste를 함께 빼주는 형태로 보정.
- **영향 범위**: `src/storage/slotted_page.c`. 모든 슬롯 페이지 사용자(heap, btree, system_catalog, extendible_hash, ehash 등). 사용자 가시 동작은 *최대 레코드 크기 상한* 이 약간 줄어드는 방향이라 호환성 측면에서는 안전한 방향의 수정.

---

## Description

### 배경
슬롯 페이지(`slotted_page.c`)는 페이지 헤더(`SPAGE_HEADER`) 다음 영역을 레코드 저장소로 쓰고, 페이지 끝에서부터 `SPAGE_SLOT` 배열이 자라난다. 페이지 헤더는 다음 세 가지 free 회계 필드를 유지한다.

- `total_free`: 페이지에 남아 있는 총 free 바이트 수
- `cont_free`: 연속된 free 바이트 수 (`<= total_free`)
- `offset_to_free_area`: 다음 레코드를 기록할 위치 (정렬에 맞아야 함)

`SPAGE_VERIFY_HEADER` 는 `total_free >= 0`, `cont_free <= total_free`, 그리고 `offset_to_free_area` 의 포인터 정렬을 단언한다. 그러나 *"`total_free`는 페이지에 실제로 들어갈 수 있는 양보다 크지 않다"* 라는 의미적 상한 invariant는 단언되지 않는다.

### 목적
JIRA 원티켓 description에 명시된 정정 (`AS IS: total_free 가 DB_ALIGN으로 올림된다 / TO BE: DB_ALIGN_BELOW로 align에 맞춰 내려야 한다`)을 코드 베이스 전체에서 일관되게 적용하고, 이와 동일한 클래스의 정렬 미반영 버그인 `spage_max_record_size()` 도 함께 보정하여, slotted page의 free space 회계가 항상 **보수적인 하한** 을 반환하도록 만든다.

---

## Analysis

### 1. `spage_initialize()` 의 `total_free` 올림 문제

```c
/* slotted_page.c:1114 */
page_header_p->total_free = DB_ALIGN (SPAGE_DB_PAGESIZE - sizeof (SPAGE_HEADER), alignment);
/* slotted_page.c:1117 */
page_header_p->offset_to_free_area = DB_ALIGN (sizeof (SPAGE_HEADER), alignment);
```

`DB_ALIGN` 은 *올림* 이다 (`memory_alloc.h`).

- `A = DB_ALIGN(SPAGE_DB_PAGESIZE - sizeof(SPAGE_HEADER), alignment)` -- 올림
- `B = SPAGE_DB_PAGESIZE - DB_ALIGN(sizeof(SPAGE_HEADER), alignment)` -- offset 기준 정확값

`sizeof(SPAGE_HEADER)` 가 `alignment` 의 배수가 아닐 때 `A > B` 가 되어 `total_free` 가 실제 가용 바이트보다 최대 `(alignment - 1)` 만큼 **부풀려진다**.

오늘날의 `SPAGE_HEADER` 레이아웃은 32바이트로 8-byte 자연 정렬되어 있어 현재 컴파일러 환경에서는 우연히 `A == B` 이지만, 헤더 필드가 한 바이트라도 추가/변경되는 순간 즉시 invariant 위반이 발생할 수 있는 잠재 결함이다.

#### 결과 예시 (개념적, 헤더가 align 배수가 아닐 때)
- `PAGE = 16384`, `sizeof(SPAGE_HEADER) = 36`, `alignment = 8`
- `offset_to_free_area = DB_ALIGN(36, 8) = 40`
- `total_free = DB_ALIGN(16384 - 36, 8) = DB_ALIGN(16348, 8) = 16352`
- 실제 가용 = `16384 - 40 = 16344`
- 차이 8 byte 만큼 호출자가 잘못된 상한을 신뢰하게 됨

### 2. `spage_compact()` 의 `total_free` 재계산 형식

```c
/* slotted_page.c:1273 */
page_header_p->total_free = (SPAGE_DB_PAGESIZE - to_offset - (page_header_p->num_slots * sizeof (SPAGE_SLOT)));
```

여기서 `to_offset` 은 마지막 레코드 끝 offset에 `DB_ALIGN` 을 적용한 값이라 자연 정렬되어 있다. 즉 compact 후 `total_free` 는 **정렬된 값** 이다.

반면 `spage_initialize()` 직후 `total_free` 는 위 1번에서 본 대로 **올림된 값** 이다. 따라서 *"빈 페이지 직후의 `total_free`"* 와 *"compact 직후의 빈 페이지 `total_free`"* 가 같은 결과여야 함에도 다르게 계산되어, 두 시점 사이에 회계가 **드리프트** 될 수 있다.

### 3. `spage_max_record_size()` 의 정렬 미반영

```c
/* slotted_page.c:841 */
int
spage_max_record_size (void)
{
  return SPAGE_DB_PAGESIZE - sizeof (SPAGE_HEADER) - sizeof (SPAGE_SLOT);
}
```

#### 문제점
- 페이지의 `alignment`(`CHAR/SHORT/INT/LONG/FLOAT/DOUBLE_ALIGNMENT`)를 인자로 받지 않으며 정렬을 전혀 고려하지 않는다.
- 호출자는 이 값을 *최대 record_length 상한* 으로 사용한다.

  ```c
  /* slotted_page.c:1747 */
  if (record_descriptor_p->length > spage_max_record_size ())
  /* slotted_page.c:2240 */
  if (record_descriptor_length > spage_max_record_size ())
  /* slotted_page.c:3187 */
  if ((record_descriptor_p->length + (int) slot_p->record_length) > spage_max_record_size ())
  ```

- 그러나 실제 페이지 사용 바이트는 `record_length + DB_WASTED_ALIGN(record_length, alignment)` 이다. waste는 최대 `alignment - 1` 바이트.

#### 구체적 시나리오 (PAGE=16384, sizeof(HEADER)=32, sizeof(SLOT)=4, alignment=DOUBLE_ALIGNMENT(8))
- `spage_max_record_size() = 16384 - 32 - 4 = 16348`
- 호출자가 `record_length = 16348` 으로 insert 시도:
  - `waste = DB_WASTED_ALIGN(16348, 8) = 4`
  - `space = 16348 + 4 = 16352`
  - `offset_to_free_area`: `32 -> 32 + 16352 = 16384`
  - 슬롯 위치: `page_p + 16384 - 1 * 4 = page_p + 16380`
  - 즉 슬롯 영역(16380..16383) 이 record 의 waste padding 영역과 겹친다.
  - 불변식 `offset_to_free_area + cont_free + num_slots * sizeof(SPAGE_SLOT) <= SPAGE_DB_PAGESIZE` 가 `16384 + 0 + 4 = 16388 > 16384` 로 위반.
- waste 영역은 일반적으로 read/write 되지 않아 실제 corruption은 *조용히 숨어 있는* 상태이지만, 자산 회계 invariant 자체는 깨져 있다.

#### 정렬 인지 보정 후 안전치
- 보수적 상한: `SPAGE_DB_PAGESIZE - DB_ALIGN(sizeof(SPAGE_HEADER), MAX_ALIGNMENT) - sizeof(SPAGE_SLOT) - (MAX_ALIGNMENT - 1)`
- 또는 alignment를 인자로 받아 정확한 상한을 돌려주는 형태로 시그니처 변경

### 4. 관련 호출자 영향도

| 호출자 | 위치 | 사용 형태 | 영향 |
|--------|------|-----------|------|
| `system_catalog.c:711, 825, 1156` | catalog 슬롯 적재 | `spage_max_space_for_new_record(...) - CATALOG_MAX_SLOT_ID_SIZE` | `total_free` 과대 보고 시 area_size 가 실제 가용량보다 큼 |
| `extendible_hash.c:1900, 3375, 3377, 3553, 3814` | 버킷 페이지 split/merge 결정 | 비교/뺄셈 | over-report 시 split 회피 가능 |
| `slotted_page.c:1747, 2240, 3187` | insert/update 길이 검증 | `> spage_max_record_size()` | 경계값에서 invariant 위반 |
| `slotted_page.c:2319` | `max_record_size = spage_max_record_size ()` | MVCC update 길이 | 동일 |

---

## Implementation

### 변경 1: `spage_initialize()` `total_free` 보정

**Before**

```c
page_header_p->total_free = DB_ALIGN (SPAGE_DB_PAGESIZE - sizeof (SPAGE_HEADER), alignment);
```

**After (방안 A, 가장 안전)**

```c
page_header_p->offset_to_free_area = DB_ALIGN (sizeof (SPAGE_HEADER), alignment);
page_header_p->total_free = SPAGE_DB_PAGESIZE - page_header_p->offset_to_free_area;
/* total_free 는 SPAGE_DB_PAGESIZE 가 alignment 의 배수이고 offset_to_free_area 가
   alignment 정렬되어 있으므로 자동으로 alignment 정렬된다. */
```

**After (방안 B, 최소 변경)**

```c
page_header_p->total_free = DB_ALIGN_BELOW (SPAGE_DB_PAGESIZE - sizeof (SPAGE_HEADER), alignment);
```

방안 A 가 의미적으로 더 명확하고, `spage_compact()` 의 형식과도 자연스럽게 일치한다.

### 변경 2: `spage_compact()` 와의 정합성

`spage_compact()` 결과 (`SPAGE_DB_PAGESIZE - to_offset - num_slots * sizeof(SPAGE_SLOT)`) 와 `spage_initialize()` 결과가 같은 빈 페이지에서 동일하도록 두 식을 통일한다 (방안 A 채택 시 자연스럽게 정합).

### 변경 3: `spage_max_record_size()` 정렬 인지 보정

**Before**

```c
int
spage_max_record_size (void)
{
  return SPAGE_DB_PAGESIZE - sizeof (SPAGE_HEADER) - sizeof (SPAGE_SLOT);
}
```

**After (옵션 1, 시그니처 유지 + 보수적 상한)**

```c
int
spage_max_record_size (void)
{
  /* 정렬 정보 없이 호출되므로 가능한 최대 alignment(MAX_ALIGNMENT)와
     그에 따른 최대 waste(MAX_ALIGNMENT - 1)를 가정하여 보수적 상한을 반환한다. */
  return DB_ALIGN_BELOW (SPAGE_DB_PAGESIZE
                         - DB_ALIGN (sizeof (SPAGE_HEADER), MAX_ALIGNMENT)
                         - sizeof (SPAGE_SLOT),
                         MAX_ALIGNMENT);
}
```

**After (옵션 2, alignment 파라미터 추가)**

```c
int
spage_max_record_size (unsigned short alignment)
{
  return SPAGE_DB_PAGESIZE
         - DB_ALIGN (sizeof (SPAGE_HEADER), alignment)
         - sizeof (SPAGE_SLOT)
         - (alignment - 1);   /* worst-case waste */
}
```

옵션 1이 호출자 변경을 최소화하면서도 *항상* 안전한 상한을 보장한다. 옵션 2는 정확하지만 모든 호출자(슬롯 페이지 자체 4곳 + 외부 0곳) 시그니처를 변경해야 한다.

### 변경 4: assertion 강화

`SPAGE_VERIFY_HEADER` 또는 별도 디버그 체크에 다음 invariant 추가를 권장한다.

```c
assert ((sphdr)->offset_to_free_area + (sphdr)->cont_free
        + (sphdr)->num_slots * sizeof (SPAGE_SLOT) <= SPAGE_DB_PAGESIZE);
assert ((sphdr)->total_free
        == DB_ALIGN_BELOW ((sphdr)->total_free, (sphdr)->alignment));
```

---

## Acceptance Criteria

- [ ] `spage_initialize()` 의 `total_free` 계산이 `DB_ALIGN`(올림) 대신 `DB_ALIGN_BELOW` 또는 offset 기반 식으로 교체된다.
- [ ] `spage_initialize()` 직후의 `total_free` 와 빈 페이지에 대해 `spage_compact()` 가 산출하는 `total_free` 가 동일함을 단위 테스트로 검증한다.
- [ ] `spage_max_record_size()` 가 반환한 값으로 record를 insert 했을 때 `offset_to_free_area + cont_free + num_slots * sizeof(SPAGE_SLOT) <= SPAGE_DB_PAGESIZE` invariant 가 모든 alignment 값에서 깨지지 않음을 단위 테스트로 검증한다.
- [ ] `system_catalog.c`, `extendible_hash.c` 등 외부 호출자에서 회귀가 없음을 SQL/shell 테스트로 확인한다.
- [ ] 기존 `SPAGE_VERIFY_HEADER` 단언이 모든 mutation 경로에서 통과한다 (debug build 회귀 테스트).
- [ ] PR description 에 변경 전/후 `total_free` 의 alignment별 값 표를 첨부한다.

---

## Remarks

- 본 이슈는 JIRA 원본 description ("AS IS: total_free 가 DB_ALIGN으로 올림된다 / TO BE: DB_ALIGN_BELOW로 align에 맞춰 내려야 한다") 을 형식화한 것이며, 사용자가 추가로 지적한 `spage_max_record_size()` 의 정렬 미반영 결함을 같은 클래스의 버그로 묶어 함께 수정 대상에 포함했다.
- 현재 `SPAGE_HEADER` 가 32 byte 로 자연 8-byte 정렬되어 있어 `spage_initialize()` 의 `DB_ALIGN` 사용은 *오늘은 무해* 하지만, 헤더 변경에 대한 회귀 안전성을 위해 즉시 수정하는 편이 안전하다.
- 동일 파일에 대한 별도 정렬/total_free 회계 감사 결과가 `reports/slotted_page_alignment_audit.md` 에 산출 중이며, 추가 발견 사항이 있으면 본 이슈 또는 후속 티켓으로 분리한다.
- 관련 핫 패스: `heap_file.c`, `btree.c`, `system_catalog.c`, `extendible_hash.c`. 변경 후 SQL 회귀 테스트 (CircleCI) 통과를 머지 조건으로 한다.

## 참고 코드

- `src/storage/slotted_page.c:841`  -- `spage_max_record_size()`
- `src/storage/slotted_page.c:977`  -- `spage_max_space_for_new_record()`
- `src/storage/slotted_page.c:1094` -- `spage_initialize()` (`total_free` 초기화 1114)
- `src/storage/slotted_page.c:1273` -- `spage_compact()` 의 `total_free` 재계산
- `src/storage/slotted_page.c:74-78` -- `SPAGE_VERIFY_HEADER` 단언
- `src/storage/slotted_page.c:353-355` -- 페이지 무결성 디펜시브 체크
- `src/storage/slotted_page.h:64-93` -- `SPAGE_HEADER`, `SPAGE_SLOT` 레이아웃
- `src/base/memory_alloc.h:91-98` -- `DB_ALIGN`, `DB_ALIGN_BELOW`, `DB_WASTED_ALIGN` 정의
