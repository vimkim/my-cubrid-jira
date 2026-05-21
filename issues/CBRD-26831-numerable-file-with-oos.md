# [CBRD-26831] [OOS] [M2] [Survey] Numerable file type with OOS — bestspace tradeoff analysis

## TL;DR

- `FILE_OOS` 는 `oos_create_file` 에서 `file_create(..., is_numerable=true, ...)` 로 생성되어 `FILE_FLAG_NUMERABLE` 비트를 가지며 user page table 을 유지한다 (`src/storage/oos_file.cpp:924-925`).
- bestspace sync 경로 `oos_stats_sync_bestspace` 는 user page 인덱스 `i = 1..max_iterations` 에 대해 `file_numerable_find_nth` 를 반복 호출해 nth user page 의 VPID 를 얻는다 (`src/storage/oos_file.cpp:692`). `max_iterations` 는 `clamp (10, total_pages * 0.2, 100)` 로 정해지므로 작은 파일에도 최소 10, 큰 파일에서도 최대 100 의 floor/ceiling 이 있다 (`src/storage/oos_file.cpp:659-666`).
- 장점은 첫 페이지를 sticky 로 잠그면서도 모든 user page 를 ordinal index 로 순차 스캔할 수 있다는 것, sync 가 partial/full sector bitmap 을 직접 풀지 않고 user page table 을 그대로 훑을 수 있다는 것이다.
- 단점은 (i) 모든 OOS 페이지 할당이 user page table append + WAL 을 강제하고 (`file_numerable_add_page` 정의 `src/storage/file_manager.c:7956`, WAL 호출 `:8100`), (ii) `n_page_mark_delete > 0` 일 때 `file_numerable_find_nth` 가 helper `file_extdata_find_nth_vpid_and_skip_marked` 의 entry-by-entry decrement 루프로 떨어져 한 호출의 worst case 가 user page table 길이 `n` 에 선형이며 sync 전체로는 worst case 비용이 `max_iterations · n` 에 비례하는 것 (`src/storage/file_manager.c:8175-8200`, `:8304-8316`; `scan_all=true` 인 경우 `max_iterations = total_pages` 가 되어 `n²` 비례), (iii) heap_file 의 bestspace 모델은 heap chain 의 `next_vpid` 를 따라가는 enumeration 을 쓰는 반면 OOS 는 user page table 이라는 별도 자료구조 + mark-delete 의 비용을 진다는 것이다.
- 즉 현재 구현은 numerable 사용으로 sync 코드의 단순함을 얻었지만, 페이지 deallocation 과 mark-delete 가 본격화되면 cost/correctness 양면에서 재검토가 필요하다.

## Background

OOS (Out-of-row Overflow Storage) 는 큰 컬럼 값을 별도 파일에 chunk 단위로 저장하고 heap record 에는 OOS OID(16B) 만 남기는 저장 구조다. OOS 페이로드는 한 페이지에 들어가는 single-chunk 와, 여러 chunk 를 next_chunk_oid 로 연결한 multi-chunk 두 형태가 있다 (`src/storage/oos_file.cpp:1071`, `src/storage/oos_file.cpp:1109`). insert 가 빈 페이지를 매번 새로 할당하면 페이지 사용률이 폭락하므로, 같은 VFID 안에서 "충분한 free space 가 있는 페이지" 를 빠르게 찾는 **bestspace** 메커니즘이 필요하다.

OOS 의 bestspace 는 의도적으로 `heap_file.c` 의 기존 모델을 차용했다. heap 측은 `HEAP_HDR_STATS::estimates` 에 `best[HEAP_NUM_BEST_SPACESTATS]` 배열과 글로벌 `heap_Bestspace` 해시(VPID -> entry, HFID -> entry)를 두고, `heap_stats_find_page_in_bestspace` (정의 `src/storage/heap_file.c:3292`, forward decl `:630`) 가 (A) 해시 (B) heap 헤더의 best[] (C) `heap_stats_sync_bestspace` (정의 `src/storage/heap_file.c:3748`, forward decl `:636`) 의 3-tier 탐색으로 page 를 찾는다. OOS bestspace 는 이 패턴을 거의 일대일로 복제해서 `OOS_HDR_STATS::estimates.best[OOS_NUM_BEST_SPACESTATS]` + 글로벌 `oos_Bestspace` (`src/storage/oos_file.cpp:114`) 형태로 구현했다. 본 문서가 다루는 핵심 차이는 **bestspace 자료구조가 아니라**, OOS 파일이 `FILE_HEAP` 이 아니라 `FILE_OOS` 이고 `is_numerable=true` 로 생성된다는 점, 그리고 enumeration 메커니즘이 다르다는 점이다.

