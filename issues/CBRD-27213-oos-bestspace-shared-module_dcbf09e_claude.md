# [OOS] [TODO] 재시작 뒤에도 OOS 빈 공간을 재사용하도록 bestspace를 heap 재설계 기반으로 전환

## Issue Triage

**이슈 수행 목적**: OOS 페이지 선택을 heap bestspace와 같은 공통 모듈로 전환해, 서버 재시작이나 비정상 종료 뒤에도 기존 OOS 페이지의 부분 여유 공간을 다시 찾아 재사용하게 한다. OOS 전용 legacy bestspace(전역 해시, 헤더 `best[]`, 3단계 sync)는 완전히 제거하고, heap과 OOS가 하나의 탐색·동시성 정책을 사용하도록 한다.

**이슈 수행 이유**: OOS는 heap이 CBRD-26176에서 교체한 legacy 구조를 그대로 쓴다. 청크마다 페이지를 고를 때 OOS 헤더 WRITE latch와 모든 OOS 파일이 공유하는 `bestspace_mutex`를 거친다. 또한 재시작 뒤 빈 공간을 다시 찾지 못한다. 메모리 해시는 재시작으로 비고, 이를 다시 채울 3단계 sync는 발동 조건이 읽는 `estimates.num_pages`가 실제 헤더에 기록되지 않아 운영 경로에서 실행되지 않는다. PR #7990 리뷰(R4)가 이 결함을 재현과 함께 보고했고, 리뷰어는 "bestspace redesign 안정화 후 oos에 적용"할 계획을 밝혔다. 이 이슈의 재설계가 legacy 해시·`best[]`·sync를 삭제하므로 R4는 legacy 경로의 별도 수정이 아니라 이 이슈에서 해결한다.

**영향**: OOS 값을 삭제한 뒤 서버를 재시작하면, 부분적으로 빈 OOS 페이지를 두고 새 페이지를 할당해 OOS 파일이 커진다. 리뷰어 측정(release 빌드)에서 절반쯤 빈 OOS 페이지 201개가 있는 파일에 같은 크기 값 100행을 넣으면, 재시작 없이는 201개 그대로였고 재시작 뒤에는 246개로 늘었다. 데이터 정합성에는 영향이 없고, 완전히 빈 페이지는 CBRD-26786의 회수 sweep이 재시작 뒤에도 회수한다. 실제 운영 부하에서의 공간 증가 폭과 동시 INSERT의 직렬화 비용은 측정하지 않았다. heap과 별도 구현을 유지하는 동안에는 동시성 수정, stale hint 처리, 페이지 회수 정책을 두 벌로 고쳐야 한다.

**이슈 수행 방안**: TBD - heap 재설계(CBRD-27761)가 안정된 뒤 ANALYSIS 단계에서 공통 모듈의 기준 구조와 구현 범위를 다시 확정한다. 아래 2026-09 합의 방안은 재확정 전까지 참고안이다. 이 이슈가 끝나기 전까지 OOS legacy 경로는 고치지 않고, 재시작 뒤 부분 여유 페이지 미재사용을 알려진 제약으로 둔다.

