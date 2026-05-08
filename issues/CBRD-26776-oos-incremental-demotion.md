# [OOS] heap recdes가 임계값 아래로 떨어질 때까지 큰 컬럼부터 점진 OOS 전송

## Issue Triage

> **이슈 수행 목적** (필수): heap recdes 가 `DB_PAGESIZE/8` 임계값을 넘었을 때, 512 B 초과 가변 컬럼을 무차별로 모두 OOS 로 보내지 않고, 큰 컬럼부터 한 개씩 보내 record 가 임계값 아래로 떨어지면 즉시 멈추도록 한다. PG TOAST 의 demotion 정책과 동일한 동작이다.
>
> **이슈 수행 이유** (필수): 현재 정책은 record 가 임계값을 단 1 B 만 넘어도 512 B 초과 가변 컬럼을 전부 외부화한다. 그 결과 SELECT/UPDATE 시 불필요하게 OOS 페이지를 읽게 되어 I/O 가 늘고 OOS 파일이 빨리 자란다. heap 에 남겨도 충분한 작은 가변 컬럼까지 함께 외부화되는 비효율을 제거한다.
>
> **이슈 수행 방안**: `heap_attrinfo_determine_disk_layout()` 의 OOS 후보 선정 로직을 size 내림차순 정렬 + 큰 컬럼부터 순차 외부화 + 임계값 도달 시 break 로 교체한다. 다운스트림은 per-column `oos_columns[i]` 플래그만 보므로 변경 불필요.

---

## AI-Generated Context

> 아래 내용은 AI 가 코드/맥락을 분석해 작성한 상세 자료입니다. 빠른 triage 에는 위 **Issue Triage** 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하시면 됩니다.

### Summary

- **문제 / 목적**: record > 2 KB 시 512 B 초과 가변 컬럼 전부 OOS 외부화 정책을, 큰 컬럼부터 점진 외부화로 변경.
- **원인 / 배경**: M1 의 단순 정책. 임계값을 살짝 넘긴 record 가 큰 컬럼 1 개로 fit 가능한 상황에서도 작은 컬럼까지 동시 외부화되어 I/O 가 누적된다.
- **제안 / 변경**: `heap_attrinfo_determine_disk_layout()` 한 함수 패치 (~25 줄). insert 시점 정책만 변경.
- **영향 범위**: INSERT 시점 OOS 후보 선정만. recdes 포맷, MVCC 헤더, OOS 파일 구조, WAL/recovery/replication 모두 변경 없음.

---

## Description

### 배경

OOS 트리거는 두 단계로 평가된다 (`heap_file.c:12186` 부근):

1. **Record 임계값**: `header_size + payload_size + mvcc_extra > DB_PAGESIZE / 8` (16 KB 페이지 기준 2 KB)
2. **컬럼 조건**: 가변 컬럼이고 `column_size > 512 B`

기존 코드는 1 번이 참이면 2 번을 만족하는 컬럼을 모두 일괄 외부화한다:

```cpp
if (header_size + payload_size + mvcc_extra > DB_PAGESIZE / 8)
  {
    for (i = 0; i < attr_info->num_values; i++)
      {
        (*oos_columns)[i] = !is_fixed && column_size[i] > 512;   /* 무차별 */
        if ((*oos_columns)[i])
          {
            payload_size -= column_size[i];
            payload_size += OR_OOS_INLINE_SIZE;
            *has_oos = true;
          }
      }
    ...
  }
```

### 문제

- record 가 2 KB 를 살짝 넘는 경우에도 가장 큰 컬럼 1 개만 빼면 임계값 아래로 떨어지는 상황이 흔하다. 기존 정책은 512 B 초과 컬럼을 전부 외부화하므로 외부화가 불필요한 작은 가변 컬럼까지 OOS 로 함께 빠진다.
- 외부화가 늘어날수록 SELECT 시 `oos_read` I/O 가 증가한다 (CBRD-26516 의 redundant `oos_read` 문제와도 결합).
- UPDATE 시 새 OOS OID 발급 (M1: 항상 새 OID) 비용도 누적된다.
- OOS 파일 자체도 빨리 자라 bestspace/compaction/vacuum 부담이 커진다.

### PG TOAST 와의 비교

PG 는 동일 시나리오를 점진 demotion 으로 처리한다 (`heaptoast.c:177-198`):

```c
while (heap_compute_data_size (...) > maxDataLen)
  {
    biggest_attno = toast_tuple_find_biggest_attribute (&ttc, ...);
    if (biggest_attno < 0) break;
    /* 압축 또는 외부화 */
  }
```

가장 큰 컬럼부터 한 개씩 처리하고 record 가 임계값 아래로 떨어지면 즉시 종료한다. CUBRID OOS 는 M1 시점에 압축이 없으므로 PG 의 외부화 단계만 차용하는 형태로 구현 가능하다. 압축 도입 (CBRD-26536 서베이) 이후에는 본 정책 위에 압축 라운드를 얹는 식으로 자연 확장된다.

---

## Specification Changes

### Trigger Policy

| 항목 | 기존 (M1) | 변경 후 |
|---|---|---|
| 외부화 후보 결정 | 512 B 초과 가변 컬럼 전부 일괄 | 가변 컬럼 size 내림차순 정렬 후, record 가 임계값 이하로 떨어질 때까지 큰 컬럼부터 한 개씩 |
| 외부화 종료 조건 | 모든 후보 처리 후 종료 | record fit 시 break (모두 외부화해도 임계값 못 맞추면 기존과 동일하게 전부 외부화) |
| 시간 복잡도 | O(N) | O(N log N) 정렬. 가변 컬럼 N 은 보통 수십 이내 |