heap 측 대조군 한 줄 요약: `file_create_heap()` 는 `is_numerable` 인자를 받지 않고 내부적으로 `file_create_with_npages` 를 호출하여 user page table 없이 partial+full sector bitmap 만 유지한다 (`src/storage/file_manager.c:3132-3146`).

## Numerable file type mechanism

### What it is

`file_create()` 의 6번째 매개변수 `is_numerable` 이 true 면 파일 헤더의 `file_flags` 에 `FILE_FLAG_NUMERABLE` 비트(0x1) 가 설정된다 (`src/storage/file_manager.c:3333` 함수 정의 — 매개변수 시그니처, `:3527-3529` — 비트 세팅). numerable 파일은 일반 permanent file 의 기능에 더해 **user page allocation order 를 명시적으로 기록** 하고, 그 ordinal index 로 nth user page 의 VPID 를 조회할 수 있는 기능을 제공한다.

매크로 `FILE_TYPE_CAN_BE_NUMERABLE` 은 numerable 사용처를 열거한다 — `FILE_EXTENDIBLE_HASH`, `FILE_EXTENDIBLE_HASH_DIRECTORY`, `FILE_TEMP` 세 타입만 포함하며 `FILE_OOS` 는 들어 있지 않다 (`src/storage/file_manager.c:186-188`). 한편 `oos_create_file` 은 매크로를 우회하여 `file_create` 의 `is_numerable=true` 를 직접 넘긴다 (`src/storage/oos_file.cpp:924-925`). 즉 매크로 정의와 실제 numerable 사용처 사이에 불일치가 존재한다. (왜 매크로를 수정하지 않았는지는 develop 기준 정의가 그대로 유지되어 있다는 사실만 관찰될 뿐, 변경 의도는 코드만으로는 결정할 수 없다.)

### Differences from a regular permanent file

(1) **파일 헤더 페이지 레이아웃 분할이 달라진다.** non-numerable permanent file 은 헤더 페이지 안을 partial table : full table = 1:1 로 나눠 쓴다 (`src/storage/file_manager.c:3628-3644`). numerable permanent file 은 헤더 공간을 partial : full : user_page_table = 1/32 : 1/32 : 나머지 비율로 쪼개서, 헤더 페이지의 대부분을 user page table 에 할당한다 (`src/storage/file_manager.c:3588-3613`). (정확한 비율: `(DB_PAGESIZE - FILE_HEADER_ALIGNED_SIZE)` 에서 partial 과 full 이 각 1/32 씩, user page table 이 나머지 ≈ 30/32 를 사용.)

(2) **`file_alloc` 마다 user page table 에 page VPID 가 append 된다.** 이는 `file_numerable_add_page()` 가 수행한다 (`src/storage/file_manager.c:7956`). user page table 도 `FILE_EXTENSIBLE_DATA` 기반이므로 한 페이지가 다 차면 새 ftab 페이지를 더 할당해서 링크드 리스트로 잇는다 (`src/storage/file_manager.c:8008`, `:8053`). permanent numerable 파일의 경우 이 append 자체와 ftab 페이지 확장이 모두 WAL 로깅된다. WAL 호출은 함수 본체 안의 `file_log_extdata_add` (`src/storage/file_manager.c:8100`) 와 `RVFL_FHEAD_SET_LAST_USER_PAGE_FTAB` 로그 (`:8066`) 두 군데에서 일어난다.

(3) **deallocation 이 두 단계로 분리된다.** non-numerable file 의 dealloc 은 partial/full bitmap 비트를 클리어하는 단계로 끝난다. numerable file 은 동일한 비트 클리어 외에 user page table 의 해당 VPID 슬롯에 mark-deleted 플래그를 세팅해야 한다. mark-delete 플래그와 set/clear 매크로 정의는 `src/storage/file_manager.c:425-428` (`FILE_USER_PAGE_MARK_DELETE_FLAG = 0x80000000`, `FILE_USER_PAGE_MARK_DELETED(vpid)`). 실제 mutation 과 로깅이 일어나는 지점은 `file_dealloc` 안에서 numerable 분기로 들어와 `FILE_USER_PAGE_MARK_DELETED (vpid_found)` 를 호출하고 그 직후 `log_append_undoredo_data (..., RVFL_USER_PAGE_MARK_DELETE, &addr, LOG_DATA_SIZE, 0, log_data, NULL)` 가 수행되는 `src/storage/file_manager.c:6269` 와 `:6282` 다. 이때 redo length 는 0, redo data 는 NULL 이므로 실제로 emit 되는 것은 undo-only physical log 이며 — redo payload 는 별도로 emit 되지 않는다 — 정확히는 `RVFL_USER_PAGE_MARK_DELETE` 라는 rcvindex 를 가진 undoredo 레코드이되 redo 데이터가 비어 있는 형태다. 이 logical mutation 은 `file_rv_user_page_unmark_delete_logical` 로 undo 된다 (`src/storage/file_manager.c:8428`).

