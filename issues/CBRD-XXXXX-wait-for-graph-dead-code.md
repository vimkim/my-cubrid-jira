# [TRANSACTION] 컴파일되지 않는 wait_for_graph.c 교착 그래프 코드와 정의 없는 catalog_destroy 선언 정리

**한 줄 요약**: CBRD-28411에 묶여 있던 세 문제 중 3번을 Joon Min의 triage 요청에 따라 분리한 이슈다. 본문 전체가 `ENABLE_UNUSED_FUNCTION` 으로 막힌 `src/transaction/wait_for_graph.c` 가 여전히 서버·SA 빌드 목록에 등록되어 있고, `src/storage/system_catalog.h` 의 `catalog_destroy` 는 선언만 있고 정의가 없다.

## Issue Triage

**이슈 수행 목적**: 실제 교착 탐지 경로를 찾는 개발자가 컴파일되지 않는 코드와 정의 없는 선언 때문에 잘못된 위치로 안내받지 않게 한다.

**이슈 수행 이유**: `wait_for_graph.c`(2,434줄)는 25행부터 파일 끝까지 `#if defined(ENABLE_UNUSED_FUNCTION)` 안에 있어 실제로는 아무것도 컴파일되지 않는다. 그런데 `cubrid/CMakeLists.txt` 와 `sa/CMakeLists.txt` 의 소스 목록에 등록되어 있고, `lock_manager.c` 가 헤더를 include한다. `wfg_*` 함수를 부르는 곳(`lock_manager.c`, `log_tran_table.c`)도 모두 `#if 0` 이나 `ENABLE_UNUSED_FUNCTION` 안에 있다. 같은 종류의 흔적으로, `system_catalog.h:159` 의 `catalog_destroy` 는 선언만 있고 소스 트리 어디에도 정의가 없다.

**영향**: 서버 동작에는 영향이 없다. 문제는 코드 탐색과 문서 작성이다. 2,400줄 규모의 교착 그래프 구현이 빌드 목록에 살아 있으므로 실제 교착 탐지 코드(`lock_manager.c`)로 착각하기 쉽다. 실제로 `develop` 의 `src/transaction/AGENTS.md` 는 이 파일을 교착 탐지 위치이자 교착 수정 시 볼 파일로 안내하고, `src/storage/docs/catalog-statistics-maintenance.md` 는 `catalog_destroy()` 를 주요 진입점으로 소개한다. 두 문서는 CBRD-27539의 PR #8765(미병합)에서 정정 중이지만, 코드가 그대로 남아 있으면 같은 오해가 다시 생길 수 있다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

기준 소스: `CUBRID/cubrid` `origin/develop` `0eec910fc1`(2026-11-26). 아래 행 번호는 이 커밋 기준이다.

### 컴파일되지 않는 교착 그래프 코드

- `src/transaction/wait_for_graph.c:25` `#if defined(ENABLE_UNUSED_FUNCTION)` 부터 `:2434` `#endif /* ENABLE_UNUSED_FUNCTION */`(파일 끝)까지 본문 전체가 막혀 있다. `src/transaction/wait_for_graph.h:30` 도 같은 guard를 쓴다.
- 빌드 등록: `cubrid/CMakeLists.txt:508`, `sa/CMakeLists.txt:495` 의 `${TRANSACTION_DIR}/wait_for_graph.c`.
- include: `src/transaction/lock_manager.c:75` `#include "wait_for_graph.h"`.
- 호출부도 모두 컴파일되지 않는다.
  - `lock_manager.c:10638` `wfg_detect_cycle` 등: `:10597` `#if 0 /* NOT_USED */` ~ `:10773` 구간
  - `log_tran_table.c:327` `wfg_alloc_nodes`: `:326` `#if defined(ENABLE_UNUSED_FUNCTION)` 안
  - `log_tran_table.c:633` `wfg_free_nodes`: `:632` `#if defined(ENABLE_UNUSED_FUNCTION)` 안
- 남은 흔적: `src/thread/critical_section.h:59` `CSECT_WFG = 0`(주석 "Latch for wait-for-graph"), `src/thread/critical_section.c:77` 의 이름 `"WFG"`. 이 critical section을 쓰는 코드는 `wait_for_graph.c` 밖에 없다.

### 정의 없는 선언

- `src/storage/system_catalog.h:159` `extern int catalog_destroy (void);`
- `src/` 아래에서 `catalog_destroy` 정의나 호출은 찾을 수 없다. 문서 언급은 `src/storage/docs/catalog-statistics-maintenance.md` 한 곳이며, PR #8765에서 제거 중이다.
- 파일은 storage 모듈이지만 "컴파일되거나 정의되지 않는 코드 흔적" 이라는 같은 성격이라 Joon Min의 요청대로 이 이슈에 함께 둔다.

### ANALYSIS 확인 사항

1. `wait_for_graph.c/.h` 를 지울지, 남긴다면 왜 남기는지 코드에 적을지 정한다.
2. 지운다면 함께 정리할 범위를 정한다: CMake 목록 두 곳, `lock_manager.c` 의 include, `#if 0`·`ENABLE_UNUSED_FUNCTION` 안의 `wfg_*` 호출부, `CSECT_WFG` 와 critical section 이름 표.
3. `CSECT_WFG` 는 enum 값이 0이라서, 지우면 다른 critical section 번호가 하나씩 당겨진다. 이 번호가 통계 출력이나 진단 도구 등 외부에 보이는 곳에 쓰이는지 확인한다.
4. `catalog_destroy` 선언을 지워도 되는지 확인한다(빌드와 외부 헤더 사용처).

## Acceptance Criteria

- 컴파일되지 않는 교착 그래프 코드가 빌드 목록과 include에서 제거되거나, 남는 이유가 코드에 적혀 있다.
- 정의 없는 `catalog_destroy` 선언이 제거되거나, 남는 이유가 코드에 적혀 있다.
- 서버와 SA 빌드가 성공하고 교착 탐지 동작은 바뀌지 않는다.

## Related

- [CBRD-28411](https://jira.cubrid.org/browse/CBRD-28411): 이 문제가 처음 함께 보고된 이슈(1·2번 빌드 스크립트·PL 빌드 문제는 그쪽에 남음)
- [CBRD-27539](https://jira.cubrid.org/browse/CBRD-27539): 에이전트 지침 감사 중 발견, 문서 정정은 [PR #8765](https://github.com/CUBRID/cubrid/pull/8765)
