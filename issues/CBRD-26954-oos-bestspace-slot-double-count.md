# [OOS] bestspace 여유공간 비교가 슬롯을 이중 계산해 freed 페이지가 재사용되지 않는다

## Issue Triage

**이슈 수행 목적**: `oos_find_best_page` 의 여유공간 비교에서 슬롯 크기를 이중으로 더하는 오류를 없앤다. 그래서 delete/reinsert 가 반복돼도 비워진 `OOS` (Out-of-row Storage - heap 의 큰 가변 컬럼을 별도 페이지로 분리 저장하는 방식) 페이지가 정상 재사용되고 OOS 파일이 불필요하게 커지지 않게 한다.

**이슈 수행 이유**:

- **현재 동작 / 배경**: `oos_find_best_page` (`src/storage/oos_file.cpp:1489`) 는 필요 공간을 `total_space = rec_length + (int) sizeof (SPAGE_SLOT)` 로 만든 뒤, 이 값을 `needed_space` 로 삼아 세 군데에서 페이지 적합성을 판정한다 - best[] 배열 스캔과 전역 캐시 조회(`oos_stats_find_page_in_bestspace`, `oos_file.cpp:454`, 비교 지점 `:497` / `:531` / `:574`), 그리고 메인 루프의 재고정 후 재확인(`oos_file.cpp:1596`, `actual_free >= total_space`). 그런데 비교 대상인 freespace 값은 모두 `spage_max_space_for_new_record` (`src/storage/slotted_page.c:977` - 이 페이지에 새 레코드로 들어갈 수 있는 최대 바이트를 돌려주는 함수) 의 반환값이고, 이 함수는 새 슬롯을 만들어야 할 때 이미 슬롯 1개분을 차감해서 돌려준다(`slotted_page.c:999`, `total_free -= SSIZEOF (SPAGE_SLOT)`). `SPAGE_SLOT` (슬롯 디렉터리 1칸) 은 4바이트다(`slotted_page.h:88`, 비트필드 14+14+4 = 32비트). 즉 호출자가 `sizeof (SPAGE_SLOT)` 를 다시 더하면 슬롯이 두 번 빠진다. heap 의 정설 컨벤션은 슬롯을 더하지 않고 원본 레코드 길이와 직접 비교한다(`heap_file.c:21803`, `spage_max_space_for_new_record (page) < recdes->length`).
- **영향**: 기술 부채가 아니라 실측되는 공간 누수다. 단일 청크가 페이지 최대치(`rec_length`)에 가까울 때, 방금 비워진 OOS 페이지의 실제 여유공간은 `rec_length` 인데 비교가 `rec_length >= rec_length + 4` 로 실패해 그 페이지가 탈락한다. 그러면 `oos_file_alloc_new` 가 멀쩡한 freed 페이지를 두고 새 페이지를 할당한다. multi-chunk OOS 행을 delete 후 reinsert 할 때마다 반복돼, 64KB 행을 5회 delete/reinsert 하면 OOS 파일이 6 -> 26 페이지로 늘어난다(남는 행은 1개). 회수(reclaim) 자체는 정상이고 누수는 전적으로 reinsert 측 할당기 판정의 문제다.

**이슈 수행 방안**:

- `oos_find_best_page` 의 슬롯 가산을 제거한다: `int total_space = rec_length;`. `spage_max_space_for_new_record` 가 이미 슬롯을 차감하므로 heap 과 동일한 계약이 된다.
- 세 비교 지점(best[] 스캔, 전역 캐시 조회, 재고정 후 `actual_free` 재확인)과 sync-scan 경로가 모두 `needed_space` 를 원본 레코드 길이로 일관되게 다루는지 확인한다.
- delete/reinsert 반복 후 OOS 페이지 수가 증가하지 않음을 단언하는 회귀 테스트를 추가한다. PR #6986 에 `DISABLED_` 로 들어가 있는 `OosEagerCleanup.MultiChunkDeleteCleansAllChunks` 의 `DISABLED_` 를 떼는 것으로 갈음할 수 있다.

---

## AI-Generated Context

> 아래 내용은 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **문제 / 목적**: freed OOS 페이지가 재사용되지 않아 delete/reinsert churn 에서 OOS 파일이 단조 증가한다.
- **원인 / 배경**: `oos_find_best_page` 가 `spage_max_space_for_new_record` 와 비교할 값에 슬롯 크기를 이중으로 더한다.
- **제안 / 변경**: 슬롯 가산 한 줄(`+ (int) sizeof (SPAGE_SLOT)`) 제거. on-disk 포맷 변경 없음.
- **영향 범위**: `src/storage/oos_file.cpp` 의 페이지 할당 경로. 모든 OOS insert/reinsert 의 페이지 선택에 영향. 하위 호환.

---

## Description

