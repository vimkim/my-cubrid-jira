# [OOS] OOS bestspace를 heap과 공유하는 shard 구조로 전환

## Issue Triage

**이슈 수행 목적**: OOS 페이지 선택을 CBRD-26176의 shard 기반 bestspace와 같은 공통 모듈로 전환한다. OOS 전용 legacy bestspace는 완전히 제거하고, heap과 OOS가 하나의 탐색·동시성 정책을 사용하도록 한다.

**이슈 수행 이유**:

| 구분 | 내용 |
|------|------|
| **AS-IS (현재 동작 / 배경)** | OOS는 청크를 넣을 페이지를 찾을 때 OOS 헤더 페이지를 WRITE latch로 잡고, 전체 OOS 파일이 공유하는 `bestspace_mutex` 아래에서 최대 `OOS_BESTSPACE_CACHE_CAPACITY`(1000)개의 VFID/VPID 해시 엔트리와 `best[10]`/`second_best[10]` 을 탐색한다. 후보가 없으면 여유 페이지 비율 `OOS_BESTSPACE_SYNC_THRESHOLD`(0.1)을 기준으로 최대 `oos_Find_best_page_limit`(100)개 페이지를 다시 훑는다. 반면 heap은 CBRD-26176 이후 lock-free L1/L2/L3 shard와 candidate queue를 사용하므로 두 저장소의 정책과 구현이 갈라져 있다. |
| **TO-BE (목표 상태 / 기대 동작)** | lock-free shard 탐색, candidate queue, 한 shard당 단일 할당자 규칙을 공통 bestspace 모듈이 담당한다. heap과 OOS adapter는 페이지 검증·할당·영속화·통계만 각각 맡으며, OOS의 정상 탐색 경로에서는 헤더 WRITE latch, 전역 mutex, 반복 sync scan을 사용하지 않는다. |

**영향**: 성능 저하 — 여러 트랜잭션이 같은 OOS 파일에 값을 넣으면 각 OOS 청크의 페이지 선택이 헤더 latch와 전역 mutex에 모인다. OOS가 heap의 개선과 별도로 legacy 구현을 유지하면 동시성 수정, stale hint 처리, 페이지 회수 정책도 두 벌로 계속 보정해야 한다.

**이슈 수행 방안**:

| 영역 | 합의 방안 |
|------|-----------|
| 공통 모듈 | 탐색·shard·candidate·할당 소유권을 공유하고 heap/OOS adapter를 둔다. 공통 interface가 저장소별 분기와 세부 정보를 노출해야만 성립한다면 구현을 중단하고 근거를 다시 검토한다. OOS 전용 복제 구현으로 자동 전환하지 않는다. |
| OOS 영속화 | `FILE_OOS` 안에 전용 `PAGE_OOS_BESTSPACE` 페이지를 두고 OOS 헤더가 이를 참조한다. snapshot은 30초 주기의 redo-only hint이며, restart 후 snapshot을 즉시 읽고 sector bitmap을 한 번 점진적으로 순회해 누락된 free space를 보정한다. |
| 정책 | registry 공통 key는 `VFID` 로 하고 기존 `bestspace_shard_count`, `bestspace_distributed_insert`, `bestspace_cache_count` 를 함께 사용한다. OOS도 replenishment 한 번에 최대 4페이지를 할당한다. |
| 선행 조건·호환성 | CBRD-26950을 먼저 병합해 OOS data page의 slot 0 `OOS_PAGE_HEADER` 를 도입하고, CBRD-26786으로 non-numerable `FILE_OOS` 와 빈 페이지 회수 생애 주기를 확정한다. 이 이슈는 page header에 `owner_vfid` 를 추가한다. heap의 on-disk format과 동작은 유지하며, 미출시 OOS format만 호환성을 깨고 교체할 수 있다. |
| 검증 | 공통 모듈·heap 회귀·OOS adapter/restart/rebuild·4KB/8KB/16KB page size를 검증한다. 성능 benchmark는 선택 사항이다. CI에 기존 실패가 있으면 동일 commit baseline과 비교해 상속된 실패임을 보고하고, 이 변경이 만든 신규 실패만 차단한다. |