(4) **이름 그대로 "numerable"** — `file_numerable_find_nth` 가 가능하다는 것이 핵심이다 (`src/storage/file_manager.c:8214`).

### Key APIs

| API | 위치 | 역할 |
|---|---|---|
| `file_create(..., is_numerable=true, ...)` | `src/storage/file_manager.c:3333` (함수 시그니처); `is_numerable` 의미는 `:3527-3529` 에서 `FILE_FLAG_NUMERABLE` 비트 세팅 | numerable flag 와 user page table 을 초기화하며 파일 생성 |
| `file_create_temp_numerable` | `src/storage/file_manager.c:3238` | temporary numerable 파일 (extendible hash, sort 등) |
| `file_numerable_find_nth` | `src/storage/file_manager.c:8214` | nth user page 의 VPID 반환 (mark-deleted 스킵 + `auto_alloc` 옵션) |
| `file_numerable_truncate` | `src/storage/file_manager.c:8598` | nth 이후 페이지를 모두 dealloc — 내부적으로 `file_numerable_find_nth` 와 `file_dealloc` 을 페이지 수만큼 반복 |
| `file_numerable_add_page` (static) | `src/storage/file_manager.c:7956` | `file_alloc` 내부에서 호출되어 user page table 끝에 append |

`file_numerable_find_nth` 의 두 가지 동작 모드 (`src/storage/file_manager.c:8252`, `:8304`):
- `n_page_mark_delete == 0` 인 일반 경로: `file_extdata_find_nth_vpid` 로 extensible data component 단위로 점프해 들어가 O(component 수) 에 도달 가능.
- `n_page_mark_delete > 0` 인 경로: `file_extdata_find_nth_vpid_and_skip_marked` (`src/storage/file_manager.c:8175-8200`) 로 entry-by-entry 순회를 한다. 이 helper 는 mark-deleted 슬롯은 그냥 skip 하고, mark-deleted 가 아닌 슬롯을 만날 때마다 `find_nth_context->nth` 를 1씩 감소시키며 `nth == 0` 인 순간에 stop 한다. 즉 단일 호출의 비용은 worst case 가 `nth + (앞쪽에 있는 mark-deleted 수)` 만큼의 entry traversal 이며, mark-delete 분포에 따라 user page table 전체 길이 `n` 만큼 걷는 경우가 발생할 수 있다 (한 호출의 안전한 worst-case 상한은 O(n)).

또한 `vpid_find_nth_last` + `first_index_find_nth_last` 라는 단방향 캐시가 헤더에 있다 (`src/storage/file_manager.c:140-157`). 다만 이 캐시는 `FILE_CACHE_LAST_FIND_NTH` 매크로의 게이트를 통과해야만 활성화된다. 게이트 조건은 `FILE_IS_NUMERABLE (fh) && FILE_IS_TEMPORARY (fh) && (fh)->type == FILE_TEMP && thread_p->m_px_orig_thread_entry == NULL /* not parallel thread */` 의 4가지 조건의 AND 다 (`src/storage/file_manager.c:181-183`). **OOS 는 permanent 파일이므로 이 캐시가 작동하지 않는다** — sync 가 OOS 파일을 nth 로 훑을 때마다 매번 page table 의 처음부터 새로 인덱싱한다.

### On-disk / metadata cost

- 파일 헤더의 user page table 영역: `DB_PAGESIZE - offset_ftab` 바이트로, 여기서 `offset_ftab` 은 헤더 + partial(1/32) + full(1/32) 의 합 (`src/storage/file_manager.c:3611`). default 16KB 페이지 기준으로는 약 15KB 가량이 user page table 에 할당된다.
- 한 엔트리는 `sizeof(VPID) = 8B` 이므로 헤더 단일 페이지에 `15KB / 8B ≈ 1920` 개의 user page 가 인덱싱 가능 (정확한 수치는 `file_extdata_init` 의 align/header 처리로 1920 보다 약간 작다, `src/storage/file_manager.c:3613`, `:1497`).
- 헤더 페이지의 user page table 영역이 가득 차면 ftab 페이지를 추가로 잡아 링크드 리스트로 잇는다. 이는 user page 가 아니라 file table page 로 카운트된다 (`fhead->n_page_ftab` 증가, `src/storage/file_manager.c:7984-7991`).
- 정량적으로: header 의 user page table 용량을 초과한 뒤로는, 신규 ftab 페이지 1개당 `DB_PAGESIZE / sizeof(VPID)` 슬롯에서 `FILE_EXTENSIBLE_DATA` 헤더가 차지하는 영역만큼을 뺀 수의 user page 를 추가로 인덱싱할 수 있다 (default 16KB 페이지 기준 약 2000 개 안팎; 정확한 값은 `file_extdata_init` 의 align/header 처리로 약간 작다, `src/storage/file_manager.c:1497`). 즉 헤더 capacity 를 넘긴 뒤에는 **추가 user page 약 2000 개당 ftab 페이지 1개** 가 더 소모된다.

