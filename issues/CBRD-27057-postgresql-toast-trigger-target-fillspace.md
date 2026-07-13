# [OOS] [M2] [Correct Error] P사 TOAST 방식으로 OOS trigger/target 과 heap unfill 정책 분리

## Issue Triage

**이슈 수행 목적**: `feat/oos` 의 OOS trigger 와 demotion target 을 P사 기본 TOAST 정책처럼 한 heap page 에
네 record 가 물리적으로 들어가는 최대 aligned 크기로 계산한다. Heap `unfill_factor` 는 page 배치 정책에만
적용한다.

**이슈 수행 이유**:

| 구분 | 내용 |
|------|------|
| **AS-IS (`feat/oos`)** | `heap_attrinfo_determine_disk_layout()` 의 trigger 와 loop stop 이 모두 `DB_PAGESIZE / 4` 를 직접 사용한다. Current layout 에서는 4,086B 이며 slotted-page header, heap chain record/slot, 네 user slot 과 alignment 를 반영하지 않아 target-sized record 네 개가 물리적으로 들어간다는 보장이 없다. |
| **TO-BE** | `heap_nonheader_page_capacity()` 기반 four-record target 4,060B 를 trigger 와 loop stop 에 함께 사용한다. P사의 TOAST threshold/target 과 fillfactor 분리처럼 CUBRID `unfill_factor` 는 target 계산에서 제외한다. |
| **영향** | 4,060B 초과 4,086B 이하 record 가 `feat/oos` 에서는 OOS demotion 없이 inline 으로 남는다. 따라서 “한 page 에 네 record 가 들어가는 target”이라는 설계 의도와 실제 gate 가 다르고, heap page 사용량/fragmentation 과 OOS 선택이 의도한 P사 방식에서 벗어난다. |

**이슈 수행 방안**: `heap_nonheader_page_capacity()` 에서 네 `SPAGE_SLOT_SIZE` 를 뺀 뒤 4로 나누고
`HEAP_MAX_ALIGN` 으로 내림 정렬한 helper 를 추가한다. 이 값을 record gate 와 largest-first loop stop 에 함께
사용한다. `PRM_ID_HF_UNFILL_FACTOR` 와 `heap_hdr->unfill_space` 는 helper 에 넣지 않고 기존 bestspace page
선택에만 유지한다. Test 는 target 수식, 양쪽 boundary, unfill 독립성을 검증하고 실제 page 수를 네 rows/page 로
강제하지 않는다.

---

## AI-Generated Context

> 아래는 AI가 `feat/oos` revision과 P사 source를 비교해 작성한 구현 참고 자료다. AS-IS 기준은 임시 작업 branch가
> 아니라 `feat/oos` (`aa629e6923198f58c68fb9c7d2b86e7adde88c71`)다.

## Description

OOS는 큰 variable value를 별도 OOS file로 옮기고 heap record에는 16B inline stub을 남긴다.
`heap_attrinfo_determine_disk_layout()` 는 record가 target을 넘으면 candidate를 priority/size 순으로 정렬하고,
largest-first로 하나씩 demote하여 같은 target 이하가 되면 멈춘다.

### P사 구현과 CUBRID 대응

P사는 TOAST activation/target과 heap fillfactor를 서로 다른 call path에서 처리한다.

| 축 | P사 구현 | CUBRID 대응 |
|----|----------|-------------|
| trigger | `TOAST_TUPLE_THRESHOLD = MaximumBytesPerTuple(4)`. INSERT/UPDATE 경로에서 tuple이 threshold를 넘거나 external value를 포함하면 toaster를 호출한다. | `heap_attrinfo_determine_disk_layout()` 에서 recdes가 OOS target을 넘으면 demotion을 시작한다. |
| target/stop | 기본 `TOAST_TUPLE_TARGET` 은 threshold와 같다. Toaster는 tuple data가 target 이하가 될 때까지 큰 attribute를 처리한다. | trigger와 largest-first loop stop에 같은 `heap_oos_inline_target_size()` 를 사용한다. |
| four-record 계산 | Page header와 네 `ItemIdData` 를 제외한 공간을 4로 나눈 뒤 alignment를 내림한다. 기본 8KB build에서는 2,040B다. | Non-header heap capacity에서 네 `SPAGE_SLOT_SIZE` 를 제외하고 4로 나눈 뒤 `HEAP_MAX_ALIGN` 으로 내림한다. Current layout에서는 4,060B다. |
| fillspace | `RelationGetBufferForTuple()` 가 fillfactor로 `saveFreeSpace` 를 계산하여 FSM/target page 선택에 사용한다. `MaximumBytesPerTuple(4)` 에는 넣지 않는다. | `heap_stats_find_best_page()` 가 `heap_hdr->unfill_space` 를 page 선택에 사용한다. OOS target helper에는 넣지 않는다. |
| 이번 이슈 범위 밖 | Relation별 `toast_tuple_target`, `STORAGE MAIN` 용 `MaximumBytesPerTuple(1)`, compression/storage strategy가 있다. | Table별 target, MAIN 대응 target, compression 및 기존 `STORAGE PREFER_INLINE` priority 변경은 추가하지 않는다. |

