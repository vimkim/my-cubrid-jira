# [OOS] 쓰이지 않는 bestspace 매크로, 테스트 bridge, 상수 인자를 제거한다

## Issue Triage

**이슈 수행 목적**: `oos_file.cpp`와 `oos_file.hpp`에서 아무도 쓰지 않는 코드를 지워, OOS 코드를 읽는 개발자가 의미 없는 매크로와 인자를 해석하지 않게 한다.

**이슈 수행 이유**: `OOS_STATS_PREV_BEST_INDEX` 매크로와 테스트용 함수 `bridge_oos_vpid_init_new`는 저장소 어디에서도 쓰이지 않는다. `oos_stats_update`의 `prev_freespace` 인자는 유일한 호출부인 `oos_delete_chain`이 항상 0을 넘긴다. `pgbuf_unfix_and_init` 바로 뒤의 `*out_pgptr = NULL;`은 매크로가 이미 하는 일을 반복한다.

**영향**: 동작은 바뀌지 않는다. OOS 파일 관리 코드에서 읽어야 할 코드와 오해할 여지가 줄어든다.

**이슈 수행 방안**: 위 네 항목을 지운다. 구현은 PR https://github.com/CUBRID/cubrid/pull/8367 이다.

---

## AI-Generated Context

- CBRD-27881의 OOS 리팩토링 후보 조사(`feature/oos-merge` dcbf09e4f 기준)에서 나온 첫 번째 단위이다.
- 검증: `UNIT_TEST_OOS=ON` debug 빌드에서 OOS 관련 ctest 44개가 변경 전후 모두 통과했다. 독립 리뷰와 독립 재실행으로 확인했다.
