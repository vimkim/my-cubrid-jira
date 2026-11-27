# [OOS] 단위 테스트 test_oos_real_vacuum_latch_timeout_retry가 아무도 로그를 쓰지 않으면 로그 flush를 끝없이 기다린다

**한 줄 요약**: OOS 단위 테스트가 아직 기록되지 않은 로그 위치까지 flush를 요청해서, 앞선 테스트가 vacuum 작업을 모두 끝낸 상태에서 실행하면 ctest timeout(60초)까지 멈추는 테스트 코드 결함을 고친다.

## Issue Triage

**이슈 수행 목적**: OOS 단위 테스트 `test_oos_real_vacuum_latch_timeout_retry`가 실행 순서와 관계없이 끝나서, OOS 단위 테스트 전체를 ctest로 돌린 결과를 믿을 수 있게 한다.

**이슈 수행 이유**: 이 테스트의 로그 flush 헬퍼는 `log_Gl.prior_info.prior_lsa`까지 flush를 요청한다. 이 위치는 다음 로그 레코드가 들어갈 자리이므로, 다른 스레드가 새 로그를 쓰기 전에는 flush가 끝나지 않는다. 바로 앞의 `test_oos_real_vacuum_latch_timeout`이 같은 DB에서 vacuum 작업을 모두 처리한 뒤에는 로그를 쓰는 스레드가 없어서, 두 테스트를 순서대로 실행하면 10회 중 10회 timeout이 났다.

**영향**: OOS 단위 테스트를 ctest로 전체 실행하는 개발자는 엔진 변경과 무관한 timeout 실패를 보고, 원인을 조사하거나 재실행하는 데 시간을 쓴다. 엔진 동작에는 영향이 없다. 엔진의 `logpb_flush_pages()` 호출자는 이미 기록한 레코드의 시작 위치를 넘긴다. 공식 CI(gha-ci)는 `UNIT_TESTS`를 켜지 않고 ctest도 실행하지 않으므로, CI 결과에는 이 문제가 나타나지 않는다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

OOS 단위 테스트 바이너리 `test_oos_real_vacuum_server`는 실제 vacuum 데몬이 동작하는 서버 모드로 실행된다. 테스트는 vacuum이 로그 블록을 처리하게 하려고, 블록을 닫은 뒤 로그를 디스크까지 flush한다. 이 flush 요청 위치가 잘못되어, 다른 스레드가 로그를 쓰지 않으면 flush가 끝나지 않는다.

이 문제는 PR #8730을 검증하던 중 전체 ctest 실행(73/74 통과)에서 처음 보였다. 같은 테스트를 단독으로 반복 실행하면 3회 모두 약 11초에 통과했기 때문에, 처음에는 간헐적인 문제로 보였다.

## Test Build