---

## AI-Generated Context

> 아래는 AI가 코드와 관련 이슈를 분석해 작성한 상세 자료다. 빠른 triage에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현·리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: `src/storage/bestspace.{hpp,cpp}` 의 interface와 registry, `src/storage/oos_file.{hpp,cpp}` 의 페이지 선택·헤더 format·복구, page type/recovery index 정의, heap/OOS unit test와 SQL/medium 회귀가 대상이다. SQL 문법과 사용자 가시 저장 규칙은 바뀌지 않는다.

## Description

`OOS`(Out-of-row Overflow Storage — heap 레코드의 큰 가변 컬럼을 별도 파일에 청크 단위로 저장하는 방식)는 한 파일의 기존 페이지에서 청크가 들어갈 공간을 먼저 찾고, 없을 때만 새 페이지를 할당한다. 이 free-space hint가 bestspace다. hint는 실제 페이지 상태를 대신하지 않으며, 후보 페이지를 fix한 뒤 `spage_max_space_for_new_record` 로 실측해야만 사용할 수 있다.

현재 OOS bestspace는 CBRD-26658에서 당시 heap 구조를 옮겨 만든 독립 구현이다. 기준 commit `725a32c` 의 호출 흐름은 다음과 같다.

```
oos_insert / oos_insert_many
  -> oos_find_best_page
       -> OOS header WRITE latch
       -> oos_stats_find_page_in_bestspace
            -> VFID/VPID global hash (`bestspace_mutex`)
            -> OOS header `best[10]`
            -> candidate page conditional fix + free-space measurement
       -> miss + ratio >= 0.1
            -> oos_stats_sync_bestspace (up to 100 pages)
       -> miss
            -> oos_file_alloc_new
```

한 OOS 값이 여러 청크로 나뉘면 이 흐름이 청크마다 반복된다. `bestspace_mutex` 는 모든 OOS 파일의 두 해시를 함께 보호하고, `oos_find_best_page` 는 탐색을 시작할 때마다 해당 파일의 헤더를 WRITE latch로 잡는다. 후보 실측에는 conditional latch를 쓰더라도 그 앞단의 두 직렬화 지점은 남는다.

이 구조의 sync scan은 이미 실제 성능 회귀를 만든 적이 있다. CBRD-26824에서는 첫 miss마다 scan하던 조건 때문에 3MB 값의 후반 INSERT가 164ms에서 890ms까지 늘었다. 해당 조건은 수정됐지만, cache miss를 파일 순회로 보충하는 legacy 구조 자체와 OOS 전용 정책은 그대로 남아 있다.

CBRD-26176은 heap bestspace를 lock-free L1/L2/L3 shard와 candidate queue로 바꿨다. 그러나 현재 `cubstorage::bestspace` 를 OOS에서 그대로 호출할 수는 없다.

```
cubstorage::bestspace (현재)
  search/concurrency policy
  + HFID validation
  + PAGE_HEAP / class OID ownership check
  + heap unfill calculation
  + heap_alloc_new_pages
  + heap record/page statistics
  + heap ordered-fix rank
  + heap-specific persistent shard pages
```

즉 재사용 대상은 class 전체가 아니라 탐색·동시성 정책이다. 저장소별 지식을 adapter 뒤로 옮기지 않고 `if (heap) ... else if (oos) ...` 를 공통 구현에 퍼뜨리면 interface가 구현만큼 복잡한 얕은 모듈이 된다. 반대로 OOS용으로 class를 복사하면 이번 변경 뒤에도 두 구현이 다시 갈라진다. 따라서 공통 모듈은 free-space hint의 탐색과 경쟁 조정만 소유하고, 실제 페이지 작업은 두 adapter가 맡아야 한다.

CBRD-26786은 OOS 파일을 non-numerable로 바꾸고 빈 OOS 페이지를 vacuum 커밋 뒤 `file_dealloc` 로 반환하는 구현이다. 이 페이지 생애 주기가 먼저 확정돼야 OOS adapter가 deallocated page를 정상 stale hint로 처리하고, sector bitmap에서 data page만 열거하며, metadata page를 회수 대상에서 제외할 수 있다.