| 영역 | 2026-09 합의 방안(참고안) |
|------|---------------------------|
| 공통 모듈 | 탐색·shard·candidate·할당 소유권을 공유하고 heap/OOS adapter를 둔다. 공통 interface가 저장소별 분기와 세부 정보를 노출해야만 성립한다면 구현을 중단하고 근거를 다시 검토한다. OOS 전용 복제 구현으로 자동 전환하지 않는다. CBRD-27761은 heap에서 candidate queue를 제거하고 전 페이지 맵으로 바꾸려 하므로, candidate 공유는 재검토 대상이다. |
| OOS 영속화 | `FILE_OOS` 안에 전용 `PAGE_OOS_BESTSPACE` 페이지를 두고 OOS 헤더가 이를 참조한다. snapshot은 30초 주기의 redo-only hint이며, restart 후 snapshot을 즉시 읽고 sector bitmap을 한 번 점진적으로 순회해 누락된 free space를 보정한다. CBRD-27761은 heap에서 30초 snapshot과 메타 페이지 snapshot을 없애고 체크포인트 때 맵을 기록하려 하므로, 이 행 전체가 재검토 대상이다. |
| 정책 | registry 공통 key는 `VFID` 로 하고 기존 `bestspace_shard_count`, `bestspace_distributed_insert`, `bestspace_cache_count` 를 함께 사용한다. OOS도 replenishment 한 번에 최대 4페이지를 할당한다. |
| 선행 조건·호환성 | 선행 이슈 CBRD-26950과 CBRD-26786은 완료됐고 PR #7990 head(`dcbf09e`)에 들어 있다. 합의 당시에는 CBRD-26950의 slot 0 `OOS_PAGE_HEADER` 에 `owner_vfid` 를 추가하기로 했다. 그러나 CBRD-26950은 page LSA identity stamp로 설계를 바꿔 slot 0 header를 만들지 않았으므로, `owner_vfid` 의 기록 위치는 재검토 대상이다. heap의 on-disk format과 동작은 유지하며, 미출시 OOS format만 호환성을 깨고 교체할 수 있다. |
| 검증 | 공통 모듈·heap 회귀·OOS adapter/restart/rebuild·4KB/8KB/16KB page size를 검증한다. 성능 benchmark는 선택 사항이다. CI에 기존 실패가 있으면 동일 commit baseline과 비교해 상속된 실패임을 보고하고, 이 변경이 만든 신규 실패만 차단한다. |

---

## AI-Generated Context

> 아래는 제공된 자료와 확인한 근거를 바탕으로 작성한 상세 맥락이다. 미확인 사항은 본문에 구분한다. 코드 줄 번호는 PR #7990 head `dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67` 기준이다.

## Description

### 무엇이 문제인가

OOS(Out-of-row Overflow Storage)는 heap 레코드의 큰 가변 컬럼을 별도 파일에 청크 단위로 저장한다. OOS는 한 파일의 기존 페이지에서 청크가 들어갈 공간을 먼저 찾고, 없을 때만 새 페이지를 할당한다. 이 free-space hint가 bestspace다. hint는 실제 페이지 상태를 대신하지 않으며, 후보 페이지를 fix한 뒤 `spage_max_space_for_new_record` 로 실측해야만 사용할 수 있다.

현재 OOS bestspace는 CBRD-26658에서 당시 heap 구조를 옮겨 만든 독립 구현이다. PR #7990 head의 호출 흐름은 다음과 같다.

```
oos_insert / oos_insert_many
  -> oos_find_best_page
       -> OOS header WRITE latch
       -> oos_stats_find_page_in_bestspace
            -> VFID/VPID global hash (bestspace_mutex)
            -> OOS header best[10]
            -> candidate page conditional fix + free-space measurement
       -> miss + (num_other_high_best / num_pages) >= 0.1
            -> oos_stats_sync_bestspace (up to 100 pages)   운영 경로에서 실행되지 않음
       -> miss
            -> oos_alloc_page_with_reclaim
                 -> oos_reclaim_sweep_step (CBRD-26786 빈 페이지 회수 sweep)
                 -> oos_file_alloc_new
```

한 OOS 값이 여러 청크로 나뉘면 이 흐름이 청크마다 반복된다. `bestspace_mutex` 는 모든 OOS 파일의 두 해시를 함께 보호하고, `oos_find_best_page` 는 탐색을 시작할 때마다 해당 파일의 헤더를 WRITE latch로 잡는다. 후보 실측에는 conditional latch를 쓰더라도 그 앞단의 두 직렬화 지점은 남는다.

#### 재시작 뒤 빈 공간을 다시 찾지 못한다 (PR #7990 R4)

OOS의 빈 공간 hint는 메모리의 전역 해시와 헤더의 `best[10]` 이다. 전역 해시는 서버가 시작될 때 비어 있다. 헤더의 `best[10]` 은 로그 없이 갱신하는 hint라 재시작 뒤 남더라도 10개다. 이를 보충하는 수단이 3단계 sync(`oos_stats_sync_bestspace`)다.

