# [OOS] PAGE_OOS 타입 switch/case 전수 조사 및 반영

## Description

### 배경
OOS 기능 구현 시 `PAGE_TYPE` enum에 `PAGE_OOS` 를 추가했으나, 코드베이스 전반에 걸친 page type switch/case 문에 `PAGE_OOS` 를 반영하지 않았다. 이로 인해 replication 과정에서 `spage_is_slotted_page_type()` 이 OOS 페이지에 대해 `false` 를 반환하여 assert 실패 및 코어 덤프가 발생했다.

### 목적
`PAGE_OOS` 가 사용되는 모든 page type 분기 로직을 전수 조사하여 누락된 곳에 `PAGE_OOS` case를 추가한다.

---

## Analysis

### 영향을 받는 위치

| 파일 | 함수/위치 | 문제 | 수정 내용 |
|------|-----------|------|-----------|
| `src/storage/slotted_page.c:1150` | `spage_is_slotted_page_type()` | `PAGE_OOS` 누락 → `default` 에서 `false` 반환 → assert 실패 | `case PAGE_OOS:` 추가 (`true` 반환) |
| `src/base/perf_monitor.h:220` | `PERF_PAGE_TYPE` enum | `PERF_PAGE_OOS` 누락 → 값 불일치 (직접 cast 사용) | `PERF_PAGE_OOS` 추가 (`PERF_PAGE_OVERFLOW` 와 `PERF_PAGE_AREA` 사이) |
| `src/base/perf_monitor.c:2098` | `perfmon_stat_page_type_name()` | OOS 페이지 이름 문자열 누락 | `case PERF_PAGE_OOS: return "PAGE_OOS"` 추가 |
| `src/storage/page_buffer.c:16730` | `pgbuf_scan_bcb_table()` 상태 스냅샷 | OOS 페이지 카운팅 누락 | `case PAGE_OOS:` 추가 (data pages 카테고리) |

### 핵심 원인: `PERF_PAGE_TYPE` 값 불일치

`pgbuf_get_page_type_for_stat()` 함수는 `(PERF_PAGE_TYPE) io_pgptr->prv.ptype` 으로 직접 cast를 수행한다. `PAGE_OOS` 가 `PAGE_TYPE` enum에서 8번 값(`PAGE_OVERFLOW` 와 `PAGE_AREA` 사이)으로 추가되었으나, `PERF_PAGE_TYPE` enum에는 `PERF_PAGE_OOS` 가 없어 `PERF_PAGE_AREA` 가 8번을 차지한다. 이로 인해 OVERFLOW 이후 모든 perf page type 값이 1씩 밀리는 문제가 발생한다.

### 조사 후 제외한 항목

- **`PGBUF_IS_ORDERED_PAGETYPE`** (`page_buffer.h:166`): OOS 페이지는 현재 `pgbuf_fix`(일반)만 사용하고 `pgbuf_ordered_fix` 는 사용하지 않음. Ordered fix 지원은 M4 과제로 예정.

---

## Acceptance Criteria

- [x] `spage_is_slotted_page_type()` 에서 `PAGE_OOS` 가 `true` 를 반환
- [x] `PERF_PAGE_TYPE` enum에 `PERF_PAGE_OOS` 추가, `PAGE_TYPE` 과 값 일치
- [x] `perfmon_stat_page_type_name()` 에서 `PERF_PAGE_OOS` → `"PAGE_OOS"` 반환
- [x] `pgbuf_scan_bcb_table()` 에서 OOS 페이지가 data pages로 카운팅
- [x] 빌드 성공

---

## Remarks

- 재현 경로: replication 중 OOS 페이지에 대해 slotted page 연산 수행 시 `spage_is_slotted_page_type()` → `false` → assert 실패 → core dump
- 향후 M4에서 `PGBUF_IS_ORDERED_PAGETYPE` 에 `PAGE_OOS` 추가 필요 (ordered fix deadlock 방지)
