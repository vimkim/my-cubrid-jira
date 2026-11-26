CBRD-27539 후속 감사(`develop` `ca5c2153ed`)에서 이 이슈와 같은 문제를 다시 확인했고, ANALYSIS에 참고할 관련 사항 네 가지를 덧붙인다.

1. **주석 처리된 LOADDB 블록이 `monitor`를 등록한다.** `unit_tests/CMakeLists.txt`의 `TODO compilation fails` 블록 중 `UNIT_TEST_LOADDB` 조건 안에 `message("    monitor")` / `add_subdirectory(monitor)`가 들어 있다. 복사·붙여넣기 오류로 보인다. 이 블록의 주석을 그대로 해제하면 `monitor`가 두 번 추가되어 target이 중복되고, `loaddb` 테스트는 여전히 빌드되지 않는다.
2. **`UNIT_TEST_OBJECT_FACTORY`가 `option()`으로 선언되어 있지 않다.** `if (UNIT_TESTS OR UNIT_TEST_OBJECT_FACTORY)`에서는 쓰이지만 상단의 `option (UNIT_TEST_...)` 목록에 없다. `-DUNIT_TEST_OBJECT_FACTORY=ON`은 일반 cache 변수로 동작하지만, `cmake -LH`나 `ccmake`에는 나타나지 않는다.
3. **lockfree가 컴파일되지 않는다는 주석이 낡았다.** `log_prior_inflight` 블록 위의 주석 "Separate from lockfree/ only while that module does not compile"은 lockfree를 다시 활성화한 커밋(`2ba9fdc8a8`) 이후 사실이 아니다. 주석이 약속한 `log_prior_inflight` → `lockfree` 통합도 이루어지지 않았다.
4. **legacy 모듈 일부는 그대로 `add_test`에 넣기 어렵다.** 나머지 모듈과 달리 `json_builder`, `double_write_buffer`, `stream_session`은 `CATCH_CONFIG_MAIN`을 쓰는 Catch2 모듈이라, 등록된 다른 Catch2 모듈(`scope_exit`, `radix_sort`, `btree_sort_merge`, `log_recovery`)처럼 바로 등록할 수 있다. 반면 `lockfree`는 인자 없이 실행하면 hashmap 성능 테스트를 포함하고(`unit_tests/lockfree/test_main.cpp`의 `do_performance`), `string_buffer`는 `time` 실행 모드가 있다. ANALYSIS 확인 사항 2(장시간·시간 의존 테스트 분리)의 대상으로 보인다.

참고로 CBRD-27539 PR(2)에서는 `unit_tests/AGENTS.md`가 현재 상태(어느 모듈이 `ctest`에 등록되어 있는지)를 사실대로 설명하도록 고치고, 이 이슈 키를 남긴다. 이 이슈가 해결되면 해당 문서 문구도 함께 갱신해야 한다.