### Guarantees and recovery

`file_alloc` 호출 순서대로 user page table 에 VPID 가 append 된다는 점이 nth 의 의미를 정의한다 (`src/storage/file_manager.c:7971-7973`). dealloc 은 슬롯을 mark-delete 만 하고 물리적으로 즉시 제거하지 않으므로, mid-chain 페이지가 dealloc 되어도 다른 페이지의 ordinal index 가 즉시 shift 되지는 않는다 — find_nth 가 skip_marked 로 처리한다.

recovery 측면에서 numerable 만의 비용은 두 종류다:
- `RVFL_USER_PAGE_MARK_DELETE` / `..._COMPENSATE` (undo-only physical log; logical undo handler, `src/storage/file_manager.c:8396-8559`).
- `RVFL_FHEAD_SET_LAST_USER_PAGE_FTAB` 와 `file_log_extdata_add` 등 user page table 자체의 redo 로그 (`src/storage/file_manager.c:8038`, `:8066`, `:8100`).

이는 모두 permanent numerable 파일에서만 발생하며 temporary numerable 파일에서는 단순 dirty 표시로 끝난다 (`src/storage/file_manager.c:8090`, `:8103`).

본 문서에서 OOS 단위의 recovery semantics(예: chunk WAL ordering, vacuum 과의 상호작용) 는 다루지 않는다 — out of scope.

## OOS bestspace use case

### What OOS needs from "best space"

`oos_find_best_page` 는 다음 4-step 으로 후보 페이지를 결정한다 (`src/storage/oos_file.cpp:1459-1619`):
1. sticky first page (헤더 페이지) 를 잡고, 헤더의 `OOS_HDR_STATS::estimates.best[10]` 와 글로벌 hash `oos_Bestspace` 를 함께 본다.
2. `oos_stats_find_page_in_bestspace` 가 (Phase A) global hash → (Phase B) header best[] → (Phase C) 후보 페이지 conditional latch + 실제 free space 검증 순으로 시도한다 (`src/storage/oos_file.cpp:478-601`). 이 경로에는 동적 cache 무효화가 들어 있다: Phase A 에서 hash entry 의 freespace 가 요청 needed_space 보다 작으면 그 자리에서 entry 를 `mht_rem2` 로 제거하고 (`src/storage/oos_file.cpp:514-517`), Phase C 에서 conditional latch 후 실제 free space 가 요청보다 작아도 동일하게 hash 에서 제거한다 (`:591-594`). 즉 bestspace cache 는 단순 "lookup miss" 가 아니라 "lookup-and-evict" 의미를 가진다.
3. 모두 실패하고 ratio (`num_other_high_best / num_pages`) 가 `OOS_BESTSPACE_SYNC_THRESHOLD = 0.1f` 이상이면 헤더 latch 를 푼 뒤 sync 스캔을 한다 (`src/storage/oos_file.cpp:1519-1538`).
4. 그래도 못 찾으면 `oos_file_alloc_new` 로 신규 페이지 할당 (`src/storage/oos_file.cpp:1608`).

여기서 numerable file 메커니즘이 직접 등장하는 지점은 **(3) sync 스캔** 이다. `oos_stats_sync_bestspace` 가 `file_get_num_user_pages` 로 총 user page 개수를 얻은 뒤, `start_idx = 1` (header page 인 0번 skip) 부터 시작해 `file_numerable_find_nth(thread_p, vfid, i, false, NULL, NULL, &scan_vpid)` 를 호출하며 ordinal index 로 페이지를 순회한다 (`src/storage/oos_file.cpp:647`, `:692`).

또한 `oos_create_file` 자체가 `file_create(..., is_temp=false, is_numerable=true, ...)` 로 호출되어 OOS 파일을 numerable permanent 파일로 만들고, `file_alloc_sticky_first_page` 로 첫 페이지(header 슬롯이 들어가는 페이지) 를 sticky 로 잠근다 (`src/storage/oos_file.cpp:924-925`, `:941`). 이 sticky 페이지가 numerable 의 0번 인덱스가 되며, sync 가 명시적으로 `start_idx = 1` 로 skip 한다 (`src/storage/oos_file.cpp:643`).

### How "numerable" maps to OOS requirements

