# [unit_tests] ctest에 미등록된 C/C++ 단위 테스트 타깃 실행 누락 정비

**한 줄 요약**: [PR #8751 리뷰 댓글](https://github.com/CUBRID/cubrid/pull/8751#discussion_r4694061501)에서 지적한 바와 같이, 활성화된 `unit_tests/` C/C++ 단위 테스트 중 상당수가 `add_test()`로 등록되지 않아 `ctest` 실행 시 누락되는 문제를 해소한다.

## Issue Triage

**이슈 수행 목적**: 활성화된 `unit_tests/` C/C++ 단위 테스트 타깃이 `ctest`를 통해 일관되게 발견·실행되도록 정비한다.

**이슈 수행 이유**: 루트 `AGENTS.md`와 `unit_tests/AGENTS.md`는 `-DUNIT_TESTS=ON` 또는 `-DUNIT_TEST_<MODULE>=ON` 설정 후 `ctest`로 단위 테스트를 실행하도록 안내하지만, 현재 활성화된 17개 단위 테스트 모듈 가운데 12개 모듈이 `add_executable()`만 정의하고 `add_test()`가 빠져 있어 `ctest` 실행에서 조용히 건너뛰어진다.

**영향**: 개발자나 AI 에이전트가 `-DUNIT_TEST_MEMORY_ALLOC=ON` 등으로 단위 테스트를 빌드하고 `ctest`를 실행해도 실제 테스트가 전혀 돌지 않거나(`No tests were found!!!`), 전체 테스트를 돌렸다고 오인할 위험이 있다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

기준 커밋(`CUBRID/CUBRID` `origin/develop` `cbed1d5707`, PR `#8751` 헤드 `e4da2c73ea`)에서 루트 `CMakeLists.txt:817`은 `enable_testing()`을 활성화하고 있으나, `unit_tests/` 하위 모듈별 `CMakeLists.txt`의 `ctest` 등록 상태는 일관되지 않다.

### 확인한 현황

- **등록됨 (`add_test()` 존재, 5개 디렉터리)**: `btree_sort_merge`, `log_recovery`, `oos`, `radix_sort`, `scope_exit`
- **활성화되었으나 미등록 (`add_executable()`만 존재, 12개 디렉터리)**:
  - `double_write_buffer` (`test_double_write_buffer`)
  - `json_builder` (`test_json_builder`)
  - `lockfree` (`test_lockfree`)
  - `log_prior_inflight` (`test_log_prior_inflight`)
  - `memory_alloc` (`test_memory_alloc`)
  - `monitor` (`test_monitor`)
  - `object_factory` (`test_object_factory`)
  - `packing` (`test_packing`)
  - `resource_tracker` (`test_resource_tracker`)
  - `stream_session` (`test_stream_session`)
  - `string_buffer` (`test_string_buffer`)
  - `thread` (`test_thread`)
- **컴파일 실패로 비활성화 (`unit_tests/CMakeLists.txt`에서 주석 처리, 2개 디렉터리)**: `loaddb`, `memory_monitor`

`AGENTS.md`와 `unit_tests/AGENTS.md` 모두 단위 테스트 표준 실행 경로로 `ctest`를 안내하고 있으나, `test_memory_alloc`을 비롯한 위 12개 타깃은 빌드만 되고 `ctest` 목록에 포함되지 않는다.

### ANALYSIS 확인 사항

1. 위 12개 활성 단위 테스트 타깃 각각이 현재 `origin/develop` 환경에서 정상 컴파일되며, 별도 인자·대화형 입력·외부 파일이나 장시간 실행 없이 무인 `ctest` 환경에서 통과하는지 확인한다.
2. 단독 실행이 어렵거나 실행 시간이 길거나 현재 실패하는 구형 테스트가 있다면, `ctest` 등록 전 수정 대상과 라벨·필터 분리 대상을 구분한다.
3. 이미 컴파일 오류로 비활성화된 `loaddb`와 `memory_monitor`는 이번 범위에서 제외할지, 별도 정비 대상으로 둘지 결정한다.

## Acceptance Criteria

- 활성화된 C/C++ 단위 테스트 모듈 중 `ctest`에 등록하기로 결정된 타깃들이 `-DUNIT_TESTS=ON` 또는 개별 `-DUNIT_TEST_<MODULE>=ON` 구성 후 `ctest` 실행으로 누락 없이 발견되고 실행된다.
- 무인 `ctest` 실행에 적합하지 않거나 추가 선행 조건이 필요한 타깃이 있다면 그 기준과 실행 방법이 `unit_tests/CMakeLists.txt` 및 `unit_tests/AGENTS.md`에 일치하도록 정리된다.

### 관련 이슈

- [CBRD-27539](https://jira.cubrid.org/browse/CBRD-27539): 루트 `AGENTS.md` 및 `src/AGENTS.md` 공통 지침 정비 (PR `#8751` Greptile 리뷰에서 본 누락 사항이 보고됨)