page type만 확인해서는 persistent hint를 안전하게 재사용할 수 없다. 예를 들어 OOS file A의 snapshot이 data page VPID를 보관한 뒤 CBRD-26786이 그 page를 deallocate하면, file manager는 같은 VPID를 OOS file B에 다시 줄 수 있다. restart 후 A의 stale hint가 `PAGE_OOS` 만 검사하면 B의 page도 정상 후보처럼 보인다.

CBRD-26950은 모든 OOS data page의 slot 0에 `OOS_PAGE_HEADER` 를 두고 generation counter를 저장하는 accepted design이다. 이 header에 `owner_vfid` 를 함께 기록하면 candidate fix만으로 현재 file 소유권까지 검증할 수 있다. 별도의 file-header latch나 allocation-bitmap lookup을 매 후보마다 추가하지 않아도 되며, heap bestspace가 page 안의 class OID로 소유권을 확인하는 규칙과도 대응한다.

## Specification Changes

사용자 가시 SQL과 manual 변경은 N/A다. 내부 저장·복구 규칙은 아래와 같이 변경한다.

| 항목 | 변경 스펙 |
|------|-----------|
| 공통 bestspace | L1/L2/L3 shard, candidate queue, tier 탐색, shard allocation ownership을 heap/OOS가 공유한다. hint는 비권위 정보이며 실제 page fix와 free-space 실측이 최종 판단이다. |
| Registry | 공통 key는 `VFID` 다. heap adapter는 `HFID` 와 class OID를, OOS adapter는 OOS VFID와 owner 정보를 자기 context에 보관한다. |
| OOS data page identity | CBRD-26950의 slot 0 `OOS_PAGE_HEADER` 에 generation counter와 `owner_vfid` 를 저장한다. `PAGE_OOS` 와 `owner_vfid` 가 모두 일치해야 해당 OOS file의 candidate로 인정한다. |
| OOS metadata page type | bestspace snapshot 페이지는 `PAGE_OOS_BESTSPACE` 로 표시한다. `PAGE_OOS_BESTSPACE` 와 sticky OOS header page는 청크 저장·OOS data 통계·vacuum reclaim·sector-bitmap data-page 순회에서 제외한다. |
| OOS header | metadata page 개수와 VPID 목록, snapshot format/version, 점진 rebuild 진행 상태를 식별할 정보를 보관한다. 기존 `best[10]`, `second_best[10]`, sync-scan 추정 필드는 제거한다. OOS 통계 필드는 bestspace와 분리해 유지한다. |
| Snapshot | metadata page 생성은 정상 WAL로 보호한다. 이후 hint snapshot 갱신은 OOS 전용 redo-only recovery index를 사용하며 undo는 두지 않는다. hint가 마지막 갱신보다 오래돼도 데이터 정합성에는 영향을 주지 않는다. |
| Restart | snapshot을 즉시 registry에 적재한 뒤, non-numerable `FILE_OOS` 의 sector bitmap을 한 번 점진적으로 순회한다. 한 OOS 파일에서 동시에 하나의 rebuild만 진행하며, cursor를 청크마다 처음으로 되돌리지 않는다. |
| Hint failure | stale/missing/format-invalid snapshot은 경고를 남기고 버린 뒤 rebuild한다. page I/O, WAL, allocation 실패는 hint 문제로 숨기지 않고 기존 CUBRID error model로 반환한다. |
| Page allocation | 후보가 부족하면 OOS adapter가 한 번에 최대 `bestspace::ALLOC_BATCH_SIZE`(4)개 data page를 할당하고, caller가 사용할 한 페이지의 WRITE latch를 연속해서 인계한다. |
| Space accounting | OOS는 heap unfill을 적용하지 않는다. `spage_max_space_for_new_record` 가 새 slot 비용을 이미 반영하므로 필요한 크기는 OOS record 길이 그대로 비교한다(CBRD-26954). |
| Configuration | `bestspace_shard_count`(기본 8, 범위 1~28), `bestspace_distributed_insert`, `bestspace_cache_count`(기본 40, 범위 10~128)를 그대로 공유한다. OOS 전용 parameter는 추가하지 않는다. |
| Compatibility | heap bestspace의 기존 on-disk layout과 동작을 유지한다. `feat/oos` 는 미출시이므로 OOS header와 file layout은 이전 실험 DB와 호환하지 않아도 된다. |