OOS workload 는 다음 3가지 특성을 갖는다:
- (a) MVCC-aware: 각 chunk 는 `OR_MVCC_FLAG_HAS_OOS` 등 MVCC 플래그와 함께 살아 있으며 UPDATE 가 새 chunk 를 만들고 이전 chunk 는 vacuum 까지 남는다.
- (b) recovery-sensitive: chunk 자체가 chunk-당 WAL record (`RVOOS_INSERT`/`RVOOS_DELETE`) 로 로깅된다 (`src/storage/oos_file.cpp:1658`, `:1677`).
- (c) chunk 크기는 페이지 크기에 의해 상한이 정해진다 — `oos_get_max_chunk_size_within_page()` 는 `DB_ALIGN_BELOW (spage_max_record_size (), OOS_ALIGNMENT) - sizeof (OOS_RECORD_HEADER)` 를 반환하므로, single chunk 의 payload 상한은 페이지 내 최대 record 크기에서 alignment slack 과 OOS record header 만큼 작다 (`src/storage/oos_file.cpp:1805-1811`; insert 분기 `:1071`, multi-chunk path `:1118`, 그리고 단일 chunk 경로 assert `:1213`).

보다 자세한 배경은 `CBRD-26357-oos-epic.md` 참조.

numerable 의 nth 인덱싱은 OOS 가 sync 시 **모든 user page 를 deterministic 한 순서로 한 번씩** 훑을 수 있게 해준다. 같은 일을 non-numerable 파일에서 하려면 두 가지 옵션이 있다: (i) heap 처럼 페이지마다 chain 의 `next_vpid` 를 임베드해 follow-the-chain 방식으로 enumeration 하거나 (heap 측 `heap_stats_sync_bestspace` 의 `while (!VPID_ISNULL (&next_vpid) || can_cycle == true)` 루프, `src/storage/heap_file.c:3864`), (ii) `file_get_all_data_sectors` + `file_partsect_pageid_to_offset` 로 partial+full sector bitmap 을 풀어 페이지 enumeration 을 직접 구현 (`src/storage/file_manager.h:294` 의 extern 선언, 호출 예는 `src/storage/external_sort.c:5283`). `file_numerable_find_nth` 는 이 enumeration 을 user page table 위에 이미 캡슐화하고 있다.

## Pros

1. **Sync 구현이 단순하다.** `oos_stats_sync_bestspace` 는 `for (int i = start_idx; i < total_pages && iterations < max_iterations; i++)` + `file_numerable_find_nth(..., i, false, ...)` 의 한 줄로 user page enumeration 을 끝낸다 (`src/storage/oos_file.cpp:689-692`). non-numerable 라면 heap-style chain 임베드 또는 `file_get_all_data_sectors` 기반 bitmap walk 를 OOS 측에서 직접 구현해야 했을 것이다 — `heap_file.c` 의 `heap_stats_sync_bestspace` 가 `next_vpid` 루프로 비슷한 일을 N 줄 분량으로 풀어내고 있는 것과 비교했을 때 정성적으로 더 짧다 (실측 비교는 없으며, 본 prosa 의 "1 line vs N lines" 는 코드 형태에 대한 추정).

2. **Header page 가 자연스럽게 0번 인덱스가 된다.** `file_alloc_sticky_first_page` 가 호출된 첫 페이지는 user page table 의 0번 슬롯이 되고, sync 는 `start_idx = 1` 로 안전하게 skip 할 수 있다 (`src/storage/oos_file.cpp:643`, `:699`). 또한 hash 와 best[] 모두에서 header page 가 후보로 잡히지 않도록 `file_get_sticky_first_page` 로 가져온 `hdr_vpid` 와 직접 비교해 거르는 추가 방어선이 있다 (`src/storage/oos_file.cpp:470`, `:500-507`).

3. **부분 스캔이 명확히 정의된다.** sync 는 `clamp (10, total_pages * 0.2, 100)` 만큼만 nth 인덱스를 진행하고 `oos_hdr->estimates.full_search_vpid` 에 resume point 를 저장한다 (`src/storage/oos_file.cpp:659-667`, `:753`). nth 인덱싱이 없다면 "어디까지 봤는지" 를 VPID 로 저장하고 다음 라운드에 어디서 재개할지 다시 찾아야 한다 — 현재 `full_search_vpid` 자체도 정확히 그 점에 대한 TODO 가 코드 안에 명시되어 있다 (`src/storage/oos_file.cpp:671-675`: `/* TODO: ideally find the index of full_search_vpid; for now start from 1 */`).

## Potential future benefits (not yet realized in OOS)

- **`file_numerable_truncate` 가 동일 패밀리 API 로 존재한다.** `file_numerable_truncate` 는 정확히 nth 이후를 dealloc 하는 API 다 (`src/storage/file_manager.c:8598-8656`). OOS 파일 drop / shrink 시나리오에서 별도 helper 없이 활용 가능하다. 다만 현재 `oos_remove_file` 은 `file_postpone_destroy` 만 호출하며 `file_numerable_truncate` 는 호출하지 않는다 (`src/storage/oos_file.cpp:1001`). 따라서 현 시점에서는 Pro 가 아니라 **잠재적 미래 이득** 으로만 분류한다.

## Cons