### 외부 인터페이스

- 변경 없음. `oos_columns[i]` per-column 플래그 시그니처 유지.
- recdes 포맷 변경 없음. MVCC 헤더 `OR_MVCC_FLAG_HAS_OOS` 비트 의미 변경 없음.
- WAL 레코드 포맷 변경 없음.

---

## Implementation

### 변경 파일

| 파일 | 변경 내용 |
|---|---|
| `src/storage/heap_file.c` | STL 헤더 (`<algorithm>`, `<utility>`) 추가. `heap_attrinfo_determine_disk_layout()` 의 OOS 후보 선정 로직 교체 |

### 변경 함수

| 함수 | 변경 내용 |
|---|---|
| `heap_attrinfo_determine_disk_layout()` | 가변 컬럼 후보를 `std::vector<std::pair<int, int>>` 에 수집, `std::sort(.., std::greater<>())` 로 size 내림차순 정렬, 임계값 도달 시까지 큰 컬럼부터 외부화 |

### 새 로직 핵심

```cpp
if (header_size + payload_size + mvcc_extra > DB_PAGESIZE / 8)
  {
    std::vector<std::pair<int, int>> oos_candidates;   /* {column_size, attr index} */

    for (i = 0; i < attr_info->num_values; i++)
      {
        if (!attr_info->values[i].last_attrepr->is_fixed && column_size[i] > 512)
          {
            oos_candidates.emplace_back (column_size[i], i);
          }
      }

    std::sort (oos_candidates.begin (), oos_candidates.end (),
               std::greater<std::pair<int, int>> ());

    for (auto & cand : oos_candidates)
      {
        if (header_size + payload_size + mvcc_extra <= DB_PAGESIZE / 8)
          {
            break;   /* record fit; 더 외부화 불필요 */
          }
        (*oos_columns)[cand.second] = true;
        payload_size -= cand.first;
        payload_size += OR_OOS_INLINE_SIZE;
        *has_oos = true;
      }

    header_size = heap_attrinfo_get_record_header_size (attr_info, payload_size,
                                                        is_mvcc_class, offset_size_ptr);
  }
```

### 변경 불필요 부분

- `heap_attrinfo_insert_to_oos()`, `heap_attrinfo_transform_variable_to_disk()` 등 다운스트림은 per-column `oos_columns[i]` 만 본다.
- `heap_record_replace_oos_oids_with_values_if_exists()` 등 read 경로는 VOT `IS_OOS` 비트 기반이라 영향 없음.
- WAL/recovery/replication: heap recdes 와 OOS 파일 모두 포맷이 동일하므로 영향 없음.

### 미세 정확성 고려

- 루프 내부 비교 `header_size + payload_size + mvcc_extra <= DB_PAGESIZE / 8` 는 외부 트리거 시점의 `header_size` (offset_size 재계산 전 값) 를 그대로 쓴다.
- payload 가 줄면 `offset_size` 가 4 -> 2 -> 1 로 줄어 header 가 더 작아질 수 있으나, 항상 `actual_header <= old_header` 이므로 "실제 size 가 임계값 초과인데 break" 하는 경우는 없다 (보수적 over-estimate).
- 후보 전부 외부화해도 임계값을 못 맞추는 경우 (예: 작은 fixed 컬럼이 매우 많거나 가변이 전부 <= 512 B) 는 기존과 동일하게 후보 전부 외부화 후 종료.

---

## Acceptance Criteria

- [ ] record <= 2 KB: OOS 외부화 발생하지 않음 (기존 동작 유지)
- [ ] record > 2 KB, 큰 컬럼 1 개로 fit 가능: 큰 컬럼만 OOS, 나머지는 heap
- [ ] record > 2 KB, 큰 컬럼 1 개로 부족: 큰 컬럼부터 순서대로 추가 외부화
- [ ] record > 2 KB, 모든 후보 외부화해도 부족: 후보 전부 외부화 (기존 동작 유지)
- [ ] 가변 컬럼이 모두 <= 512 B 라서 후보가 0 개인 경우: 외부화 없음 (기존 동작 유지)
- [ ] OOS insert/read/update/delete regression 없음 (`cubrid-isolation-test` OOS suite 통과)
- [ ] CDC/replication regression 없음
- [ ] crash recovery 5 종 시나리오 통과 (committed redo, uncommitted undo, mixed, multi-chunk)

## Definition of Done

- [ ] 위 A/C 충족
- [ ] CircleCI `test_sql`, `test_medium` 그린
- [ ] PR 리뷰 승인
- [ ] OOS 관련 내부 문서 (있는 경우) 업데이트

---

## Remarks

- M2 의 bestspace (CBRD-26658), compaction, vacuum 작업과는 독립.
- M3 의 OOS OID 재사용 (deduplication) 과 결합 시 효과 증폭 (불필요한 외부화 자체가 줄어들면 재사용 로직도 단순해짐).
- 부모 epic: CBRD-26583 (M2).
- 관련: CBRD-26536 (PG TOAST 압축 시점 서베이), CBRD-26516 (redundant `oos_read`).