## Implementation

### 공통 module seam

목표 호출 관계는 다음과 같다. 함수명은 구현 과정에서 조정할 수 있지만 책임 방향은 바꾸지 않는다.

```
heap_find_bestpage --------------------+
                                        |
                                        v
                                shared bestspace
                               +------------------+
                               | registry (VFID)  |
                               | L1/L2/L3 shards  |
                               | candidate queue  |
                               | tier search      |
                               | allocation owner |
                               +------------------+
                                  ^            ^
                                  |            |
                         heap adapter        OOS adapter
                         - HFID/class        - OOS VFID/owner
                         - PAGE_HEAP         - PAGE_OOS
                         - unfill            - no unfill
                         - heap alloc        - OOS batch alloc
                         - heap snapshot     - OOS snapshot
                                  ^            ^
                                  |            |
                                  +            +-- oos_find_best_page
```

공통 interface가 표현해야 하는 동작은 후보 page 검증, actual free-space 반환, data page batch 할당, snapshot load/store, lifecycle destroy다. page type, class ownership, latch rank, file-specific header format과 통계 필드는 adapter 밖으로 노출하지 않는다. 두 adapter를 구현한 뒤에도 공통 module에 저장소별 조건 분기가 다수 남거나 caller가 adapter 내부 규칙을 알아야 한다면, code review 전에 interface 설계를 다시 검토한다.

### OOS adapter

OOS 후보 page는 다음 순서로 검증한다.

```
candidate VPID
  -> OLD_PAGE_MAYBE_DEALLOCATED + ordered WRITE fix
  -> deallocated page면 stale hint로 제거
  -> page type == PAGE_OOS 확인
  -> slot 0 OOS_PAGE_HEADER 읽기
  -> page_header.owner_vfid == requested OOS VFID 확인
  -> spage_max_space_for_new_record 실측
  -> record length가 들어가면 latch를 caller에 인계
```

page type 또는 `owner_vfid` 가 맞지 않으면 해당 L1/candidate entry를 제거하고 다른 후보를 찾는다. 이는 hint miss이며 오류가 아니다. `OOS_PAGE_HEADER` 자체를 읽을 수 없거나 format이 맞지 않으면 snapshot-invalid 복구 규칙과 실제 page corruption 규칙을 구분해 처리한다.

CBRD-26786이 정한 insert latch 연속성을 유지해야 한다. 후보를 검사한 뒤 unfix/re-fix하지 않으며, 새 page도 할당 시 받은 WRITE latch를 OOS record 삽입이 끝날 때까지 넘긴다. empty-page reclaim과 경합해도 "비어 있음을 확인한 page를 writer가 나중에 다시 잡는" 공백이 생기지 않아야 한다.

candidate가 모두 부족한 shard는 allocation owner 한 명만 OOS adapter를 호출한다. adapter는 최대 4페이지를 한 번에 만들고, 한 페이지는 caller에 반환하며 나머지는 shard/candidate로 공급한다. OOS record count와 payload length는 기존 OOS 통계 경로에서 갱신하고 shared bestspace의 heap estimates에 넣지 않는다.

### Persistence and recovery

OOS header는 metadata VPID 목록과 format 식별자만 소유한다. shard entry와 candidate snapshot은 `PAGE_OOS_BESTSPACE` 에 저장하며 4KB, 8KB, 16KB page size에서 필요한 페이지 수를 계산한다. metadata page 생성·연결은 system operation으로 원자화하고, snapshot 갱신은 CBRD-26176과 같은 30초 `updatable()` gate를 거친다.