```text
P사 INSERT/UPDATE                         CUBRID INSERT/UPDATE
tuple > MaximumBytesPerTuple(4)?          recdes > heap_oos_inline_target_size()?
  -> toaster 호출                          -> OOS largest-first demotion
  -> tuple <= TOAST target 까지 축소        -> recdes <= same target 까지 축소

RelationGetBufferForTuple(fillfactor)      heap_stats_find_best_page(unfill_space)
  -> 별도 page/FSM 선택                      -> 별도 bestspace page 선택
```

두 구현이 같아야 하는 핵심은 “네 record용 물리 target”과 “실제 page를 얼마나 채울지”를 분리하는 것이다.
P사의 기본 fillfactor는 100이고 CUBRID의 기본 `unfill_factor` 는 0.10이지만, 이번 이슈는 기본값을 같게 만드는
작업이 아니다.

### `feat/oos` AS-IS

`feat/oos` 의 outer gate와 loop stop은 다음과 같다.

```c
if (header_size + payload_size + mvcc_extra > DB_PAGESIZE / 4)
  {
    /* priority + largest-first candidates */
    for (auto& cand : oos_candidates)
      {
        if (header_size + payload_size + mvcc_extra <= DB_PAGESIZE / 4)
          {
            break;
          }
        /* demote cand */
      }
  }
```

Current 16KB I/O page layout은 다음과 같다.

```text
IO_PAGESIZE                                      16,384
DB_PAGESIZE (40B reserved 제외)                  16,344
feat/oos target = DB_PAGESIZE / 4                 4,086

heap_nonheader_page_capacity()                  16,268
four target recdes + slots, aligned
  = 4 * (ALIGN(4,086, 4) + 4)                   16,368
physical capacity                               16,268
```

즉 `feat/oos` target-sized record 네 개는 physical capacity를 100B 초과한다.

### TO-BE target

P사 `MaximumBytesPerTuple(4)` 와 같은 방식으로 heap 고정 overhead와 네 user slot을 먼저 제외한다.

```text
records_per_page = 4
page_capacity = heap_nonheader_page_capacity() = 16,268

target = ALIGN_BELOW(
           (page_capacity - records_per_page * SPAGE_SLOT_SIZE)
             / records_per_page,
           HEAP_MAX_ALIGN)
       = ALIGN_BELOW((16,268 - 16) / 4, 4)
       = ALIGN_BELOW(4,063, 4)
       = 4,060
```

물리 invariant:

```text
4 * (4,060 + 4) = 16,256 <= 16,268
4 * (4,064 + 4) = 16,272 >  16,268
```

4,060B는 current layout에서 네 aligned recdes와 네 slot이 들어가는 최대 target이다. 이는 bestspace가
`unfill_factor` 를 무시하고 실제 모든 page에 네 row를 채운다는 뜻이 아니다.

### 임시 구현에서 피해야 할 방식

임시 작업 branch에서는 physical capacity에서 `DB_PAGESIZE * unfill_factor` 까지 차감하여 기본 target을
3,652B로 계산한 적이 있다. 이 방식은 `feat/oos` 의 AS-IS가 아니며 최종 방안으로 사용하지 않는다.

```text
wrong target = ALIGN_BELOW(
                 (16,268 - int(16,344 * 0.10)) / 4 - 4,
                 4)
             = 3,652
```