- 소스: `develop` 0eec910fc1 (OOS 단위 테스트는 CBRD-26357 PR #7990에서 추가되었다)
- 빌드: GCC, `CMAKE_BUILD_TYPE=RelWithDebInfo`, `UNIT_TEST_OOS=ON`
- assert가 켜진 Debug 빌드에서는 재현하지 않았다.

## Repro

CUBRID 환경 변수(`CUBRID`, `CUBRID_DATABASES`)를 설정한 상태에서 OOS 단위 테스트를 켜고 빌드·설치한다.

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo -DUNIT_TEST_OOS=ON
cmake --build build -j
cmake --install build
```

DB fixture, 앞 테스트, 대상 테스트를 순서대로 실행한다. 세 테스트는 같은 DB(`OOS_DB` fixture)를 쓰고 `RUN_SERIAL`로 차례대로 실행된다.

```sh
ctest --test-dir build -V \
  -R '^(oos_setup_db|test_oos_real_vacuum_latch_timeout|test_oos_real_vacuum_latch_timeout_retry)$'
```

`test_oos_real_vacuum_latch_timeout_retry`는 다음 명령과 환경으로 실행된다(`unit_tests/oos/CMakeLists.txt`).

- 명령: `test_oos_real_vacuum_server --gtest_filter=OosRealVacuumHeaderHeld.FailingHeapCostsOneLookupPerRun:OosRealVacuumHeaderHeld.ImmediateFailureRerunsAtMostOncePerSecond`
- 환경: `CUBRID_PAGE_LATCH_TIMEOUT_IN_MSECS=2000`, `CUBRID_FAULT_INJECTION_IDS=800000`, `CUBRID_VACUUM_WORKER_COUNT=1`

## Expected Result

`test_oos_real_vacuum_latch_timeout_retry`가 앞 테스트 실행 여부와 관계없이 약 11초 안에 통과한다.

## Actual Result

- 앞 테스트 다음에 실행하면 10회 중 10회 timeout이 났다. 마지막 출력은 `[ RUN      ] OosRealVacuumHeaderHeld.FailingHeapCostsOneLookupPerRun`이고, 이후 60초 ctest timeout까지 진행하지 않는다.
- DB fixture 바로 다음에 단독으로 실행하면 3회 모두 통과했다.

멈춘 테스트 프로세스에 gdb를 붙여 얻은 스택이다. 정상적으로 얻은 7개 스택이 모두 같다.

```text
#0  pthread_cond_timedwait
#2  logpb_flush_pages                      src/transaction/log_page_buffer.c:4178
#3  OosRealVacuumHeaderHeld::flush_log     unit_tests/oos/test_oos_real_vacuum_server.cpp:1318
#4  close_block_with_oos_fillers           unit_tests/oos/test_oos_real_vacuum_server.cpp:1328
#5  FailingHeapCostsOneLookupPerRun        unit_tests/oos/test_oos_real_vacuum_server.cpp:1714
```

같은 시점에 vacuum master, vacuum worker, log flush 데몬은 모두 할 일 없이 대기하고 있었다. 로그 위치는 다음과 같았다.

| 값 | LSA |
|---|---|
| `log_Gl.prior_info.prior_lsa` (다음 레코드가 들어갈 위치) | 713\|832 |
| `log_Gl.append.nxio_lsa` (디스크에 기록된 끝 위치) | 713\|832 |
| `log_Gl.hdr.append_lsa` | 713\|832 |
| `log_Gl.prior_info.prev_lsa` (마지막 레코드의 시작 위치) | 713\|776 |

prior list에 대기 중인 레코드는 없었고, `log_Pb.partial_append.status`는 `LOGPB_APPENDREC_SUCCESS`였다.

## Additional Information

### 원인

테스트 헬퍼 두 곳이 `prior_lsa`까지 flush를 요청한다(소스 줄 번호는 `develop` 0eec910fc1 기준).

- `OosRealVacuumHeaderHeld::flush_log()` (`unit_tests/oos/test_oos_real_vacuum_server.cpp:1315-1319`): `FailingHeapCostsOneLookupPerRun` 등이 `close_block_with_oos_fillers()`를 거쳐 호출한다.
- `VacuumWaitsForHeapHeaderWithoutHoldingLastPage` (`unit_tests/oos/test_oos_real_vacuum_server.cpp:1066-1067`): 같은 코드가 있다.

`logpb_flush_pages()`는 서버 모드에서 `logpb_need_wal (flush_lsa)`가 거짓이 될 때까지 1초 간격으로 log flush 데몬을 깨우고 기다린다(`src/transaction/log_page_buffer.c:4158-4180`). `logpb_need_wal()`은 `nxio_lsa <= lsa`일 때 참이다(`src/transaction/log_page_buffer.c:11995`). 모든 로그가 flush되면 `nxio_lsa`는 `hdr.append_lsa`가 되고(`src/transaction/log_page_buffer.c:3895`), 이 값은 `prior_lsa`와 같다. 따라서 `prior_lsa`까지 요청한 flush는 다른 스레드가 새 레코드를 써서 `nxio_lsa`가 더 앞으로 가야 끝난다.

엔진의 호출자는 방금 쓴 레코드의 시작 위치를 넘긴다. 예: `log_manager.c:3401`의 `start_lsa = prior_lsa_next_record (...)` 다음 `logpb_flush_pages (thread_p, &start_lsa)`. 그래서 같은 문제가 엔진에는 없다.

### 실행 순서에 따라 결과가 달라지는 이유 (추정)

DB를 막 만든 직후에는 vacuum이 남은 로그 블록을 처리하면서 로그를 쓰기 때문에, 대기가 우연히 풀리는 것으로 보인다. 앞 테스트가 그 작업을 모두 끝낸 뒤에는 로그를 쓰는 스레드가 없어서 대기가 풀리지 않는다. 멈춘 시점에 vacuum 스레드가 모두 대기 중이었다는 관찰과는 맞지만, 단독 실행에서 대기를 푼 로그 레코드가 무엇인지는 확인하지 않았다.

### 검증한 수정 후보

두 곳에서 `log_Gl.prior_info.prev_lsa`(마지막으로 쓴 레코드의 시작 위치)까지 flush하도록 바꾸면, 엔진 호출자와 같은 방식이 된다. 이 변경으로 `oos_setup_db`, `test_oos_real_vacuum_latch_timeout`, `test_oos_real_vacuum_latch_timeout_retry`, `test_oos_real_vacuum_latch_timeout_shutdown`을 순서대로 5회 실행했을 때 모두 통과했다. 대상 테스트는 10.9-11.9초에 끝났다. 변경은 테스트 파일에만 있다. Debug 빌드에서는 검증하지 않았다.

### 관련 이슈

- CBRD-27860 (Resolved): 이 이슈 설명에 실린 회귀 테스트 diff에 `VacuumWaitsForHeapHeaderWithoutHoldingLastPage`의 `prior_lsa` flush 코드가 들어 있다. 이 이슈가 다루는 잘못된 flush 위치는 그 테스트 코드에서 쓰기 시작한 것으로 보인다. CBRD-27860이 다룬 엔진 결함(vacuum과 새 힙 페이지 할당의 래치 대기)과는 다른 문제다.
- CBRD-28067 (Resolved): OOS 단위 테스트를 ctest 항목마다 1분 안에 끝나도록 나누고 `TIMEOUT 60`을 걸었다. 그 결과 이 대기가 무한 대기 대신 60초 timeout 실패로 보이게 되었다. 느린 테스트를 나누는 작업이고, 이 이슈의 원인을 다루지 않는다.

### 별도 관찰

수정 후 전체 ctest에서 다른 바이너리의 `test_oos_sql_deferred_write_preparation`(`OosSqlDeferredWrite.OwnerlessCopyAreaBypassMissingTdesPreservesPairAndFails`)이 30초 timeout으로 한 번 실패했다. 단독으로 6회 실행하면 모두 통과했다. 이 이슈와 원인이 같은지는 확인하지 않았으므로 이 이슈의 범위에 넣지 않는다.