restart 시 snapshot이 유효하면 곧바로 page search에 사용할 수 있다. 동시에 한 registry entry가 sector bitmap의 frozen snapshot을 순차 소비해 모든 `PAGE_OOS` data page를 한 번씩 재검증한다. 이미 deallocate된 page는 건너뛰고, metadata/header page는 후보와 통계에서 제외한다. 순회 도중 발견한 free space는 candidate queue에 공급한다. 한 pass가 끝나면 다음 restart 또는 명시적 rebuild 전까지 다시 시작하지 않는다.

snapshot이 없거나 format이 맞지 않으면 빈 bestspace로 시작해 같은 점진 rebuild를 수행한다. 이 경우도 신규 page 할당과 INSERT는 가능해야 한다. 반면 metadata page fix, WAL append, 새 page allocation에서 실제 error가 발생하면 실패를 전파한다.

### Lifecycle and cleanup

공통 registry entry는 file create/lazy first use에서 생성하고, DROP/heap reuse/OOS file removal 및 dropped-file recovery notification에서 `VFID` 로 제거한다. server finalize에서는 registry가 소유한 memory를 정리한다.

다음 OOS 전용 legacy 구현은 삭제한다.

- `OOS_STATS_BESTSPACE_CACHE`, VFID/VPID hash, free list, `bestspace_mutex`
- `OOS_BESTSPACE_CACHE_CAPACITY`, `OOS_DROP_FREE_SPACE`, `OOS_BESTSPACE_SYNC_THRESHOLD`
- `best[10]`, `second_best[10]`, 관련 ring/index/substitution 필드
- `oos_stats_find_page_in_bestspace`, `oos_stats_sync_bestspace` 와 current header-latch 탐색
- `oos_bestspace_initialize`/`oos_bestspace_finalize` 및 heap manager 연결
- 내부 함수에 직접 접근하는 `bridge_oos_*bestspace*` test seam

## Acceptance Criteria

### Shared module and heap

- [ ] L1/L2/L3 shard, candidate queue, tier search, allocation ownership 구현은 heap과 OOS가 같은 module을 사용한다.
- [ ] 공통 module의 registry lookup key는 `VFID` 이며 heap/OOS 세부 context는 adapter가 소유한다.
- [ ] heap adapter는 CBRD-26176의 page validation, unfill, statistics, ordered-fix, batch allocation 동작을 보존한다.
- [ ] heap header와 persistent bestspace page의 on-disk layout이 변경되지 않는다.
- [ ] 기존 bestspace unit/regression test가 변경 전과 같은 결과를 낸다.

### OOS behavior

- [ ] CBRD-26950의 `OOS_PAGE_HEADER` 를 기준으로 구현하고 slot 0에 `owner_vfid` 를 추가한다.
- [ ] CBRD-26786의 non-numerable `FILE_OOS`, empty-page reclaim, latch 연속성을 기준으로 구현한다.
- [ ] OOS header가 `PAGE_OOS_BESTSPACE` VPID와 snapshot format/version을 관리한다.
- [ ] `PAGE_OOS_BESTSPACE` 는 OOS INSERT 후보, OOS record/page 통계, vacuum reclaim, sector-bitmap data-page 순회에서 제외된다.
- [ ] OOS snapshot을 저장한 뒤 restart하면 shard/candidate가 복원되고 기존 data page를 재사용한다.
- [ ] stale/missing/format-invalid snapshot에서 INSERT가 가능하며, 점진 rebuild가 모든 data page를 한 번 방문한 뒤 종료한다.
- [ ] rebuild cursor가 청크마다 초기화되지 않고, 동일 OOS 파일에서 rebuild worker/owner가 하나만 존재한다.
- [ ] deallocated candidate는 오류 없이 stale hint에서 제거하며, 실제 I/O/WAL/allocation 오류는 caller에 반환한다.
- [ ] 다른 OOS file에 재할당된 동일 VPID candidate는 `owner_vfid` 불일치로 제거하고 그 page에 청크를 쓰지 않는다.
- [ ] OOS의 필요 공간은 record length로 비교해 CBRD-26954의 exact-fit slot 재사용 동작을 유지한다.
- [ ] 후보가 부족할 때 최대 4페이지 batch allocation을 수행하고 나머지 페이지를 bestspace에 공급한다.
- [ ] delete/vacuum이 돌려준 partial free page를 candidate로 즉시 공급해 restart 전에도 재사용한다.
- [ ] OOS record count/payload statistics는 OOS adapter에 남고 heap estimates와 섞이지 않는다.

