# [OOS] OOS 페이지를 위한 3-Tier Bestspace 메커니즘 구현

## Description

### 배경

현재 OOS (Out-of-row Overflow Storage) 파일의 페이지 할당은 `oos_find_best_page()` 함수에서 단일
`unordered_map<VFID, VPID>` 를 사용하여 가장 최근에 삽입된 페이지 하나만 확인한다.
해당 페이지에 공간이 부족하면 즉시 새 페이지를 할당한다.

이로 인해 다음 문제가 발생한다:

- OOS 파일이 불필요하게 커짐 (기존 페이지의 빈 공간을 재활용하지 않음)
- DELETE 후 해제된 공간을 재사용할 방법이 없음
- 단일 페이지에 대한 핫스팟 발생 (동시성 저하)

### 목적

Heap 파일의 검증된 15년 이상의 bestspace 아키텍처를 미러링하여, OOS 파일에 full 3-tier bestspace 메커니즘을
구현한다. INSERT와 DELETE 양쪽 경로 모두 bestspace 캐시와 연동하여 삭제된 공간의 즉시 재활용을 보장한다.

---

## Implementation

### 주요 변경 사항

#### 1. OOS 헤더 페이지 추가 (`OOS_HDR_STATS`)

| 항목 | 설명 |
|------|------|
| 위치 | OOS 파일 page 0, slot 0 |
| 구조체 | `OOS_HDR_STATS` — `best[10]`, `second_best[10]`, 공간 추정 통계 포함 |
| 영속성 | 디스크에 영속 (non-logged hints — WAL 비기록) |
| 파일 생성 | `file_create()` 에 `is_numerable=true` 전달, `file_alloc_sticky_first_page()` 로 헤더 페이지 할당 |

```cpp
struct oos_hdr_stats
{
  VFID oos_vfid;
  struct {
    int num_pages, num_recs;
    float recs_sumlen;
    int num_other_high_best, num_high_best;
    int num_substitutions, num_second_best;
    int head_second_best, tail_second_best, head;
    VPID full_search_vpid;
    VPID second_best[10];
    OOS_BESTSPACE best[10];
  } estimates;
};
```

#### 2. OOS 전용 글로벌 캐시 (`OOS_BESTSPACE_CACHE`)

| 항목 | 설명 |
|------|------|
| 구조 | 듀얼 해시 테이블 (VFID -> entry, VPID -> entry) |
| 뮤텍스 | `oos_bestspace_mutex` — heap 의 `bestspace_mutex` 와 완전 독립 |
| Free list | 엔트리 재사용 풀 (최대 1000개) |
| 초기화 | `oos_bestspace_initialize()` — `heap_manager_initialize()` 에서 호출 |

#### 3. 3-Tier 탐색 알고리즘

```
oos_find_best_page() — 새로운 구현:
│
├─ [1] 헤더 페이지 fix (WRITE latch)
├─ [2] OOS_HDR_STATS 에서 best[] 힌트 로드
│
├─ [3] oos_stats_find_page_in_bestspace()
│   ├── Tier 1: 글로벌 해시 캐시 탐색 (VFID 키)
│   ├── Tier 2: best[10] 순환 배열 탐색
│   └── Tier 3: 후보 페이지 fix (CONDITIONAL_LATCH, zero-wait)
│
├─ [4] 못 찾은 경우 → oos_stats_sync_bestspace()
│   └── OOS 파일 페이지 스캔 (최대 20%, 100개 제한)
│       → best[] 및 글로벌 캐시 재충전
│       → 재탐색
│
└─ [5] 그래도 못 찾은 경우 → oos_file_alloc_new()
```

#### 4. Delete → Bestspace 연동 (완료)

`oos_delete_chain()` 에서 `spage_delete()` + `pgbuf_set_dirty()` 직후 `oos_stats_update()` 를 호출하여, 삭제로 해제된 공간을 bestspace 캐시에 즉시 반영한다.

```
oos_delete_chain() — 각 청크 삭제 루프:
│
├── spage_delete()          — 슬롯 삭제
├── pgbuf_set_dirty()       — 페이지 dirty 마킹
├── oos_stats_update()      — bestspace 캐시 갱신 (NEW)
│   ├── 글로벌 해시 캐시에 해제된 공간 등록
│   └── 헤더 best[] 갱신 (conditional latch, zero-wait)
└── 다음 청크로 이동
```

| 경로 | 동작 |
|------|------|
| Forward delete | `oos_delete_chain()` 에서 `oos_stats_update()` 호출 — 해제된 공간 즉시 캐시 등록 |
| Rollback (undo-of-insert) | `oos_rv_redo_delete()` 에서 `oos_stats_del_bestspace_by_vpid()` 호출 — stale 캐시 엔트리 제거 |
| Crash recovery | Sync scanner 가 자동으로 빈 공간 재발견 (self-healing) |

#### 5. 추가 품질 개선 (`c28e27520`)

| 항목 | 내용 |
|------|------|
| Free space 함수 일관성 | 캐시 저장 시 `spage_get_free_space` -> `spage_max_space_for_new_record` 로 통일 (조회 검증과 동일 함수 사용) |
| Stale best[] 정리 | Full scan 시 `best_count < 10` 조건 제거 — 가득 찬 best[]에서도 stale 엔트리 정리 |
| Phase C 에러 로깅 | Conditional latch 실패 시 `ER_INTERRUPTED` 외 에러를 `oos_trace` 로 기록 |
| Re-fix 에러 전파 | Unconditional re-fix 실패 시 `ER_INTERRUPTED` 이면 즉시 `nullptr` 반환 |

### 변경 파일