P사 fillfactor가 TOAST threshold에 들어가지 않는 것처럼 CUBRID unfill도 OOS target에 들어가면 안 된다.
Unfill은 이미 `heap_stats_find_best_page()` 의 page placement에서 적용된다.

## Expected Result

- Current layout의 OOS trigger와 demotion stop이 모두 4,060B를 사용한다.
- `unfill_factor` 를 바꿔도 같은 schema/value의 OOS layout 선택이 변하지 않는다.
- 4,060B target과 slot 네 개는 physical capacity 안에 들어가며 다음 aligned size는 들어가지 않는다.
- 기존 largest-first, `STORAGE PREFER_INLINE` priority, 16B profitability floor, OOS+bigone rejection은 유지한다.
- Actual heap page count는 acceptance criterion으로 고정하지 않는다.

## Actual Result

`feat/oos` 는 `DB_PAGESIZE / 4` 인 4,086B를 outer trigger와 loop stop에 직접 사용한다. 이 값은 heap page의
고정 overhead와 네 user slot/alignment를 반영하지 않아 P사 방식의 physical four-record target보다 26B 크다.

## Implementation

```c
#define HEAP_OOS_MIN_RECS_PER_PAGE 4

int
heap_oos_inline_target_size (void)
{
  const int page_capacity = heap_nonheader_page_capacity ();
  int target_size;

  target_size = (page_capacity - HEAP_OOS_MIN_RECS_PER_PAGE * SPAGE_SLOT_SIZE)
                / HEAP_OOS_MIN_RECS_PER_PAGE;
  return DB_ALIGN_BELOW (target_size, HEAP_MAX_ALIGN);
}
```

다음 두 위치가 같은 helper 결과를 사용해야 한다.

1. `header_size + payload_size + mvcc_extra > target` record gate
2. candidate loop의 `header_size + payload_size + mvcc_extra <= target` stop condition

다음은 변경하지 않는다.

- `column_size > OR_OOS_INLINE_SIZE` 인 variable value만 candidate로 선택
- `STORAGE PREFER_INLINE` priority 후 largest-first 순서
- candidate가 부족하면 target 초과 non-bigone record 저장 허용
- OOS+bigone `ER_HEAP_OOS_OVERPASS_MAXOBJ_SIZE` rejection
- Heap header의 `unfill_space` 저장 및 bestspace page 선택

## Test

| test | 검증 내용 |
|------|-----------|
| target exact value | Current layout에서 helper가 4,060B인지 확인한다. |
| physical invariant | `4 * (target + slot) <= capacity` 이며 다음 aligned size는 capacity를 넘는지 확인한다. |
| unfill independence | `unfill_factor=0.0` 과 `0.10` 에서 helper 결과가 같은지 확인한다. |
| lower/upper behavior | Old temporary 3,652B gate를 넘지만 4,060B 이하인 record는 inline으로 유지하고, 4,060B를 넘는 record는 OOS를 trigger하는지 확인한다. |
| page-count removal | 실제 네 rows/page assertion을 제거한다. 실제 packing은 unfill과 page placement 정책의 결과다. |
| regression | Logical value round-trip과 기존 OOS unit/SQL suite를 유지한다. |

## Test Build

- AS-IS target revision: `feat/oos` / `aa629e6923198f58c68fb9c7d2b86e7adde88c71`
- P사 comparison revision: `cb937e48f01fa710d084694de8cc556223ba0967`
- Build: CUBRID 11.5 debug GCC, Linux x86_64
- Verification: debug GCC build 성공, configured OOS tests 23/23 통과
- Focused verification: `test_oos_sql_boundary` 11/11 통과
- Static check: `git diff --check` 통과

## References

- CUBRID `src/storage/heap_file.c` -- OOS record gate, candidate loop, target helper
- CUBRID `src/storage/heap_file.c` -- `heap_nonheader_page_capacity()` 및 heap bestspace/unfill 처리
- P사 `src/include/access/heaptoast.h` -- `MaximumBytesPerTuple(4)`, threshold, target
- P사 `src/backend/access/heap/heaptoast.c` -- target 이하까지 처리하는 toaster loop
- P사 `src/backend/access/heap/hio.c` -- fillfactor 기반 page free-space 예약
- JIRA: <http://jira.cubrid.org/browse/CBRD-27057>
- Parent epic: CBRD-26835
