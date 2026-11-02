# [OOS] OOS 헤더 페이지를 로그 없이 dirty로 표시하는 반복 코드를 하나로 합친다

## Issue Triage

**이슈 수행 목적**: OOS 파일 헤더 페이지의 bestspace 힌트를 로그 없이 갱신하는 코드를 한 함수로 모아, "힌트는 WAL이 필요 없다"는 결정을 한 곳에서 설명하고 관리한다.

**이슈 수행 이유**: `oos_file.cpp`의 네 곳이 같은 여섯 줄(`LOG_DATA_ADDR` 준비, `log_skip_logging`, `pgbuf_set_dirty`)을 반복한다. 같은 결정이 네 곳에 흩어져 있어, 규칙을 바꿀 때 네 곳을 모두 찾아 고쳐야 한다.

**영향**: 동작은 바뀌지 않는다. `log_skip_logging` 호출도 그대로 둔다.

**이슈 수행 방안**: 여섯 줄을 `oos_hdr_page_set_dirty_unlogged`로 옮기고 네 곳에서 호출한다.

---

## AI-Generated Context

- CBRD-27881의 OOS 리팩토링 후보 조사(`feature/oos-merge` dcbf09e4f 기준)에서 나온 네 번째 단위이다.
- 검증: OOS 관련 ctest 44개가 변경 전후 모두 통과했다. gdb로 확인하니 네 곳 중 세 곳은 기존 테스트가 실행한다. sync-scan 직전의 한 곳은 어떤 OOS 테스트도 실행하지 않았고, 조건을 강제로 바꿨을 때만 실행됐다. 이는 CBRD-27881 조사에서 별도 결함 후보로 기록한 "tier-3 bestspace sync가 실행되지 않는다"는 관찰과 일치한다.