본 절의 모든 항목은 코드 구조와 알고리즘적 비용을 분석한 것이며, 실측 (microbench, profile, regression) 은 아직 수집된 바 없다. 정량적 비교가 필요한 결정은 별도 측정으로 보강해야 한다.

1. **모든 OOS 페이지 할당이 user page table append + WAL 을 추가로 지불한다.** `oos_file_alloc_new` 는 `file_alloc` 을 부르고, `file_alloc` 은 numerable 파일이면 `file_numerable_add_page` 를 거쳐 user page table 에 VPID 를 append 하고 `file_log_extdata_add` 로 logging 한다 (`src/storage/file_manager.c:5498`, `:8100`). 추가로 user page table 의 ftab page 가 full 이 되어 새 ftab page 를 더 잡을 때마다 `RVFL_FHEAD_SET_LAST_USER_PAGE_FTAB` 가 별도 redo 로그로 기록된다 (`src/storage/file_manager.c:8066`). 이 비용은 OOS 페이로드 자체의 `RVOOS_INSERT` 와 별개이며 — 정량적 byte 크기는 본 문서에서 측정하지 않았다 (qualitative; not measured).

2. **`n_page_mark_delete > 0` 일 때 sync 의 worst-case 비용이 user page table 길이에 비례한다.** mark-delete 가 존재할 때 `file_numerable_find_nth` 는 `file_extdata_find_nth_vpid_and_skip_marked` 분기로 들어가 entry-by-entry 순회를 한다 (`src/storage/file_manager.c:8175-8200`, `:8304-8316`). helper 는 mark-deleted slot 은 skip 하고, mark-deleted 가 아닌 slot 을 만날 때마다 `find_nth_context->nth` 를 감소시키며 `nth==0` 에서 short-circuit 한다. 따라서 단일 `file_numerable_find_nth (..., i, ...)` 호출의 비용은 `i + (앞쪽에 있는 mark-deleted 수)` 만큼의 entry traversal 이며 user page table 길이 `n` 에 대해 worst case O(n) 이다. OOS sync 가 `i = 1, 2, ..., max_iterations` 로 호출되므로 sync 전체의 worst-case 비용은 `max_iterations · n` 에 비례한다. `max_iterations` 는 `clamp (10, total_pages * 0.2, 100)` 로 정해지므로 (`src/storage/oos_file.cpp:659-666`) 일반 경로에서는 최소 10, 최대 100 의 호출이 발생하고, `scan_all=true` 인 호출 경로(`src/storage/oos_file.cpp:655`) 는 `max_iterations = total_pages` 가 되어 worst-case 비용이 `n²` 에 비례한다. 페이지 dealloc 은 `file_dealloc` 의 numerable 분기에서 `FILE_USER_PAGE_MARK_DELETED (vpid_found)` 호출 후 `RVFL_USER_PAGE_MARK_DELETE` 가 로깅되는 시점에 mark-delete 가 누적된다 (`src/storage/file_manager.c:6269`, `:6282`). 현재 `oos_remove_page` 는 TODO 상태로 vacuum 미연동이지만 (`src/storage/oos_file.cpp:1007`), 호출 시 위 경로를 통해 mark-delete 를 누적시키게 된다.

3. **find_nth_last 캐시 path 가 OOS 에서는 비활성이다.** `FILE_CACHE_LAST_FIND_NTH` 의 게이트는 `FILE_IS_NUMERABLE (fh) && FILE_IS_TEMPORARY (fh) && (fh)->type == FILE_TEMP && thread_p->m_px_orig_thread_entry == NULL` 의 AND 다 (`src/storage/file_manager.c:181-183`). OOS 는 permanent 파일이고 `FILE_OOS` 타입이므로 `FILE_IS_TEMPORARY (fh)` 와 `type == FILE_TEMP` 의 이중 게이트에서 막힌다. 결과적으로 sync 가 매번 `nth = 1, 2, ...` 로 호출되면서 user page table 의 첫 ftab component 부터 다시 인덱싱한다. (heap 의 sync 경로는 이와 별도로 chain 의 `next_vpid` follow 를 쓰므로 동등한 비교는 아니지만, OOS 가 numerable 이점을 부분적으로만 누리고 있다는 의미이기는 하다.)

4. **OOS 와 heap_file 의 bestspace enumeration 메커니즘이 구조적으로 다르다.** heap 측 `heap_stats_sync_bestspace` 는 heap chain 의 `next_vpid` 를 따라가는 walk 로 페이지를 enumeration 한다 (`src/storage/heap_file.c:3864`). 즉 heap 은 페이지마다 자기 chain link 를 갖고 있고, OOS 는 별도의 file-level user page table 을 갖고 있다. 동일한 enumeration 효과를 얻기 위해 두 모듈이 서로 다른 mechanism 을 쓰고 있는 셈이며, 그 결과 OOS 는 numerable 의 cost(헤더 페이지 분할 변화, 매 alloc 마다의 append + WAL, mark-delete logical undo) 를 sync enumeration 의 단순함과 맞바꾼 셈이다. (`file_get_all_data_sectors` 는 file_manager 단의 sector enumeration helper 로 `src/storage/external_sort.c:5283` 에서 호출될 뿐, `heap_stats_sync_bestspace` 는 이를 사용하지 않는다 — grep 결과로 확인 가능.)