PR #6986 (CBRD-26668, vacuum 의 OOS 정리 연동) 의 SA_MODE (standalone 모드 - 서버 없이 클라이언트와 서버를 한 프로세스로 실행) DELETE 회수 테스트를 추가하던 중 발견된 사전 결함이다. `oos_file.cpp` 의 할당 경로는 부모 브랜치 `feat/oos` 소속이라 #6986 범위 밖이므로 별도 PR 로 분리한다.

핵심은 `oos_find_best_page` 의 여유공간 기준값 한 줄이다.

```c
/* oos_file.cpp:1489 (현재) */
int total_space = rec_length + (int) sizeof (SPAGE_SLOT);
/* 이 total_space 가 needed_space 로 흘러 들어가 아래 세 곳에서 비교된다:
 *   - oos_stats_find_page_in_bestspace 의 best[] / 캐시 조회 (oos_file.cpp:497, 531)
 *   - 같은 함수의 재고정 후 actual_free 재확인          (oos_file.cpp:574)
 *   - oos_find_best_page 메인 루프의 재고정 후 재확인     (oos_file.cpp:1596)
 * 비교 대상 freespace 는 모두 spage_max_space_for_new_record() 반환값. */
```

`spage_max_space_for_new_record` 는 반환 직전에 이미 슬롯 1개분을 뺀 "이 페이지에 새 레코드로 들어갈 수 있는 최대 바이트" 를 돌려준다.

```c
/* slotted_page.c:999 - 재사용 가능한 빈 슬롯이 없어 새 슬롯을 카브해야 하는 경우 */
total_free -= SSIZEOF (SPAGE_SLOT);
```

따라서 호출자가 `sizeof (SPAGE_SLOT)` 를 한 번 더 더하면 슬롯 4바이트가 이중으로 요구된다. 딱 한 슬롯 차이로 freed 페이지가 탈락하고, 새 페이지가 할당된다. heap 은 같은 함수를 쓰면서 슬롯을 더하지 않으므로(`heap_file.c:21803`), 정설 계약은 "원본 레코드 길이와 직접 비교" 다.

## Test Build

`feat/oos` 최신(PR #6986 머지 이후), debug 빌드. OS: Linux x86_64.

## Repro

SA_MODE 유닛테스트로 재현한다. (로컬 전용 래퍼는 쓰지 않는다 - 아래는 이식 가능한 명령.)

```bash
# UNIT_TESTS 활성으로 빌드
cmake --preset debug -DUNIT_TESTS=ON
cmake --build build_preset_debug

# PR #6986 의 DISABLED_ 테스트가 정확히 이 누수를 잡는다.
# unit_tests/oos/sql/test_oos_sql_eager_cleanup.cpp 의
#   OosEagerCleanup.DISABLED_MultiChunkDeleteCleansAllChunks
# 에서 DISABLED_ 접두어를 떼고 실행한다.
ctest --test-dir build_preset_debug -R test_oos_sql_eager_cleanup --output-on-failure
```

테스트 시나리오: `CREATE TABLE t (id INT PRIMARY KEY, big_col BIT VARYING)` 후 64KB 행을 INSERT 하고, DELETE + 새 64KB 행 INSERT 를 5회 반복한 다음 OOS 페이지 수를 확인한다.

## Expected Result

남는 행이 1개뿐이므로 OOS 페이지 수가 첫 INSERT 직후 수준(약 6)에서 유지된다. 단언: `pages_after_churn <= pages_after_insert + 2`.

## Actual Result

OOS 페이지 수가 6 -> 26 으로 증가한다(사이클당 약 +4). freed 페이지가 재사용되지 않고 매 reinsert 가 새 페이지를 할당한다.

## Additional Information

- 정설 비교(슬롯 미가산): `heap_file.c:21803` (`< recdes->length`). heap 의 bestspace freespace 적재도 슬롯 가산 없이 `spage_max_space_for_new_record` 원본을 저장한다(`heap_file.c:3447`).
- `spage_max_space_for_new_record`: `slotted_page.c:977`, 슬롯 차감 분기 `:999`. `SPAGE_SLOT` 크기 4바이트: `slotted_page.h:88` (비트필드 `offset_to_record:14` + `record_length:14` + `record_type:4`).
- 회수(reclaim) 정상 근거: `oos_delete_chain` (`oos_file.cpp:1695` 부근) 이 청크 체인을 끝까지 돌며 슬롯을 free 하고 freed 페이지를 bestspace 에 되돌린다. DELETE 단독 시 페이지 증가 0, 행수 0 확인.

## Remarks

- 본 수정 머지 후 PR #6986 의 `OosEagerCleanup.DISABLED_MultiChunkDeleteCleansAllChunks` 에서 `DISABLED_` 를 제거해 회귀 가드로 상시화한다.
- 관련: CBRD-26658 (3-tier bestspace - `oos_find_best_page` 를 도입한 이슈), CBRD-26786 (빈 OOS 페이지 회수), CBRD-26668 / PR #6986 (vacuum-OOS 연동, 본 결함의 발견 맥락).
