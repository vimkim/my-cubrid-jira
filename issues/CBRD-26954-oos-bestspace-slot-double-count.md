# [OOS] 페이지 재사용 판정이 슬롯 크기를 두 번 빼서 비워진 OOS 페이지를 다시 쓰지 못한다

## Issue Triage

**이슈 수행 목적**: delete 후 reinsert 가 반복돼도 비워진 `OOS` (Out-of-row Storage - heap 의 큰 가변 컬럼을 별도 페이지로 분리 저장하는 방식) 페이지가 정상적으로 재사용되도록 고친다. 그래서 행 수가 그대로인데 OOS 파일만 계속 커지는 현상을 없앤다.

**이슈 수행 이유**:

- **현재 동작 / 배경**: OOS 행을 새로 넣을 때 할당기 `oos_find_best_page` 는 "이 페이지에 레코드가 들어갈 만큼 공간이 있나" 를 따진다. 그런데 필요 공간을 `rec_length + sizeof (SPAGE_SLOT)` (레코드 길이 + 슬롯 1칸 4바이트) 로 잡는다. 비교 대상인 `spage_max_space_for_new_record` (slotted page 에 새 레코드가 들어갈 수 있는 최대 바이트를 돌려주는 함수) 는 **이미 슬롯 1칸을 빼고** 돌려주므로, 슬롯 4바이트가 두 번 차감된다. heap 은 같은 함수를 쓰면서 슬롯을 더하지 않고 레코드 길이와 직접 비교한다 (`heap_file.c`, `spage_max_space_for_new_record (...) < recdes->length`).
- **영향**: 실측되는 공간 누수다. 레코드가 페이지를 거의 꽉 채울 때, 방금 비워진 페이지의 실제 여유공간은 딱 `rec_length` 인데 비교가 `rec_length >= rec_length + 4` 로 4바이트 차이로 실패한다. 그러면 멀쩡한 빈 페이지를 두고 새 페이지를 할당한다. 64KB 행을 delete/reinsert 5회 반복하면 행은 1개뿐인데 OOS 파일이 6 -> 26 페이지로 늘어난다.

**이슈 수행 방안**:

- `oos_find_best_page` 에서 슬롯 가산 한 줄을 지운다: `int total_space = rec_length + (int) sizeof (SPAGE_SLOT);` -> `int total_space = rec_length;`. 이러면 heap 과 동일한 계약이 된다. on-disk 포맷 변경 없음.
- 이 값(`needed_space`)을 쓰는 세 비교 지점(best[] 스캔, 전역 캐시 조회, 재고정 후 `actual_free` 재확인)이 모두 일관되게 원본 레코드 길이로 비교하는지 확인한다.
- 회귀 테스트로 고정한다. PR #6986 에 `DISABLED_` 상태로 들어가 있는 `OosEagerCleanup.MultiChunkDeleteCleansAllChunks` 가 정확히 이 누수를 잡으므로, 수정 후 `DISABLED_` 접두어만 떼면 된다.

---

## AI-Generated Context

> 아래 내용은 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **문제 / 목적**: 비워진 OOS 페이지가 재사용되지 않아, 같은 행을 delete/reinsert 반복하면 OOS 파일이 계속 커진다.
- **원인 / 배경**: `oos_find_best_page` 가 필요 공간에 슬롯 크기(4바이트)를 더하는데, 비교 함수가 이미 슬롯을 빼고 돌려주므로 슬롯이 이중 차감된다.
- **제안 / 변경**: 슬롯 가산 한 줄 제거. 코드 한 줄 수정이며 디스크 포맷/호환성 영향 없음.
- **영향 범위**: `src/storage/oos_file.cpp` 의 페이지 선택 경로. 모든 OOS insert/reinsert 의 페이지 할당에 영향. 하위 호환.

---

## Description

### 배경 - 알아야 할 용어 4개

이 버그를 이해하려면 OOS 가 디스크에 공간을 잡는 방식만 알면 된다.

- **slotted page**: OOS 페이지 한 장은 "슬롯 디렉터리 + 레코드 데이터" 구조다. 레코드 1개를 새로 넣으려면 데이터가 들어갈 공간뿐 아니라 **슬롯 디렉터리에 1칸(`SPAGE_SLOT`, 4바이트)** 도 함께 필요하다.
- **`spage_max_space_for_new_record`**: "이 페이지에 새 레코드의 *데이터* 가 최대 몇 바이트까지 들어가나" 를 돌려주는 함수. 새 슬롯 1칸이 필요한 경우 그 4바이트를 **미리 빼고** 돌려준다 (`slotted_page.c`, `total_free -= SSIZEOF (SPAGE_SLOT)`). 즉 반환값은 "슬롯 값을 이미 치른 뒤 데이터에 쓸 수 있는 예산" 이다.
- **bestspace**: 여유공간이 있는 페이지를 캐싱해 두는 자료구조. 새 행을 넣을 때 새 페이지를 만들기 전에 여기서 재사용할 페이지를 먼저 찾는다.
- **freed page 재사용**: OOS 행을 delete 하면 그 페이지들의 슬롯이 free 되고 페이지가 bestspace 로 돌아온다. 다음 insert 는 이 빈 페이지를 재사용해야 OOS 파일이 커지지 않는다.

