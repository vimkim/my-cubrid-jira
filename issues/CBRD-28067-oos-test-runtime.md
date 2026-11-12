# [OOS] OOS 단위 테스트를 ctest 항목마다 1분 안에 끝나게 나누고 1분 제한을 건다

**한 줄 요약**: 상위 이슈 [CBRD-27881](https://jira.cubrid.org/browse/CBRD-27881)의 하위 작업으로, OOS ctest 항목을 1분 안에 끝내고 시간 제한을 강제한다. 쓰기 경로를 분리할 수 있는 workspace 테스트의 병렬 실행도 같은 이슈에서 지원한다.

## Issue Triage

**이슈 수행 목적**: OOS 개발자가 개별 테스트의 결과를 빨리 받고, 독립적인 테스트는 함께 실행하여 전체 대기 시간도 줄이도록 한다.

**이슈 수행 이유**: 기존 측정에서 한 ctest 항목이 3~4분, 여러 항목이 1~2분 걸렸다. 일부 항목은 제한이 없거나 최대 840초까지 기다린다. 현재 workspace 테스트는 DB와 설정을 케이스별로 만들지만 설치 디렉터리의 로그와 임시 경로는 공유하므로, 직렬 실행 표시만 제거해서는 안전한 병렬 실행을 보장할 수 없다.

**영향**: 개발자가 느린 항목이나 멈춘 테스트를 오래 기다린다. 독립적인 workspace 묶음도 직렬로 실행되어 전체 검증 시간이 늘어난다. 공유 DB의 준비·정리가 등록 파일을 다시 쓰는 동안 다른 테스트가 이를 읽는 경합도 막아야 한다.

**이슈 수행 방안**: 측정값을 기준으로 `--gtest_filter` 묶음을 나누고, 검증하려는 상태를 관찰하면 대기를 끝낸다. 모든 항목에 60초 이하의 `TIMEOUT`을 요구한다. workspace는 케이스별 쓰기 경로를 분리한 뒤 병렬 실행을 허용하고, 공용 DB를 사용하는 테스트와 fixture는 직렬로 유지한다. 엔진 코드는 바꾸지 않는다.

---

## AI-Generated Context

## Description

대상은 `feature/oos-merge`의 `unit_tests/oos`와 `unit_tests/oos/sql`이다. 상위 이슈는 [CBRD-27881](https://jira.cubrid.org/browse/CBRD-27881)이다. 테스트가 확인하는 동작과 데이터 크기, 전체 케이스를 유지하는 테스트 전용 변경이다.

### 기존에 보고된 느린 항목

2026-11-12의 GCC Debug 측정에서 다음 항목이 오래 걸렸다. 부하와 실행 환경에 따라 시간은 달라진다.

| ctest 항목 | 기존 보고 시간 |
| --- | --- |
| `test_oos_real_vacuum_latch_timeout` | 3.2~3.8분 |
| `test_oos_workspace` | 1.9~2.2분 |
| `test_oos_real_vacuum_server` | 1.1~2.1분 |
| `test_oos_sql_deferred_write` | 1.3~3.0분 |
| `test_oos_sql_crash_recovery` | 1.2~1.7분 |
| `test_oos_concurrent_insert` | 0.7~1.6분 |

혼자 1분에 가깝거나 그 이상 걸린 것으로 보고된 gtest 케이스는 다음과 같다.

- `OosRealVacuumHeaderHeld.UnrelatedHeapVacuumedWhileHeaderLookupKeepsFailing`, 62초.
- `OosRealVacuumHeaderHeld.UnrelatedRowInSameBlockVacuumedWhileHeaderLookupKeepsFailing`, 62초.
- `OosSqlDeferredWrite.PendingReferencesResolveAndFinalizeInPlace`, 62초.
- `OosRealVacuum.UpdateStaleVersionDrainsNewSurvives`, 54초.
- `OosSqlDeferredWrite.RedistributionFailurePreservesSourceAndNextOperation`, 45초.

같은 날 기준 리비전 `67220b7e23`에서 다시 측정한 결과, 두 무관한 행 vacuum 케이스는 61.45초와 62.26초였다. 해당 코드에는 조건을 충족해도 60초를 채우는 대기가 있다. SQL 오류 경로에는 스택의 함수·소스 위치를 찾는 진단 비용도 있다. 오류 코드와 데이터 검사는 유지하면서 이 비용을 줄인다.

### 병렬 실행 범위 추가

독립적인 workspace 여섯 묶음과 DB를 쓰지 않는 순수 테스트를 병렬 실행 대상으로 한다. workspace의 각 케이스는 DB, 등록 파일, 설정, 작업 디렉터리뿐 아니라 `CUBRID` 아래의 `conf`, `log`, `tmp`, `var`도 따로 소유한다. 실행 파일과 라이브러리 등 읽기 전용 자산만 기존 설치를 참조한다. 자식 프로세스의 `CUBRID_TMP`와 `TMPDIR`도 해당 케이스의 경로로 지정한다.

공용 DB fixture의 준비·정리와 이를 사용하는 나머지 테스트는 `RUN_SERIAL`로 직렬 실행한다. 기존 DB 소유권 검사와 자원 잠금은 유지한다. 이번 변경에는 모든 DB 테스트의 병렬화를 위한 DB별 재설계나 엔진 변경을 포함하지 않는다.

### 범위 밖

PR [#8434](https://github.com/CUBRID/cubrid/pull/8434)에만 있는 다음 두 케이스는 이 이슈에서 바꾸지 않는다.

- `OosCrashRecoveryTest.FailedCommitReclaimStopsAndRestartRecoveryFinishesIt`, 기존 보고 102초.
- `OosServerCrashRecovery.CrashInUpdateCommitPostponesThenRestartReclaimsOnlyTheDroppedChains`, 기존 보고 37초.

## Acceptance Criteria

- DB 준비·정리 fixture를 포함한 모든 OOS ctest 항목이 60초 이하의 양수 `TIMEOUT`을 가진다. 누락, 0, 60초 초과 값은 CMake configure에서 오류가 된다.
- 서버가 한가할 때 각 항목이 30초 안에 끝나는 것을 목표로 한다. 부하가 있는 검증에서도 60초 제한을 넘지 않을 여유를 확인한다.
- 각 바이너리의 `--gtest_list_tests`와 실제 CTest 필터를 비교하여, 모든 gtest 케이스가 정확히 한 항목에 속함을 확인한다.
- 대기를 줄여도 기존 검증 동작과 assertion을 유지한다. 무관한 행의 회수는 헤더를 잡은 상태에서 조회 실패와 함께 관찰해야 한다.
- workspace 묶음의 DB·등록 파일·설정·로그와 CUBRID 임시 경로는 케이스별로 분리한다. 공용 설치에 쓰지 않음을 실제 파일 접근으로 확인한다.
- 공용 DB fixture의 준비·정리와 사용자 테스트는 다른 테스트와 겹치지 않는다. workspace와 순수 테스트의 실제 중첩 실행을 확인한다.
- `src/`의 엔진 코드는 변경하지 않는다.

## Verification

변경 전후의 항목별·케이스별 시간과 부하 평균을 기록한다. 최종 코드로 전체 OOS 테스트를 두 번 이상 통과시키고, 직렬 실행과 병렬 실행을 모두 포함한다. 병렬 실행은 낮은 동시 실행 수와 workspace 여섯 묶음이 함께 실행될 수 있는 설정을 확인한다.

- `ctest -R oos` 전체를 실행한다. OOS 디렉터리의 `test_byte_span_writer`는 이름에 `oos`가 없으므로 별도로 실행하거나 OOS 빌드 하위 디렉터리 전체를 실행한다.
- workspace 묶음을 병렬로 반복 실행하여 겹침과 실패 여부를 확인한다.
- 별도 진단 실행에서 파일·네트워크 시스템 호출을 추적한다. 진단 도구를 붙인 실행 시간은 성능 비교에 사용하지 않는다.
- CTest 속성에서 모든 시간 제한과 DB fixture 사용 항목의 직렬 실행 표시를 확인한다.
- 명시적인 별도 지시가 있기 전에는 CI를 시작하지 않는다.
