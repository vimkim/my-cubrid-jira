# [OOS] 페이지 재사용 판정이 필요 공간을 슬롯 한 칸만큼 부풀려 비워진 OOS 페이지를 다시 쓰지 못한다

## Issue Triage

**이슈 수행 목적**: delete 후 reinsert 가 반복돼도 비워진 `OOS` (Out-of-row Storage - heap 의 큰 가변 컬럼을 별도 페이지로 분리 저장하는 방식) 페이지가 정상적으로 재사용되도록 고친다. 그래서 행 수가 그대로인데 OOS 파일만 계속 커지는 현상을 없앤다.

**이슈 수행 이유**:

- **현재 동작 / 배경**: OOS 행을 새로 넣을 때 페이지 할당기 `oos_find_best_page` 는 페이지 적합성을 `필요 공간 = rec_length + sizeof (SPAGE_SLOT)` (레코드 길이 + 슬롯 1칸 4바이트) 로 따진다. 비교 함수 `spage_max_space_for_new_record` (slotted page 에 새 레코드 데이터가 몇 바이트 들어가는지 돌려주는 함수) 는 슬롯 자리 비용을 이미 반영해서 돌려주므로, heap 은 슬롯을 더하지 않고 레코드 길이와 곧장 비교한다 (`heap_file.c`). OOS 만 슬롯 한 칸을 덧붙여, 함수가 이미 처리한 슬롯을 중복으로 요구한다.
- **영향**: 실측되는 공간 누수다. delete 로 비워진 페이지는 풀린 슬롯을 reinsert 때 그대로 재사용하므로 새 슬롯이 0바이트인데, 군더더기 4바이트 요구 탓에 같은 레코드가 딱 들어갈 페이지가 탈락한다. 그러면 멀쩡한 빈 페이지를 두고 `oos_file_alloc_new` 가 새 페이지를 만든다. 64KB 행을 delete/reinsert 5회 반복하면 남는 행은 1개인데 OOS 파일이 약 6 -> 26 페이지로 늘어난다.

**이슈 수행 방안**:

- `oos_find_best_page` 에서 슬롯 가산 한 줄을 지운다: `int total_space = rec_length + (int) sizeof (SPAGE_SLOT);` -> `int total_space = rec_length;`. 이러면 heap 과 동일한 계약이 된다. on-disk 포맷 변경 없음.
- 이 `total_space` 는 `needed_space` 로 흘러가 best[] 스캔 / 전역 캐시 조회 / 재고정 후 `actual_free` 재확인 등 모든 비교 지점에서 쓰인다. 전부 한 변수를 공유하므로 가산 한 줄만 지우면 모든 지점이 같이 바로잡힌다.
- delete/reinsert 후 비워진 페이지가 재사용되는지 단언하는 회귀 테스트로 고정한다 (아래 Repro 의 `OosBestspaceTest` 케이스).

---

## AI-Generated Context

> 아래 내용은 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **문제 / 목적**: 비워진 OOS 페이지가 재사용되지 않아, 같은 행을 delete/reinsert 반복하면 OOS 파일이 계속 커진다.
- **원인 / 배경**: `oos_find_best_page` 가 필요 공간에 슬롯 1칸을 덧붙이는데, 비교 함수가 슬롯 자리를 이미 반영하므로 잉여 요구다.
- **제안 / 변경**: 슬롯 가산 한 줄 제거. 코드 한 줄 수정이며 디스크 포맷/호환성 영향 없음.
- **영향 범위**: `src/storage/oos_file.cpp` 의 페이지 선택 경로. 모든 OOS insert/reinsert 의 페이지 할당에 영향. 하위 호환.

---

## Description

### 배경 - 알아야 할 용어

이 버그를 이해하려면 OOS 가 디스크에 공간을 잡는 방식만 알면 된다.

- **slotted page**: OOS 페이지 한 장은 "슬롯 디렉터리 + 레코드 데이터" 구조다. 레코드 1개를 *새로* 만들려면 데이터 공간뿐 아니라 슬롯 디렉터리에 1칸(`SPAGE_SLOT`, 4바이트)도 필요하다. 단, 이미 비워진 슬롯을 재사용하면 새 칸은 필요 없다.
- **`spage_max_space_for_new_record`**: "이 페이지에 새 레코드 *데이터* 가 최대 몇 바이트 들어가나" 를 돌려주는 함수. 슬롯 자리 비용은 이 함수가 알아서 반영한다 - 새 슬롯을 만들어야 하면 슬롯 1칸을 빼고 돌려주고, 비워진 슬롯을 재사용할 수 있으면 빼지 않는다 (`slotted_page.c`). 즉 반환값은 곧 "새 레코드가 쓸 수 있는 순수 데이터 예산" 이다.
- **bestspace**: 여유공간이 있는 페이지를 캐싱해 두는 자료구조. 새 행을 넣을 때 새 페이지를 만들기 전에 여기서 재사용할 페이지를 먼저 찾는다.
- **freed page 재사용**: OOS 행을 delete 하면 그 페이지의 슬롯은 재사용 가능 상태(`REC_DELETED_WILL_REUSE`)로 남고(OOS 페이지는 ANCHORED 라 슬롯을 버리지 않고 재사용한다) 페이지는 bestspace 로 돌아온다. 다음 reinsert 가 이 빈 슬롯과 데이터 공간을 그대로 재사용해야 OOS 파일이 커지지 않는다.

### 무엇이 잘못됐나