5. **헤더 페이지 레이아웃이 OOS 의 `OOS_HDR_STATS` 와 경쟁한다.** numerable 파일의 헤더는 user page table 에 약 15/16 ((`DB_PAGESIZE - offset_ftab`) 의 잔여, `src/storage/file_manager.c:3611`) 를 할당한다. 한편 OOS 는 헤더 페이지 슬롯 0 에 별도 record 로 `OOS_HDR_STATS`(약 200B) 를 끼워 넣는다 (`src/storage/oos_file.cpp:951-983`, `OOS_HDR_STATS` 정의는 `src/storage/oos_file.hpp:59`). 두 자료구조는 같은 페이지의 다른 영역에 공존하지만 — `FILE_HEADER` 는 `FILE_HEADER_ALIGNED_SIZE` 이내, `OOS_HDR_STATS` 는 slotted page 슬롯 — 헤더 페이지가 single-point-of-fix 가 된다. `oos_find_best_page` 가 헤더를 write latch 로 잡고 sync 동안 잠시 푸는 별도 처리를 둔 이유가 여기에 있다 (`src/storage/oos_file.cpp:1520-1530`). 더해서 `oos_stats_find_page_in_bestspace` 의 hash invalidation 경로 (`src/storage/oos_file.cpp:514-517`, `:591-594`) 가 sync 와 cache 동기화에 관여하므로, 헤더 자체와 글로벌 hash 가 동시에 single-point-of-fix 역할을 한다.

6. **`FILE_TYPE_CAN_BE_NUMERABLE` 매크로의 열거 invariant 가 깨져 있다.** `src/storage/file_manager.c:186-188` 의 매크로는 develop 의 정의(extendible hash 2종 + FILE_TEMP)를 그대로 유지하고 있고, OOS 가 이를 우회하여 `is_numerable=true` 로 `file_create` 를 부른다 (`src/storage/oos_file.cpp:924-925`). 매크로의 callsite 는 `grep -rn FILE_TYPE_CAN_BE_NUMERABLE /home/vimkim/gh/cb/oos-storage/src/` 기준 비-backup 트리에서 정의 자리(`src/storage/file_manager.c:186`)와 단 한 곳의 사용 자리 — `file_dealloc` 의 early-exit 가드 `if (!FILE_TYPE_CAN_BE_NUMERABLE (file_type_hint))` (`src/storage/file_manager.c:6211`) — 만 잡힌다 (나머지는 `.conform.*.c~` / `.c~` backup 파일). 이 callsite 가 OOS 에 대해 어떻게 동작하는지 코드를 읽어 확인할 필요가 있다 — `file_dealloc` 은 `file_type_hint=FILE_OOS` 일 때 `FILE_TYPE_CAN_BE_NUMERABLE` 가 false 가 되어 user-page-table 분기 (마크 삭제 + `RVFL_USER_PAGE_MARK_DELETE`) 자체를 건너뛰고 early-exit 한다. 그러나 그 직후 `if (!FILE_IS_NUMERABLE (fhead))` 도 별도로 체크하므로 실제 numerable 파일이라면 안전한 두 번째 가드가 있는 셈이다 (`src/storage/file_manager.c:6235-6239`). 즉 현재 상황은 매크로가 *논리적 type list 와 실제 numerable 사용처 간 불일치* 는 만들지만, dealloc 경로에서는 early-exit 만 발생하고 큰 문제가 되지는 않는다 — 단, 매크로가 다른 곳에서 invariant 로 사용되기 시작하면 OOS 가 누락될 위험이 있다.

7. **Recovery surface 가 numerable 채택만큼 넓어진다.** numerable permanent 파일은 mark-delete logical undo, `RVFL_FHEAD_SET_LAST_USER_PAGE_FTAB`, `file_log_extdata_add` 등 user page table 자체에 대한 redo/undo 경로를 활성화시킨다 (`src/storage/file_manager.c:8038`, `:8066`, `:8100`, `:8396-8559`). OOS 의 record-level WAL (`RVOOS_INSERT`/`RVOOS_DELETE`, `src/storage/oos_file.cpp:1658`, `:1677`) 와는 별도의 recovery 경로이며, crash recovery 시 두 경로의 idempotency/interaction (예: ftab append redo 와 chunk insert redo 의 순서) 이 새로 검증 대상이 된다. 본 문서는 이 recovery 경로의 정확성 분석을 다루지 않는다 — out of scope.