`oos_find_best_page` 는 후보를 못 찾으면 `num_other_high_best / num_pages` 가 0.1 이상일 때만 sync를 부른다(`oos_file.cpp:3080-3086`). 그런데 `estimates.num_pages` 를 쓰는 코드는 sync 함수 안의 두 줄뿐이다(`oos_file.cpp:985`, `1001`). 운영 경로의 유일한 sync 호출(`oos_file.cpp:3103-3105`)은 지역 변수 `tmp_hdr` 를 넘기고 결과를 버린다. 다른 호출자는 unit test용 `bridge_oos_stats_sync_bestspace` 뿐이다. 파일 생성 때 0으로 초기화한 `num_pages`(`oos_file.cpp:1164-1165`)는 계속 0이므로 비율도 0이고, sync는 실행되지 않는다(소스 추론). 리뷰어는 재시작 뒤 조건 검사 45번에서 `num_pages` 와 `num_other_high_best` 가 모두 0이었고 sync가 한 번도 호출되지 않았음을 gdb로 확인했다고 보고했다.

이 상태는 CBRD-26824 hotfix(PR #7297, 2026-06-29 `feat/oos` 병합)가 매 INSERT 첫 시도의 무조건 sync 조건 `|| try_find == 0` 을 지운 뒤부터다. hotfix 이전에도 sync는 `tmp_hdr` 에 썼으므로 비율 조건은 늘 거짓이었고, 첫 시도 조건이 sync를 실행한 유일한 경로였다(소스 추론). hotfix는 3MB 값 INSERT 지연 회귀를 고쳤지만, 그 결과 재시작 뒤 hint를 다시 채우는 경로도 함께 멈췄다.

sync가 실행되더라도 충분하지 않다. sync는 매번 파일 앞쪽 20%(최소 10, 최대 100페이지)만 처음부터 읽고(`oos_file.cpp:869-877`, `892`), 이어 읽을 위치 `full_search_vpid` 를 기록하지 않는다(`oos_file.cpp:960-961`). `num_other_high_best` 도 `best[]` 에서 밀려난 페이지만 센다(`oos_file.cpp:1058`). 여유 공간이 비슷한 페이지가 많으면 밀려남이 없어 이 값은 0에 머문다(소스 추론).

재시작 전에는 문제가 드러나지 않는다. 삭제 경로의 `oos_stats_update` 가 여유 공간이 늘어난 페이지를 전역 해시에 등록하기 때문이다(`oos_file.cpp:1066-1117`). 재시작이 해시를 비우면, 그 페이지에 다시 삭제가 일어나기 전까지 되살릴 경로가 없다(소스 추론). 재시작 뒤 첫 성장 때 CBRD-26786의 회수 sweep이 데이터 페이지를 순회하지만, 완전히 빈 페이지만 회수하고 부분 여유 페이지의 여유 공간은 기록하지 않는다(`oos_file.cpp:1583-1602`).

리뷰어가 보고한 재현 결과(release 빌드)는 다음과 같다. 7KB 값 400행을 넣고 홀수 행을 삭제한 뒤 vacuum해 절반쯤 빈 OOS 페이지 201개를 만들고, 같은 크기 값 100행을 넣었다.

| 조건 | OOS 페이지 | 쓰지 않는 공간 |
|------|-----------|----------------|
| 재시작 없음 | 201 → 201 | 기재 없음 |
| 재시작 뒤 | 201 → 246 | 1.17MB → 1.91MB |
| 리뷰어 수정 빌드(회수 sweep이 부분 여유 페이지를 hint로 등록), 재시작 뒤 | 201 → 202 | 1.19MB |

리뷰어는 수정 빌드의 1.19MB가 재시작하지 않은 경우와 같은 수준이라고 적었다. 측정한 build revision은 원댓글에 없다. 이 이슈를 작성하며 재현이나 측정은 하지 않았다. 원 보고는 https://github.com/CUBRID/cubrid/pull/7990#discussion_r4409283403 이다.

#### heap bestspace는 다시 바뀌고 있다

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

재사용 대상은 class 전체가 아니라 탐색·동시성 정책이다. 저장소별 지식을 adapter 뒤로 옮기지 않고 `if (heap) ... else if (oos) ...` 를 공통 구현에 퍼뜨리면 interface가 구현만큼 복잡한 얕은 모듈이 된다. 반대로 OOS용으로 class를 복사하면 이번 변경 뒤에도 두 구현이 다시 갈라진다. 따라서 공통 모듈은 free-space hint의 탐색과 경쟁 조정만 소유하고, 실제 페이지 작업은 두 adapter가 맡아야 한다.

heap도 재시작 뒤 빈 공간을 잊는 문제를 겪었다. CBRD-27325는 CBRD-26176 이후 bulk insert/delete로 비운 heap 페이지가 재사용되지 않아 heap 파일이 계속 커지는 회귀다. CBRD-27761(Develop, target guava, draft PR #8251)은 그 원인을 bestspace가 heap 크기와 무관하게 정해진 수의 페이지만 기억하고, 밀려난 공간을 다시 찾을 수단이 없다는 데서 찾는다. 그래서 shard 탐색은 유지하되, candidate queue, 헤더·메타 페이지 snapshot, 30초 주기 동기화를 제거하고 모든 데이터 페이지의 여유 등급을 담는 전 페이지 맵으로 바꾸려 한다. 이 이슈의 2026-09 합의 방안은 CBRD-26176의 candidate queue와 30초 snapshot을 기준으로 삼았다. 그대로 구현하면 OOS에 같은 결함을 다시 만들 수 있다(추론). 리뷰어가 말한 "bestspace redesign"이 CBRD-27761인지는 확인하지 않았다.

#### 선행 이슈와 페이지 소유권

CBRD-26786은 OOS 파일을 non-numerable로 바꾸고 빈 OOS 페이지를 vacuum 커밋 뒤 `file_dealloc` 로 반환한다. 이 구현은 PR #7990 head에 들어 있다. 이 페이지 생애 주기가 있어야 OOS adapter가 deallocated page를 정상 stale hint로 처리하고, sector bitmap에서 data page만 열거하며, metadata page를 회수 대상에서 제외할 수 있다.

page type만 확인해서는 persistent hint를 안전하게 재사용할 수 없다. 예를 들어 OOS file A의 snapshot이 data page VPID를 보관한 뒤 CBRD-26786이 그 page를 deallocate하면, file manager는 같은 VPID를 OOS file B에 다시 줄 수 있다. restart 후 A의 stale hint가 `PAGE_OOS` 만 검사하면 B의 page도 정상 후보처럼 보인다.

2026-09 합의는 CBRD-26950이 모든 OOS data page의 slot 0에 `OOS_PAGE_HEADER` 와 generation counter를 둔다는 설계를 전제로, 그 header에 `owner_vfid` 를 함께 기록하려 했다. 그러면 candidate fix만으로 현재 file 소유권까지 검증할 수 있고, heap bestspace가 page 안의 class OID로 소유권을 확인하는 규칙과도 대응한다. 그러나 CBRD-26950은 2026-09-04 설계를 page LSA identity stamp로 바꿨다. 청크 헤더와 heap stub에 stamp를 기록할 뿐 slot 0 header 레코드는 만들지 않는다. PR #7990 head에도 `OOS_PAGE_HEADER` 는 없다. 소유권 검증은 여전히 필요하지만 `owner_vfid` 를 둘 위치는 ANALYSIS에서 다시 정해야 한다.

### 왜 문제인가

OOS를 쓰는 테이블에서 큰 값을 삭제하고 다시 넣는 응용은, 삭제로 비운 공간을 새 값이 채워 OOS 파일 크기가 일정하게 유지되기를 기대한다. 재시작 전에는 그렇다. 정상 재시작, 장애 뒤 재시작, 유지보수 재시작 뒤에는 부분적으로 빈 페이지를 두고 새 페이지를 할당하므로, 같은 데이터 양에도 OOS 파일과 디스크 사용량이 커진다. 리뷰어 측정에서는 100행 입력에 페이지가 45개 늘었다. 잊힌 공간은 그 페이지에 다시 삭제가 일어나거나 페이지가 완전히 비어 회수될 때까지 쓰이지 않는다. 재시작마다 그 시점의 부분 여유 공간을 잊으므로, 재시작이 잦고 삭제·삽입이 반복되는 부하에서는 증가가 쌓일 수 있다(추론, 측정 안 함).

개발과 유지보수 측면에서는 같은 종류의 결함을 두 번 고치게 된다. heap은 CBRD-27325로 대량 삭제·재시작 뒤 빈 공간 미재사용을 겪었고, R4는 OOS에서 같은 형태로 나타났다. heap과 OOS가 서로 다른 bestspace를 유지하는 동안에는 heap 쪽 수정이 OOS로 넘어오지 않는다.

테스트도 이 결함을 잡지 못했다. sync 테스트는 `bridge_oos_stats_sync_bestspace` 를 실제 헤더와 `scan_all=true` 로 직접 부른다(`unit_tests/oos/test_oos_bestspace.cpp:1099`). 재시작을 모사하는 `simulate_hint_loss` 는 sync가 hint를 다시 채운다는 전제로 `num_other_high_best` 를 0으로 만든다(`unit_tests/oos/test_oos_growth_sweep.cpp:58-59`). 운영 경로의 발동 조건을 거치는 재시작 재사용 테스트는 없다.

동시성 측면에서는 청크마다 헤더 WRITE latch와 전역 mutex를 거치므로, 여러 트랜잭션이 같은 OOS 파일에 값을 넣으면 페이지 선택이 직렬화된다. 이 위험은 코드 구조에서 도출했고 측정하지 않았다.

### 왜 해결해야 하는가

OOS가 legacy bestspace로 develop에 병합되면, 이 이슈가 끝날 때까지 재시작마다 부분 여유 공간을 잊는 상태가 유지된다. OOS 설계 명세 §2(Best Page Policy)는 재시작 뒤 sync로 빈 공간을 재발견한다고 적었지만, PR #7990 head에서는 성립하지 않는다.

legacy 경로를 따로 고치는 방법은 다음 이유로 이 이슈를 대신하지 못한다. 리뷰어가 검증한 방법은 회수 sweep이 부분 여유 페이지를 hint로 등록하는 것이다. 이 방법은 CBRD-27872가 다루는 성장 게이트 sweep의 발동 조건과 순회량에 그대로 기댄다. 또한 등록할 전역 해시는 모든 OOS 파일 합계 1000개에서 새 등록을 거부하므로(`oos_file.cpp:373-377`), 그보다 많은 부분 여유 페이지는 다시 잊힌다(소스 추론). sync 발동 조건을 살리는 방법은 `num_pages`·`num_other_high_best` 집계와 이어 읽기를 새로 만들어야 하고, CBRD-26824 같은 INSERT 지연 회귀 위험이 있다. 어느 쪽이든 이 이슈가 해시·`best[]`·sync를 삭제할 때 함께 사라진다.

그래서 R4를 이 이슈의 완료 조건으로 편입한다. 근거는 두 가지다. 리뷰어가 "bestspace redesign 안정화 후 oos에 적용"을 처리 방향으로 밝혔다. 그리고 이 이슈의 재설계가 legacy 해시·`best[]`·sync를 삭제하므로, legacy 수정은 재설계 때 버려진다. 이 이슈를 heap 재설계 결론에 맞추면 OOS도 재시작 뒤 재발견을 구조로 보장하고, 두 저장소의 동시성·stale hint·회수 정책 수정을 한 곳에서 할 수 있다.

착수 시점은 CBRD-27761의 안정화에 달려 있다. CBRD-27761은 Develop 상태이고 PR #8251은 draft다. OOS legacy 경로가 이 결함을 가진 채 guava 릴리스에 포함되어도 되는지는 아직 정하지 않았다. 팀이 이를 허용하지 않으면 legacy 결함 수정을 별도 Sub-task로 분리해야 한다(Remarks 참고).

## Triage Request

이 이슈의 범위에 PR #7990 R4(재시작 뒤 부분 여유 OOS 페이지 미재사용)를 포함하는 것을 확인하고, 작성자 측에 ANALYSIS 배정을 요청한다. ANALYSIS에서 확인할 사항은 다음과 같다.

1. 공통 모듈의 기준 구조를 CBRD-27761 결론에 맞춰 다시 정한다. candidate queue, 30초 snapshot, sector bitmap 점진 rebuild 가운데 무엇을 유지하고 무엇을 전 페이지 맵으로 바꿀지 정한다. 리뷰어가 말한 "bestspace redesign"이 CBRD-27761인지 리뷰어에게 확인한다.
2. CBRD-26950의 page LSA identity stamp 설계에서 OOS data page의 소유 file(`owner_vfid`)을 어디에 기록하고 어떻게 검증할지 정한다.
3. 재발견 순회가 INSERT 한 건에 더하는 순회량의 상한을 정한다. 성장 게이트 sweep과 같은 섹터 비트맵을 함께 도는 부분은 CBRD-27872의 sweep 계약에 맞춘다.
4. 리뷰어 수치를 PR #7990 head release 빌드에서 재현한다. 400행 입력, 홀수 행 삭제, vacuum, 정상 재시작, 100행 입력 전후의 OOS 데이터 페이지 수와 sync 분기 진입 횟수를 비교한다. 같은 시나리오를 서버 강제 종료 뒤 재시작으로도 확인한다.
5. 부분 여유 페이지가 1000개를 넘는 파일과 OOS 파일이 여러 개인 DB에서 재시작 전후 공간 증가 폭을 확인한다.

## Specification Changes

사용자 가시 SQL과 manual 변경은 N/A다. 변경 대상은 `src/storage/bestspace.{hpp,cpp}` 의 interface와 registry, `src/storage/oos_file.{hpp,cpp}` 의 페이지 선택·헤더 format·복구, page type/recovery index 정의, heap/OOS unit test와 SQL/medium 회귀다. SQL 문법과 사용자 가시 저장 규칙은 바뀌지 않는다.

내부 저장·복구 규칙은 아래와 같이 변경한다. 표는 2026-09 합의 방안 기준이다. candidate queue와 30초 snapshot을 전제한 행(공통 bestspace, OOS metadata page type, OOS header, Snapshot, Restart)은 CBRD-27761 결론에 맞춰 재검토 대상이다.

| 항목 | 변경 스펙 |
|------|-----------|
| 공통 bestspace | L1/L2/L3 shard, candidate queue, tier 탐색, shard allocation ownership을 heap/OOS가 공유한다. hint는 비권위 정보이며 실제 page fix와 free-space 실측이 최종 판단이다. |
| Registry | 공통 key는 `VFID` 다. heap adapter는 `HFID` 와 class OID를, OOS adapter는 OOS VFID와 owner 정보를 자기 context에 보관한다. |
| OOS data page identity | OOS data page마다 `owner_vfid` 를 기록하고, `PAGE_OOS` 와 `owner_vfid` 가 모두 일치해야 해당 OOS file의 candidate로 인정한다. 합의 당시의 기록 위치인 CBRD-26950 slot 0 `OOS_PAGE_HEADER` 는 존재하지 않으므로 기록 위치는 재검토 대상이다. |
| OOS metadata page type | bestspace snapshot 페이지는 `PAGE_OOS_BESTSPACE` 로 표시한다. `PAGE_OOS_BESTSPACE` 와 sticky OOS header page는 청크 저장·OOS data 통계·vacuum reclaim·sector-bitmap data-page 순회에서 제외한다. |
| OOS header | metadata page 개수와 VPID 목록, snapshot format/version, 점진 rebuild 진행 상태를 식별할 정보를 보관한다. 기존 `best[10]`, `second_best[10]`, sync-scan 추정 필드는 제거한다. OOS 통계 필드는 bestspace와 분리해 유지한다. |
| Snapshot | metadata page 생성은 정상 WAL로 보호한다. 이후 hint snapshot 갱신은 OOS 전용 redo-only recovery index를 사용하며 undo는 두지 않는다. hint가 마지막 갱신보다 오래돼도 데이터 정합성에는 영향을 주지 않는다. |
| Restart | snapshot을 즉시 registry에 적재한 뒤, non-numerable `FILE_OOS` 의 sector bitmap을 한 번 점진적으로 순회한다. 한 OOS 파일에서 동시에 하나의 rebuild만 진행하며, cursor를 청크마다 처음으로 되돌리지 않는다. 어느 구조를 고르든 정상 재시작과 비정상 종료 뒤 부분 여유 페이지를 다시 찾는 것이 요구 결과다(PR #7990 R4). |
| Hint failure | stale/missing/format-invalid snapshot은 경고를 남기고 버린 뒤 rebuild한다. page I/O, WAL, allocation 실패는 hint 문제로 숨기지 않고 기존 CUBRID error model로 반환한다. |
| Page allocation | 후보가 부족하면 OOS adapter가 한 번에 최대 `bestspace::ALLOC_BATCH_SIZE`(4)개 data page를 할당하고, caller가 사용할 한 페이지의 WRITE latch를 연속해서 인계한다. |
| Space accounting | OOS는 heap unfill을 적용하지 않는다. `spage_max_space_for_new_record` 가 새 slot 비용을 이미 반영하므로 필요한 크기는 OOS record 길이 그대로 비교한다(CBRD-26954). |
| Configuration | `bestspace_shard_count`(기본 8, 범위 1~28), `bestspace_distributed_insert`, `bestspace_cache_count`(기본 40, 범위 10~128)를 그대로 공유한다. OOS 전용 parameter는 추가하지 않는다. |
| Compatibility | heap bestspace의 기존 on-disk layout과 동작을 유지한다. OOS는 미출시이므로 OOS header와 file layout은 이전 실험 DB와 호환하지 않아도 된다. |

## Implementation

TBD - ANALYSIS 단계에서 결정한다. 아래는 2026-09 합의 방안 기준의 설계 메모이며 재확정 전까지 참고안이다. candidate queue, snapshot, `owner_vfid` 기록 위치를 전제한 부분은 재검토 대상이다.

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
  -> page의 owner 정보 읽기 (기록 위치는 ANALYSIS에서 정한다)
  -> owner_vfid == requested OOS VFID 확인
  -> spage_max_space_for_new_record 실측
  -> record length가 들어가면 latch를 caller에 인계
```

page type 또는 `owner_vfid` 가 맞지 않으면 해당 L1/candidate entry를 제거하고 다른 후보를 찾는다. 이는 hint miss이며 오류가 아니다. owner 정보 자체를 읽을 수 없거나 format이 맞지 않으면 snapshot-invalid 복구 규칙과 실제 page corruption 규칙을 구분해 처리한다.

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

candidate queue나 snapshot을 이름으로 쓴 항목은 ANALYSIS가 기준 구조를 바꾸면 같은 결과를 요구하는 문장으로 고친다.

### Shared module and heap

- [ ] L1/L2/L3 shard, candidate queue, tier search, allocation ownership 구현은 heap과 OOS가 같은 module을 사용한다.
- [ ] 공통 module의 registry lookup key는 `VFID` 이며 heap/OOS 세부 context는 adapter가 소유한다.
- [ ] heap adapter는 CBRD-26176의 page validation, unfill, statistics, ordered-fix, batch allocation 동작을 보존한다.
- [ ] heap header와 persistent bestspace page의 on-disk layout이 변경되지 않는다.
- [ ] 기존 bestspace unit/regression test가 변경 전과 같은 결과를 낸다.

### OOS behavior

- [ ] OOS data page의 소유 file을 candidate fix만으로 검증할 수 있게 `owner_vfid` 를 기록한다. 기록 위치는 CBRD-26950의 page LSA identity stamp 설계와 맞춰 ANALYSIS에서 정한다.
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

### Restart reuse (PR #7990 R4)

- [ ] 부분 여유 OOS 페이지가 있는 파일에서 서버를 정상 재시작한 뒤 같은 크기 값을 넣으면, 재시작하지 않은 대조군과 같은 수준으로 기존 페이지를 재사용한다. PR #7990 R4의 재현 시나리오를 포함하며, 허용 차이는 ANALYSIS에서 정한다.
- [ ] 부분 여유 페이지 수가 메모리 hint 용량보다 많은 파일과, OOS 파일이 여러 개인 DB에서도 위 결과가 성립한다.
- [ ] 비정상 종료 뒤 재시작해도 부분 여유 페이지의 재사용이 회복된다. 회복까지 허용하는 지연은 ANALYSIS에서 정한다.
- [ ] 이 이슈의 재발견 순회가 INSERT 한 건에 더하는 순회량의 상한을 정한다. 성장 게이트 sweep과의 중복 순회 처리는 CBRD-27872의 sweep 계약에 맞춘다.
- [ ] 재시작 재사용 테스트는 운영 경로의 발동 조건을 거친다. 내부 함수를 직접 호출하는 테스트만으로 대신하지 않는다.

### Compatibility and cleanup

- [ ] 기존 OOS global hash/mutex, `best[10]`/`second_best[10]`, sync scan, lifecycle hook, 내부 bridge test를 제거한다.
- [ ] 기존 heap DB는 disk compatibility를 유지한다. 이전 OOS 실험 DB는 재생성이 필요함을 PR과 QA notes에 명시한다.
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
- [ ] PR #7990 R4 시나리오의 재시작 전후 OOS 데이터 페이지 수를 변경 전 build와 비교해 보고한다.
- [ ] OOS 실험 DB 재생성 필요성을 PR/QA notes에 기록한다.
- [ ] 사용자 manual 변경은 N/A다.

## References

- 기준 source: CUBRID `dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67`(PR #7990 head). 이전 판의 기준은 `725a32c` 였다.
- PR #7990 R4 원댓글: https://github.com/CUBRID/cubrid/pull/7990#discussion_r4409283403
- 현재 OOS legacy cache: `src/storage/oos_file.cpp:130-162,265-538,559-1117,3017-3163`
- 현재 OOS header format: `src/storage/oos_file.hpp:126-156`, `src/storage/oos_file.cpp:1123-1224`
- 재시작 뒤 sync 미실행 근거: `src/storage/oos_file.cpp:985,1001`(`num_pages` 쓰기), `3080-3086`(비율 조건), `3103-3105`(`tmp_hdr` 호출), `869-877,892,960-961`(sync 범위와 이어 읽기 부재), `373-377`(해시 용량), `1583-1602`(회수 sweep의 비어 있음 판정)
- 관련 test: `unit_tests/oos/test_oos_growth_sweep.cpp:58-90`, `unit_tests/oos/test_oos_bestspace.cpp:1099`
- 현재 heap bestspace: `src/storage/bestspace.hpp:71-538`, `src/storage/bestspace.cpp:635-722,926-1066,1432-1523,1648-1697,1746-1810`
- 기존 parameter: `src/base/system_parameter.c:5512-5547`
- CBRD-26824 hotfix PR #7297(`feat/oos` merge `03133632`): https://github.com/CUBRID/cubrid/pull/7297
- CBRD-27761 draft PR #8251: https://github.com/CUBRID/cubrid/pull/8251
- CBRD-26176: <http://jira.cubrid.org/browse/CBRD-26176>
- CBRD-26950: <http://jira.cubrid.org/browse/CBRD-26950>
- CBRD-26786: <http://jira.cubrid.org/browse/CBRD-26786>
- CBRD-26831: <http://jira.cubrid.org/browse/CBRD-26831>
- CBRD-26824: <http://jira.cubrid.org/browse/CBRD-26824>
- CBRD-26954: <http://jira.cubrid.org/browse/CBRD-26954>
- CBRD-27761: <http://jira.cubrid.org/browse/CBRD-27761>
- CBRD-27325: <http://jira.cubrid.org/browse/CBRD-27325>
- CBRD-27872: <http://jira.cubrid.org/browse/CBRD-27872>

## Remarks

- 이 이슈는 live JIRA의 `Sub-task` 를 유지하되, 변경 성격은 기존 기능·성능 개선이다. 문제 범주는 동시성 성능과 공간 효율이다.
- 선행 순서는 CBRD-26950 -> CBRD-26786 -> CBRD-27213이다. 두 선행 이슈는 완료됐고 PR #7990 head에 들어 있다. CBRD-26950은 slot 0 `OOS_PAGE_HEADER` 대신 page LSA identity stamp를 채택했으므로, `owner_vfid` 를 전제한 설계는 다시 확인한다.
- PR #7990 R4는 새 이슈 없이 이 이슈로 추적한다. R4 원댓글 thread는 이 이슈의 재설계가 반영될 때 해결한다.
- 성장 게이트 sweep(CBRD-26786)의 발동 조건과 할당당 상한은 CBRD-27872(PR #7990 R3)가 맡는다. 이 이슈는 자신이 도입하는 재발견 순회의 비용만 맡는다.
- 이 이슈가 끝나기 전에 develop에 병합되는 OOS legacy 경로는 재시작 뒤 부분 여유 페이지를 재사용하지 못한다. 병합 PR 설명 또는 QA 노트에 알려진 제약으로 기록한다.
- 팀이 OOS develop 병합이나 guava 릴리스에서 이 제약을 허용하지 않기로 정하면, legacy 결함 수정을 별도 Sub-task로 분리한다. 이 이슈가 Sub-task이므로 그 밑이 아니라 CBRD-26583 밑에 만든다.
