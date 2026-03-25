# [OOS] OOS 페이지 compact 분석 — 별도 구현 불필요

## Description

### 배경

OOS 레코드를 페이지에 삽입할 때, 페이지의 `total_free` 는 충분하지만 `cont_free`(연속 여유 공간)가
부족한 경우가 발생할 수 있다. 레코드 삽입/삭제가 반복되면 단편화로 인해 `total_free > cont_free` 가 되며,
새 레코드는 연속 공간이 부족하면 삽입에 실패할 수 있다.

이에 `spage_compact` 와 유사한 `oos_compact` 함수를 별도로 구현하여
OOS 페이지의 단편화를 해소하는 방안을 검토하였다.

### 목적

- OOS 페이지 삽입 시 단편화로 인한 삽입 실패 가능성을 분석한다.
- `oos_compact` 함수의 필요성을 판단한다.

---

## Analysis

### 현재 OOS 삽입 흐름

```
oos_insert() / oos_insert_within_page()                   [oos_file.cpp:263]
  |
  +-- oos_find_best_page(vfid, required_length)            [oos_file.cpp:557]
  |     |
  |     +-- 해당 VFID의 최근 삽입 페이지 조회
  |     +-- spage_get_free_space() -> total_free 반환      [slotted_page.c:891]
  |     +-- total_free >= rec_length + sizeof(SPAGE_SLOT) -> 페이지 재사용
  |     +-- 그 외 -> 새 페이지 할당
  |
  +-- oos_make_oos_recdes(recdes, header, oos_rec)         [oos_file.cpp:122]
  |     +-- OOS_RECORD_HEADER를 레코드 데이터 앞에 추가
  |
  +-- spage_insert(page_ptr, &oos_rec, &slotid)           [oos_file.cpp:298]
        |
        +-- spage_find_empty_slot()                        [slotted_page.c:1396]
              |
              +-- (1) spage_has_enough_total_space() ---- NO -> SP_DOESNT_FIT
              |
              +-- (2) 슬롯 탐색 또는 할당
              |
              +-- (3a) 새 슬롯 경로:
              |     +-- spage_check_space()                [slotted_page.c:1347]
              |           +-- spage_has_enough_total_space()
              |           +-- spage_has_enough_contiguous_space()  <- COMPACT 트리거
              |
              +-- (3b) 재사용 슬롯 경로:
                    +-- spage_has_enough_contiguous_space()        <- COMPACT 트리거
```

### 핵심 함수: `spage_has_enough_contiguous_space`

`slotted_page.c:4679-4685`:

```c
static bool
spage_has_enough_contiguous_space (THREAD_ENTRY * thread_p, PAGE_PTR page_p,
                                   SPAGE_HEADER * page_header_p, int space)
{
  return (space <= page_header_p->cont_free
          || spage_compact (thread_p, page_p) == NO_ERROR);
}
```

**`cont_free < space` 일 때 `spage_compact` 를 자동 호출한다.** compact 성공 후 `cont_free == total_free` 가 되므로,
`total_free >= space` 이면 삽입이 정상 진행된다.

### 분석 결론: `oos_compact` 불필요

새 슬롯 경로와 재사용 슬롯 경로 ** 모두 ** `spage_has_enough_contiguous_space` 를 거치며,
단편화로 인해 삽입이 불가능한 경우 자동으로 `spage_compact` 가 트리거된다.

1. `oos_find_best_page` 가 `total_free >= needed` 인 페이지를 선택 (`spage_get_free_space` 사용)
2. 해당 페이지에 `spage_insert` 호출
3. `cont_free < needed` 이면 `spage_compact` 가 자동 실행
4. compact 후: `cont_free == total_free >= needed`
5. 삽입 성공

**OOS 페이지에서 total space는 충분하지만 단편화로 인해 삽입이 실패하는 코드 경로는 존재하지 않는다.**

### OOS 페이지 설정

| 속성 | 값 | 출처 |
|------|-----|------|
| Anchor type | `ANCHORED` | `oos_vpid_init_new`, 615행 |
| Alignment | `MAX_ALIGNMENT` (8) | `OOS_ALIGNMENT` 상수, 93행 |
| Page type | `PAGE_OOS` | `oos_file_alloc_new`, 533행 |
| Record type | `REC_HOME` | `oos_make_oos_recdes`, 141행 |

OOS 페이지는 **ANCHORED** 슬롯을 사용하므로, 삭제된 슬롯 ID가 보존된다.
새 슬롯과 재사용 슬롯 경로 모두 `spage_has_enough_contiguous_space` 를 호출하여 `spage_compact` 를 트리거한다.

---

## 참고 코드

| 구성 요소 | 파일 | 행 | 용도 |
|-----------|------|-----|------|
| `spage_compact` | `slotted_page.c` | 1174-1283 | 레코드 패킹, 갭 제거, `cont_free = total_free` 설정 |
| `spage_has_enough_contiguous_space` | `slotted_page.c` | 4679-4685 | `cont_free < space` 시 compact 자동 트리거 |
| `spage_check_space` | `slotted_page.c` | 1347-1359 | total -> contiguous 순서로 확인 (새 슬롯 경로) |
| `spage_find_empty_slot` | `slotted_page.c` | 1396-1485 | 핵심 삽입 로직, 새 슬롯/재사용 슬롯 경로 모두 포함 |
| `spage_get_free_space` | `slotted_page.c` | 891-906 | `total_free` 반환 (`oos_find_best_page` 에서 사용) |
| `SPAGE_HEADER` | `slotted_page.h` | 64-84 | `total_free`, `cont_free`, `offset_to_free_area` 포함 헤더 |
| `oos_find_best_page` | `oos_file.cpp` | 557-604 | `total_free` 기반 페이지 선택 |
| `oos_insert_within_page` | `oos_file.cpp` | 263-334 | 298행에서 `spage_insert` 호출 |
| `oos_vpid_init_new` | `oos_file.cpp` | 608-623 | OOS 페이지를 ANCHORED로 초기화 |

---

## Acceptance Criteria

- [x] OOS 삽입 시 `spage_compact` 가 자동 트리거되는 코드 경로를 확인하였다.
- [x] `spage_has_enough_contiguous_space` 내부에서 compact이 수행됨을 검증하였다.
- [x] 별도의 `oos_compact` 구현이 불필요함을 확인하였다.

---

## Remarks

- ** 별도 구현 불필요 **: 기존 `spage_compact` 메커니즘이 OOS 페이지를 포함한 모든 슬롯 페이지에 대해 범용으로 동작한다.
- ** 부수적 발견 **: `oos_find_best_page` 의 공간 확인에서 alignment waste(최대 7바이트)가 미반영되어 있음.
  `spage_find_empty_slot` 은 `DB_WASTED_ALIGN(record_length, alignment)` 만큼 추가 공간을 사용하나,
  `oos_find_best_page` 는 `rec_length + sizeof(SPAGE_SLOT)` 만 확인한다.
  드문 경우지만 페이지 선택 후 `spage_insert` 가 실패할 수 있으며, 이는 compact과는 별개의 경미한 이슈이다.
- ** 권고 **: 본 티켓은 "불필요 / 기존 메커니즘으로 이미 처리됨"으로 종료. alignment waste 이슈는 별도 티켓으로 분리 가능.