### 무엇이 잘못됐나

핵심은 `oos_find_best_page` 의 필요 공간 계산 한 줄이다.

```c
/* oos_file.cpp, oos_find_best_page() - 현재 (버그) */
int total_space = rec_length + (int) sizeof (SPAGE_SLOT);
```

`total_space` 는 `needed_space` 로 흘러가 "이 페이지가 적합한가" 를 판정하는 모든 곳에서 `spage_max_space_for_new_record` 반환값과 비교된다. 그런데 비교 양쪽이 슬롯을 **둘 다** 치른다.

| | 슬롯(4바이트) 처리 | |
|---|---|---|
| 필요 공간 (`total_space`) | `rec_length + 4` | 슬롯을 더함 |
| 가용 공간 (`spage_max_space_for_new_record`) | `빈공간 - 4` | 슬롯을 이미 뺌 |

올바른 비교는 "데이터 예산 >= 데이터 길이", 즉 `spage_max_space_for_new_record(page) >= rec_length` 다. heap 이 정확히 이렇게 한다. 하지만 OOS 는 오른쪽에 `+ 4` 를 붙여 슬롯을 두 번 요구한다.

### 왜 freed 페이지가 탈락하나 - 구체 예시

레코드가 페이지를 거의 꽉 채우는 큰 청크라고 하자. 방금 그 레코드 1개를 delete 해 비워진 페이지는, 똑같은 크기의 레코드를 다시 받을 만큼의 여유공간을 가진다. 즉 `spage_max_space_for_new_record(page) == rec_length`.

- **올바른 판정**: `rec_length >= rec_length` -> 통과. 페이지 재사용.
- **현재 판정**: `rec_length >= rec_length + 4` -> 4바이트 차이로 실패. 페이지 탈락 -> `oos_file_alloc_new` 가 새 페이지를 할당.

회수(reclaim) 자체는 정상이다. 누수는 전적으로 reinsert 쪽 할당기 판정에서 생긴다.

## Test Build

`feat/oos` 최신 (PR #6986 머지 이후), debug 빌드. OS: Linux x86_64.

## Repro

SA_MODE (standalone 모드 - 서버 프로세스 없이 클라이언트와 서버를 한 프로세스로 실행) 유닛 테스트로 재현한다.

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

테스트 시나리오: `CREATE TABLE t (id INT PRIMARY KEY, big_col BIT VARYING)` 후 64KB 행을 INSERT 하고, "DELETE + 새 64KB 행 INSERT" 를 5회 반복한 다음 OOS 페이지 수를 센다.

## Expected Result

남는 행이 1개뿐이므로 OOS 페이지 수는 첫 INSERT 직후 수준(약 6)에서 유지된다. 단언: `pages_after_churn <= pages_after_insert + 2`.

## Actual Result

OOS 페이지 수가 6 -> 26 으로 늘어난다(사이클당 약 +4). 빈 페이지가 재사용되지 않고 매 reinsert 가 새 페이지를 할당한다.

## Additional Information

- **정설 비교(슬롯 미가산)**: heap 은 페이지 적합 판정에서 슬롯을 더하지 않고 `spage_max_space_for_new_record (...) < recdes->length` 로 비교한다(`heap_file.c`). bestspace 에 여유공간을 적재할 때도 슬롯 가산 없이 `spage_max_space_for_new_record` 원본을 저장한다.
- **`SPAGE_SLOT` 4바이트 근거**: `slotted_page.h` 의 비트필드 `offset_to_record:14` + `record_length:14` + `record_type:4` = 32비트 = 4바이트.
- **회수가 정상이라는 근거**: `oos_delete_chain` 이 청크 체인을 끝까지 돌며 슬롯을 free 하고 빈 페이지를 bestspace 로 되돌린다. DELETE 만 했을 때는 페이지 증가 0, 행수 0 으로 확인된다.

## Remarks

- 발견 맥락: PR #6986 (CBRD-26668, vacuum 의 OOS 정리 연동)의 SA_MODE DELETE 회수 테스트를 추가하다 발견한 사전 결함이다. `oos_file.cpp` 할당 경로는 부모 브랜치 `feat/oos` 소속이라 #6986 범위 밖이므로 별도 PR 로 분리한다.
- 수정 머지 후 PR #6986 의 `OosEagerCleanup.DISABLED_MultiChunkDeleteCleansAllChunks` 에서 `DISABLED_` 를 제거해 회귀 가드로 상시화한다.
- 관련 이슈: CBRD-26658 (3-tier bestspace - `oos_find_best_page` 도입), CBRD-26786 (빈 OOS 페이지 회수), CBRD-26668 / PR #6986 (vacuum-OOS 연동).
