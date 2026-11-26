# [PL] PL 엔진 Gradle 빌드가 버전을 고정하지 않은 JDBC를 평문 HTTP로 받아 pl_server.jar에 포함한다

**한 줄 요약**: CBRD-27539 후속 감사에서, `cubrid-jdbc` 서브모듈이 없거나 Gradle을 직접 실행하면 PL 엔진 빌드가 `http://maven.cubrid.org/`에서 `cubrid-jdbc:latest.integration`을 내려받아 fat jar에 넣는다는 것을 확인했다. 재현 가능한 빌드와 전송 구간 위변조 위험 측면에서 처리 방향을 정하려는 이슈다.

## Issue Triage

**이슈 수행 목적**: PL 엔진 빌드가 어떤 경로로 실행되든 같은 JDBC 드라이버를 쓰고, 인증되지 않은 전송으로 내려받은 코드를 배포 jar에 넣지 않게 한다.

**이슈 수행 이유**: `pl_engine/CMakeLists.txt`는 `cubrid-jdbc/src`가 있을 때만 `-PcubridJdbcPath=`로 로컬 JDBC를 넘긴다. 그 외의 경우, 즉 서브모듈을 초기화하지 않은 checkout이나 `pl_engine`에서 `./gradlew`를 직접 실행한 경우에는 `build.gradle.kts`가 평문 HTTP 저장소(`isAllowInsecureProtocol = true`)에서 동적 버전 `latest.integration`을 받는다. `tasks.jar`는 `runtimeClasspath` 전체를 fat jar로 묶으므로 이 드라이버가 `pl_server.jar`에 포함된다.

**영향**:
- 같은 소스라도 빌드 시점에 저장소에 올라 있는 최신 JDBC에 따라 결과물이 달라진다.
- 네트워크 경로에서 응답이 바뀌면 그 코드가 서버와 함께 배포되는 PL 프로세스에 들어갈 수 있다.
- 공식 패키지 빌드가 이 경로를 타는지는 확인하지 않았다. 정상 CMake 빌드에서 서브모듈이 있으면 영향이 없다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

기준 소스: `CUBRID/cubrid` `develop` `ca5c2153ed`.

- `pl_engine/CMakeLists.txt:40-50`: `if (EXISTS ${CMAKE_SOURCE_DIR}/cubrid-jdbc/src)` 조건에서만 `LOCAL_JDBC_PATH_COMMAND "-PcubridJdbcPath=${PL_LIB_DIR}"`를 설정한다.
- `pl_engine/pl_server/build.gradle.kts:26-37`: `cubridJdbcPath`가 없으면 `maven { url = uri("http://maven.cubrid.org/"); isAllowInsecureProtocol = true }`를 쓴다.
- `pl_engine/pl_server/build.gradle.kts:61`: `implementation("cubrid:cubrid-jdbc:latest.integration")`.
- `pl_engine/pl_server/build.gradle.kts:145-152`: `tasks.jar`가 `runtimeClasspath`를 `zipTree`로 풀어 fat jar를 만든다.

[CBRD-23727](https://jira.cubrid.org/browse/CBRD-23727)(2020, Won't Fix)은 같은 저장소의 HTTPS 미지원 경고를 다뤘다. 그때 결론은 "당장 HTTPS를 지원할 계획이 없으니 `allowInsecureProtocol`로 경고를 끈다"였다. 이 이슈는 HTTPS 전환 자체보다 버전 고정과 출처 고정을 다룬다는 점에서 다르다.

### ANALYSIS 확인 사항

1. 공식 릴리스·패키지 빌드와 CI가 서브모듈 없이 이 경로를 타는 경우가 있는지 확인한다.
2. 후보: JDBC 버전 고정, 서브모듈이 없으면 빌드 실패, checksum 검증, HTTPS를 지원하는 저장소 사용. 이 중 무엇이 개발자의 직접 Gradle 실행 흐름을 덜 깨는지 비교한다.
3. 엔진과 JDBC 버전 사이의 호환 정책을 확인한다(`latest.integration`이 의도된 정책인지).

## Acceptance Criteria

- 같은 소스와 같은 설정으로 빌드한 `pl_server.jar`에 들어가는 JDBC 버전이 빌드 시점과 관계없이 같다.
- 배포 jar에 들어가는 외부 의존성을 인증되지 않은 전송으로 받지 않거나, 받더라도 무결성을 검증한다.

## Related

- [CBRD-23727](https://jira.cubrid.org/browse/CBRD-23727): 같은 저장소의 HTTPS 미지원 경고(Won't Fix)
- [CBRD-27539](https://jira.cubrid.org/browse/CBRD-27539): 에이전트 지침 감사 중 발견