핵심은 `oos_find_best_page` 의 필요 공간 계산 한 줄이다.

```c
/* oos_file.cpp, oos_find_best_page() - 현재 (버그) */
int total_space = rec_length + (int) sizeof (SPAGE_SLOT);
```

`spage_max_space_for_new_record` 가 슬롯 자리를 이미 반영해 "데이터 예산" 을 돌려주므로, 올바른 비교는 그 예산을 레코드 길이와 직접 견주는 것이다. heap 이 정확히 그렇게 한다.

| 비교 방식 | 페이지가 요구하는 필요 공간 |
|---|---|
| heap (정상) | `rec_length` |
| OOS (버그) | `rec_length + sizeof (SPAGE_SLOT)` |

OOS 는 함수가 이미 처리한 슬롯을 한 칸 더 요구하는 셈이다.

### 왜 freed 페이지가 탈락하나 - 구체 예시

큰 레코드 하나가 페이지를 거의 꽉 채운 상황을 보자. 그 레코드를 delete 하면 페이지는 같은 크기 레코드를 다시 받을 만큼 비워진다. reinsert 는 풀린 슬롯을 재사용하므로 새 슬롯이 필요 없다 - 진짜 필요한 건 데이터 `rec_length` 뿐이다.

- **올바른 판정**: `데이터 예산 >= rec_length` -> 충분하므로 통과. 페이지 재사용.
- **현재 판정**: `데이터 예산 >= rec_length + 슬롯 4바이트` -> 군더더기 슬롯 때문에 빠듯한 페이지가 탈락. `oos_file_alloc_new` 가 새 페이지를 할당.

회수(reclaim) 자체는 정상이다. 누수는 전적으로 reinsert 쪽 페이지 선택에서 생긴다.

## Test Build

`feat/oos` 최신(PR #6986 머지 이후), debug 빌드. OS: Linux x86_64.

## Repro

SA_MODE (standalone 모드 - 서버 프로세스 없이 클라이언트와 서버를 한 프로세스로 실행) 유닛 테스트로 재현한다.

```bash
# UNIT_TESTS 활성으로 빌드
cmake --preset debug -DUNIT_TESTS=ON
cmake --build build_preset_debug

# delete 후 reinsert 가 비워진 OOS 페이지를 재사용하는지 보는 bestspace 테스트
ctest --test-dir build_preset_debug -R test_oos_bestspace --output-on-failure
```

직접 겨냥하는 케이스(`unit_tests/oos/test_oos_bestspace.cpp`, fixture `OosBestspaceTest`): `BestspaceMultiChunkDeleteReuse`, `BestspaceBulkInsertDeleteReinsert`, `BestspaceDeleteThenFindReclaimsPage` - 모두 delete 후 freed 페이지가 재사용되는지 단언한다.

SQL 레벨 시나리오: `CREATE TABLE t (id INT PRIMARY KEY, big_col BIT VARYING)` 후 64KB 행을 INSERT 하고, "DELETE + 새 64KB 행 INSERT" 를 5회 반복한 다음 OOS 페이지 수를 센다.

## Expected Result

남는 행이 1개뿐이므로 OOS 페이지 수는 첫 INSERT 직후 수준(약 6)에서 유지된다. 단언: `pages_after_churn <= pages_after_insert + 2`.

## Actual Result

OOS 페이지 수가 약 6 -> 26 으로 늘어난다(사이클당 약 +4). 빈 페이지가 재사용되지 않고 매 reinsert 가 새 페이지를 할당한다.

## Additional Information

- **정설 비교(슬롯 미가산)**: heap 은 페이지 적합 판정에서 슬롯을 더하지 않고 `spage_max_space_for_new_record (...) < recdes->length` (`recdes` - 레코드 디스크립터) 로 비교한다(`heap_file.c`). bestspace 에 여유공간을 적재할 때도 슬롯 가산 없이 함수 원본값을 저장한다.
- **새 페이지에서도 가산은 잉여**: 재사용 슬롯이 없어 새 슬롯을 카브해야 하는 페이지에서는 `spage_max_space_for_new_record` 가 이미 슬롯 1칸을 빼서 돌려준다. 거기에 또 슬롯을 더하면 같은 슬롯이 문자 그대로 두 번 차감된다. 비워진 페이지든 새 페이지든, 호출자의 슬롯 가산은 어느 경우에나 잉여다.
- **`SPAGE_SLOT` 4바이트 근거**: `slotted_page.h` 의 비트필드 `offset_to_record:14` + `record_length:14` + `record_type:4` = 32비트 = 4바이트.
- **회수가 정상이라는 근거**: `oos_delete_chain` (행의 청크 체인을 따라가며 슬롯을 free 하는 함수)이 체인 끝까지 돌며 슬롯을 free 하고 빈 페이지를 bestspace 로 되돌린다. DELETE 만 했을 때는 페이지 증가 0, 행수 0 으로 확인된다.

## Remarks

- 발견 맥락: PR #6986 (CBRD-26668, vacuum 의 OOS 정리 연동)의 SA_MODE DELETE 회수 테스트를 추가하다 발견한 사전 결함이다. `oos_file.cpp` 할당 경로는 부모 브랜치 `feat/oos` 소속이라 #6986 범위 밖이므로 별도 PR 로 분리한다.
- 관련 이슈: CBRD-26658 (3-tier bestspace - `oos_find_best_page` 도입), CBRD-26786 (빈 OOS 페이지 회수), CBRD-26668 / PR #6986 (vacuum-OOS 연동).
