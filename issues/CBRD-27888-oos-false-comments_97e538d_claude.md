# [OOS] 코드와 맞지 않는 OOS 주석을 바로잡는다

## Issue Triage

**이슈 수행 목적**: OOS 관련 주석 중 지금의 코드와 다른 사실을 말하는 것을 바로잡아, 주석을 믿고 읽는 개발자가 잘못된 결론을 내리지 않게 한다.

**이슈 수행 이유**: OOS 코드는 여러 번 고쳐지는 동안 일부 주석이 따라오지 못했다. 예를 들어 `vacuum.c`의 한 주석은 존재하지 않는 "위의 undo_data_size 검사"를 근거로 들고, `oos_file.cpp`의 한 주석은 이미 없어진 `upper_bound`를 설명한다. heap 삭제와 갱신 경로의 주석은 즉시 삭제 조건을 "SA_MODE"라고 적지만, 실제 조건은 `!is_mvcc_op`이며 SERVER_MODE의 MVCC 비활성 클래스와 in-place update도 포함한다. 주석이 commit hash에 기대는 곳과 위치가 틀린 줄 번호 참조도 있다.

**영향**: 실행 코드는 바뀌지 않는다. 내용이 없는 빈 `if` 블록 하나를 같은 내용의 주석으로 바꾼다.

**이슈 수행 방안**: 근거로 틀렸음을 확인한 주석만 고친다. 각 주석이 가리키는 코드 위치를 확인하고, 실행 token이 바뀌지 않았음을 비교로 확인한다.

---

## AI-Generated Context

- CBRD-27881의 OOS 리팩토링 후보 조사(`feature/oos-merge` dcbf09e4f 기준)에서 나온 일곱 번째 단위이다.
- 대상 파일: `vacuum.c`, `vacuum_oos.cpp`, `heap_file.c`, `oos_file.cpp`, `oos_file.hpp`, `locator.h`, `log_manager.c`.
- 검증: 독립 리뷰가 새 주석을 하나씩 코드와 대조했다. 주석을 제거한 token 비교에서 빈 `if` 하나 외에는 차이가 없다.