### Compatibility and cleanup

- [ ] 기존 OOS global hash/mutex, `best[10]`/`second_best[10]`, sync scan, lifecycle hook, 내부 bridge test를 제거한다.
- [ ] 기존 heap DB는 disk compatibility를 유지한다. 이전 `feat/oos` 실험 DB는 재생성이 필요함을 PR과 QA notes에 명시한다.
- [ ] `bestspace_shard_count`, `bestspace_distributed_insert`, `bestspace_cache_count` 를 공유하며 OOS 전용 parameter를 추가하지 않는다.

### Verification

- [ ] shared bestspace interface를 통한 unit test를 추가하고 heap/OOS adapter 결과를 각각 검증한다.
- [ ] OOS page reuse, exact-fit, multi-file isolation, stale hint, file removal, restart, invalid snapshot, incremental rebuild test를 추가한다.
- [ ] metadata page가 INSERT/vacuum/statistics/enumeration에 노출되지 않는 test를 추가한다.
- [ ] 4KB, 8KB, 16KB page size에서 metadata page 수와 layout, create/restart/insert를 검증한다.
- [ ] OOS unit/SQL test와 관련 heap bestspace test를 수행한다.
- [ ] `test_sql`, `test_medium` 결과를 수집한다. 동일 환경·동일 source baseline에서도 재현되는 legacy 실패는 test 이름과 양쪽 log를 보고하며, 이 변경에서 새로 발생한 실패는 허용하지 않는다.
- [ ] 1/8/32 session OOS INSERT benchmark는 선택 사항이다. 수행했다면 환경, workload, before/after 수치를 보고하되 완료 조건으로 사용하지 않는다.

## Definition of done

- [ ] 위 Acceptance Criteria를 충족한다.
- [ ] 공통 interface가 heap/OOS 조건 분기 없이 두 adapter를 수용하는지 maintainer review를 받는다.
- [ ] 신규·변경 test가 통과하고, 전체 CI의 legacy 실패는 baseline 비교 자료로 분리 보고한다.
- [ ] OOS 실험 DB 재생성 필요성을 PR/QA notes에 기록한다.
- [ ] 사용자 manual 변경은 N/A다.

## References

- 기준 source: CUBRID `725a32c6ee0d7cb2b27dedd2283b03a9a93de608`
- 현재 OOS legacy cache: `src/storage/oos_file.cpp:109-141,243-444,512-695,1908-2072`
- 현재 OOS header format: `src/storage/oos_file.hpp:64-94`, `src/storage/oos_file.cpp:969-1059`
- 현재 heap bestspace: `src/storage/bestspace.hpp:50-470`, `src/storage/bestspace.cpp:583-650,875-1013,1363-1456,1564-1607,1662-1724`
- 기존 parameter: `src/base/system_parameter.c:5394-5429`
- CBRD-26176: <http://jira.cubrid.org/browse/CBRD-26176>
- CBRD-26950: <http://jira.cubrid.org/browse/CBRD-26950>
- CBRD-26786: <http://jira.cubrid.org/browse/CBRD-26786>
- CBRD-26831: <http://jira.cubrid.org/browse/CBRD-26831>
- CBRD-26824: <http://jira.cubrid.org/browse/CBRD-26824>
- CBRD-26954: <http://jira.cubrid.org/browse/CBRD-26954>

## Remarks

- 이 이슈는 live JIRA의 `Sub-task` 를 유지하되, 변경 성격은 기존 기능·성능 개선이다.
- 선행 순서는 CBRD-26950 -> CBRD-26786 -> CBRD-27213이다. 선행 branch가 달라졌다면 `OOS_PAGE_HEADER`, non-numerable 전환, empty-page reclaim 시점, insert latch 연속성을 다시 확인한다.