## Alternatives considered

코드 안에서 발견되는 alternative 단서 + 메커니즘적 대안:

- `full_search_vpid` 의 TODO 주석 (`src/storage/oos_file.cpp:671-675`): "ideally find the index of full_search_vpid; for now start from 1". 즉 nth 인덱싱에 의존하지 않는 VPID 기반 resume 도 가능했지만 현재는 단순화를 위해 매번 1부터 재인덱싱하고 있다는 의미다.
- `file_get_all_data_sectors` (`src/storage/file_manager.h:294`, 정의 `src/storage/file_manager.c:12588`): partial+full sector 를 모두 모아주는 helper. 현재 `src/storage/external_sort.c:5283` 에서 호출되며, OOS 는 사용하지 않는다. OOS 가 numerable 없이 sync 를 구현했다면 이 helper 가 base 후보 중 하나였을 것이다.
- heap-style `next_vpid` chain 을 OOS page header 에 직접 임베드: `heap_stats_sync_bestspace` 가 `while (!VPID_ISNULL (&next_vpid) || can_cycle == true)` 로 chain 을 따라가는 것 (`src/storage/heap_file.c:3864`) 과 동일한 모델을 OOS page header 에 그대로 적용하는 안. 이 대안은 numerable 의 헤더 페이지 분할/매 alloc WAL/mark-delete logical undo 를 모두 제거하지만, OOS 페이지마다 next_vpid 슬롯과 그 chain 무결성을 위한 update WAL 을 새로 도입해야 한다. Con #4 의 "구조적으로 다르다" 가 가리키는 동일한 trade-off 의 반대쪽 끝이다.

## Conclusion

OOS 가 `is_numerable=true` 로 파일을 만든 결정은, sync 스캔에서 user page enumeration 을 한 줄로 끝낼 수 있게 해주는 대신, (a) 매 OOS 페이지 alloc 마다 user page table append + WAL 이라는 고정 비용, (b) `n_page_mark_delete > 0` 환경에서 sync 의 `max_iterations · n` (또는 `scan_all=true` 경로에서 `n²`) worst-case 비용 비례, (c) numerable temp-only 경로에 묶여 있는 `FILE_CACHE_LAST_FIND_NTH` 캐시를 permanent OOS 에서 사용할 수 없어 OOS sync 의 호출 패턴(`i = 1, 2, 3, ...`)이 캐시 invariant 와 맞음에도 불구하고 게이트가 막혀 사용 불가, (d) ftab/mark-delete 관련 recovery 경로의 추가 비용을 진다. 현재 milestone(M2 — bestspace 도입) 까지는 `file_dealloc` 이 호출되지 않는 가정 하에 numerable 의 이점만 거의 무료로 얻고 있는 상태로 보인다 (`oos_remove_page` 는 TODO 로 vacuum 연동 시점까지 보류, `src/storage/oos_file.cpp:1007`).

권장 사항:
- M3 이후 vacuum 이 `oos_remove_page` 를 실제로 호출하기 시작하면, mark-delete 가 누적되는 패턴에서 sync 성능을 실측하고, 필요하면 numerable 의존을 끊고 heap-style `next_vpid` chain 또는 `file_get_all_data_sectors` 기반 enumeration 으로 sync 를 재작성하는 것을 검토할 만하다.
- 차선책으로, `FILE_CACHE_LAST_FIND_NTH` 의 게이트를 permanent OOS 까지 확장하는 변경도 가능하다 — sync 의 호출 패턴(`i = 1, 2, 3, ...`)이 정확히 external sort 와 동일하게 단조 증가다 (external sort 의 `file_numerable_find_nth` 호출 사이트 `src/storage/external_sort.c:5447`, `:5495`; 캐시 게이트 정의 `src/storage/file_manager.c:181-183`). 다만 캐시의 invariant 가 `m_px_orig_thread_entry == NULL` (parallel thread 가 아니어야 함) 도 요구하므로, OOS 의 동시 접근 시나리오와의 충돌 여부는 별도 검증이 필요하다.
- `FILE_TYPE_CAN_BE_NUMERABLE` 매크로의 enumeration 갱신은 매크로 단일 callsite (`src/storage/file_manager.c:6211`) 가 `file_dealloc` 의 early-exit 가드라는 점을 고려할 때, `FILE_OOS` 를 추가하면 `file_dealloc(FILE_OOS, ...)` 호출 시 early-exit 가 사라지고 user-page-table 마크삭제 분기로 진입하게 된다. 즉 behavior change 가 발생할 수 있으므로, 이 매크로를 갱신하기 전에 `oos_remove_page` 가 실제로 active 한 시점이 와야 안전하다 — 현 단계(M2)에서는 매크로 갱신을 유보하는 편이 낫다.