| 파일 | 변경 유형 | 내용 |
|------|-----------|------|
| `src/storage/oos_file.hpp` | 수정 | `OOS_HDR_STATS`, `OOS_BESTSPACE` 구조체 추가, `oos_bestspace_initialize/finalize` 선언, `#pragma once` -> `#ifndef` 가드 |
| `src/storage/oos_file.cpp` | 대규모 수정 | 전체 bestspace 인프라 구현 (~500줄 추가), `oos_file_create()` numerable 변경, `oos_find_best_page()` 3-tier 교체, `oos_delete_chain()` -> `oos_stats_update()` 연동 |
| `src/storage/heap_file.c` | 수정 | `heap_manager_initialize/finalize()` 에 `oos_bestspace_initialize/finalize()` 호출 추가 |
| `unit_tests/oos/test_oos.cpp` | 수정 | `bridge_oos_get_recently_inserted_oos_vpid` 제거, OID 기반으로 교체 |
| `unit_tests/oos/test_oos_bestspace.cpp` | 신규 | 21개 bestspace 전용 테스트 (delete 연동 3개 포함) |
| `unit_tests/oos/CMakeLists.txt` | 수정 | `test_oos_bestspace` 테스트 등록 및 `FIXTURES_REQUIRED OOS_DB` 추가 |

---

## Acceptance Criteria

- [x] `oos_find_best_page()` 가 3-tier 탐색 (글로벌 캐시 -> best[10] -> sync -> alloc) 을
  수행하여 기존 페이지의 빈 공간을 재활용
- [x] `oos_delete_chain()` 에서 `oos_stats_update()` 호출하여 삭제된 공간이 bestspace 캐시에 즉시 반영
- [x] Rollback 시 `oos_rv_redo_delete()` 에서 stale 캐시 엔트리가 제거됨
- [x] Crash 후 restart 시, 빈/stale 힌트로도 정상 동작 (sync scanner 가 자동 복구)
- [x] 다중 트랜잭션 동시 INSERT 시 deadlock 없음 (zero-wait conditional latch)
- [x] 단위 테스트 전체 통과 (bestspace 21개 + OOS 기존 15개 + SQL 테스트 8개)
- [x] `#pragma once` -> `#ifndef _OOS_FILE_HPP_` 가드로 변경
- [x] Delete -> Insert 공간 재활용 검증 (stale-low 캐시 시나리오, 멀티 페이지, 멀티 청크)

---

## Delete -> Bestspace 연동 상세

### 연동 전후 비교

```
                    oos_insert                    oos_delete
                       |                              |
                       v                              v
              oos_insert_within_page          oos_delete_chain
                       |                              |
                       +-- spage_insert               +-- spage_delete
                       |                              |
                       +-- oos_stats_add_bestspace    +-- oos_stats_update  <-- NEW
                       |   (캐시에 남은 공간 등록)     |   (캐시에 해제 공간 등록)
                       |                              |
                       v                              v
              oos_find_best_page <--------------------+
                       |              캐시에서 재사용 가능 페이지 발견
                       +-- Tier 1: 글로벌 해시 캐시
                       +-- Tier 2: best[10] 배열
                       +-- Tier 3: sync scan
                       +-- Fallback: 신규 페이지 할당
```

| 측면 | 연동 전 | 연동 후 |
|------|---------|---------|
| Delete 후 캐시 상태 | Stale (insert 시점 값 유지) | 갱신됨 (실제 freed space 반영) |
| Delete 후 공간 재활용 | Sync scan fallback으로만 가능 | Tier 1 해시 캐시에서 즉시 발견 |
| 멀티 청크 삭제 | 어떤 청크 페이지도 미등록 | 모든 청크 페이지 등록 |
| 성능 영향 | 불필요한 신규 페이지 할당 | 즉시 재활용 -> 파일 성장 억제 |

### 핵심 시나리오 검증

**Stale-low 캐시 시나리오** (`DeleteUpdatesBestspaceCacheDirectly`):

1. 페이지를 거의 채움 (캐시에 ~100B free 기록)
2. 레코드 삭제 (실제 ~16KB 해제, `oos_stats_update` 가 캐시 갱신)
3. 2KB 레코드 insert -> 캐시에서 즉시 해당 페이지 발견하여 재사용

연동 전에는 stale 캐시(100B) < needed(2KB)로 엔트리가 evict되어 신규 페이지가 할당되었으나,
연동 후에는 캐시가 ~16KB로 갱신되어 동일 페이지를 즉시 재사용한다.

---

## Remarks

### 설계 결정

- Heap 의 `heap_Bestspace` 글로벌 캐시와 **완전히 분리된** 독립 캐시 사용 -> heap INSERT 성능에 영향 없음
- `file_create()` 에 `is_numerable=true` 전달 -> `file_numerable_find_nth()` 로 sync
  scanner 구현 가능
- `file_alloc_sticky_first_page()` 로 헤더 페이지 할당 -> 이후 `file_alloc()` 에서 page 0 이
  재할당되지 않음 보장
- 모든 bestspace 힌트는 non-logged (WAL 비기록) -> crash 후 부정확해도 sync 가 자동 복구
- `oos_stats_update()` 는 conditional latch로 헤더를 잡으므로 `oos_delete_chain` 의 데이터 페이지 write latch와 deadlock 위험 없음

### 후속 작업

- [x] ~~Forward OOS delete 경로 구현 시 `oos_stats_update()` 연동~~ (완료, `c28e27520`)
- [ ] 성능 벤치마크 (별도 태스크)
- [ ] OOS OID 재사용 (M3 범위)
- [ ] `PRM_ID_HF_MAX_BESTSPACE_ENTRIES` 를 OOS 전용 파라미터로 분리 검토

### 참고 문서

- 참고 구현:
  `src/storage/heap_file.c` — `heap_stats_find_best_page()`,
  `heap_stats_sync_bestspace()`
