# [BUILD] build.sh 도움말과 실제 옵션 불일치, pl_unittest의 빌드 디렉터리 전달 오류, 컴파일되지 않는 교착 그래프 코드 정리

**한 줄 요약**: CBRD-27539 후속 감사에서 찾은 작은 빌드·코드 불일치 세 가지를 묶었다. 각각 `build.sh -h`가 처리하지 않는 옵션을 안내하는 문제, `pl_unittest` 타깃이 Gradle에 빌드 디렉터리를 잘못된 방식으로 넘기는 문제, 전체가 `ENABLE_UNUSED_FUNCTION`으로 막힌 `wait_for_graph.c`가 계속 빌드에 등록되어 있는 문제다.

## Issue Triage

**이슈 수행 목적**: 개발자와 AI 에이전트가 신뢰하는 빌드 도움말·빌드 타깃·소스 목록이 실제 동작과 일치하게 한다.

**이슈 수행 이유**:
1. `build.sh` usage는 `-i`(빌드 번호 증가)와 `-a`(autogen.sh 실행)를 안내한다. 그런데 옵션 처리 `case`에 해당 분기가 없어서, 두 옵션을 쓰면 usage를 출력하고 exit 1로 끝난다. `-b`의 기본값 설명(`build_<mode>_<target>`)은 실제(`build_<target>_<mode>`)와 순서가 반대이고, `-j`의 기본값 설명(`/usr/java/default`)도 실제 기본값(`/usr/lib/jvm/java`)과 다르다.
2. `pl_engine/CMakeLists.txt`의 `pl_build`는 `-PbuildDir=`(Gradle 프로젝트 속성)를 넘기는데 `pl_unittest`는 `-DbuildDir=`(JVM 시스템 속성)를 넘긴다. `build.gradle.kts`는 시스템 속성을 읽지 않으므로, `pl_unittest`는 CMake 빌드 디렉터리가 아니라 소스 트리 안의 `pl_engine/pl_server/build`에서 다시 컴파일한다.
3. `src/transaction/wait_for_graph.c`(약 2,400줄)는 본문 전체가 `#if defined(ENABLE_UNUSED_FUNCTION)` 안에 있는데, `cubrid/CMakeLists.txt`와 `sa/CMakeLists.txt`에 등록되어 있다. `src/storage/system_catalog.h`의 `catalog_destroy` 선언은 정의가 없다.

**영향**:
- 1은 도움말을 보고 옵션을 고른 사용자의 빌드를 즉시 실패시킨다.
- 2는 CMake 빌드 결과와 다른 위치에서 테스트를 컴파일하므로 중복 빌드가 생기고 소스 트리에 산출물이 남는다. 그 산출물은 `.gitignore`로 가려진다.
- 3은 동작 영향은 없지만 살아 있는 교착 탐지 구현처럼 보여서 코드 탐색과 문서 작성을 오도한다. 실제로 `src/transaction/AGENTS.md`가 이 파일을 교착 탐지 위치로 안내하고 있었다(CBRD-27539 PR(2)에서 문서는 정정).

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

기준 소스: `CUBRID/cubrid` `develop` `ca5c2153ed`.

### build.sh

- usage: `build.sh:502` `-i`, `:503` `-a`, `:508` `-b ... [default: <source path>/build_<mode>_<target>]`, `:512` `-j ... [default: /usr/java/default]`.
- 처리: `build.sh:538`의 `getopts ":t:m:g:is:b:p:o:aj:c:C:z:xvh"`는 `i`와 `a`를 받는다. 그러나 `:540-563`의 `case`에는 `i`나 `a` 분기가 없어서 `h|\?|* ) show_usage; exit 1;;`로 간다.
- 실제 기본값: `build.sh:585` `build_dir="$source_dir/build_${build_target}_${build_mode}"`, `build.sh:34` `default_java_dir="/usr/lib/jvm/java"`.

### pl_unittest

- `pl_engine/CMakeLists.txt:71,76`(`pl_build`): `-PbuildDir=${PL_ENGINE_BUILD_DIR}`
- `pl_engine/CMakeLists.txt:83,87`(`pl_unittest`): `-DbuildDir=${PL_ENGINE_BUILD_DIR}`

### 컴파일되지 않는 코드

- `src/transaction/wait_for_graph.c:25` `#if defined(ENABLE_UNUSED_FUNCTION)`부터 파일 끝 `:2434`까지. `wait_for_graph.h`도 같은 guard를 쓰고, `lock_manager.c:75`가 include한다.
- `cubrid/CMakeLists.txt:508`, `sa/CMakeLists.txt:495`에 `${TRANSACTION_DIR}/wait_for_graph.c`가 등록되어 있다.
- `src/storage/system_catalog.h:159` `extern int catalog_destroy (void);`에 해당하는 정의는 트리 어디에도 없다.

### ANALYSIS 확인 사항

1. `-i`, `-a`를 구현할지 usage에서 지울지 정한다(빌드 번호와 autogen 단계가 지금도 필요한지).
2. `pl_unittest`를 `-PbuildDir`로 바꾸면 테스트 결과나 Windows 경로에 영향이 있는지 확인한다.
3. `wait_for_graph.c/.h`를 지울지, 남긴다면 왜 남기는지 주석으로 밝힐지 정한다. 지울 경우 `lock_manager.c`의 include도 함께 정리한다(다른 참조는 CMake 목록뿐이다).

## Acceptance Criteria

- `build.sh -h`가 안내하는 옵션은 모두 실제로 처리되고, 안내된 기본값은 실제 기본값과 같다.
- `pl_unittest`는 `pl_build`와 같은 빌드 디렉터리를 쓴다.
- 컴파일되지 않는 교착 그래프 코드와 정의 없는 `catalog_destroy` 선언이 제거되거나, 남는 이유가 코드에 적혀 있다.

## Related

- [CBRD-27539](https://jira.cubrid.org/browse/CBRD-27539): 에이전트 지침 감사 중 발견
