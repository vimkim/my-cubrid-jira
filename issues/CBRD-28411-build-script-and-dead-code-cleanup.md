# [BUILD] build.sh 도움말과 실제 옵션 불일치, pl_unittest의 빌드 디렉터리 전달 오류

**한 줄 요약**: CBRD-27539 후속 감사에서 찾은 빌드 관련 불일치 두 가지를 다룬다. `build.sh -h` 가 처리하지 않는 옵션과 틀린 기본값을 안내하는 문제, `pl_unittest` 타깃이 Gradle에 빌드 디렉터리를 잘못된 방식으로 넘기는 문제다. 처음에 함께 묶었던 3번(컴파일되지 않는 `wait_for_graph.c` 와 정의 없는 `catalog_destroy` 선언)은 담당 범위가 달라 Joon Min의 요청에 따라 CBRD-XXXXX로 분리했다.

## Issue Triage

**이슈 수행 목적**: 개발자가 신뢰하는 빌드 도움말과 빌드 타깃이 실제 동작과 일치하게 한다.

**이슈 수행 이유**:
1. `build.sh` usage는 `-i`(빌드 번호 증가)와 `-a`(autogen.sh 실행)를 안내한다. `getopts` 도 두 옵션을 받는다. 그런데 옵션 처리 `case` 에 해당 분기가 없어서, 두 옵션을 쓰면 usage를 출력하고 exit 1로 끝난다. `-b` 의 기본값 설명(`build_<mode>_<target>`)은 실제(`build_<target>_<mode>`)와 순서가 반대이고, `JAVA_HOME` 이 비었을 때 `-j` 의 기본값 설명(`/usr/java/default`)도 실제 기본값(`/usr/lib/jvm/java`)과 다르다.
2. `pl_engine/CMakeLists.txt` 의 `pl_build` 는 `-PbuildDir=`(Gradle 프로젝트 속성)를 넘기는데 `pl_unittest` 는 `-DbuildDir=`(JVM 시스템 속성)를 넘긴다. Gradle 빌드 스크립트는 이 시스템 속성을 읽지 않으므로 값이 무시되고, `pl_unittest` 는 CMake 빌드 디렉터리가 아니라 소스 트리 안의 `pl_engine/pl_server/build` 에서 다시 컴파일한다.

**영향**:
- 1은 도움말을 보고 `-i` 나 `-a` 를 고른 사용자의 빌드를 즉시 실패시킨다. 틀린 기본값 설명은 빌드 산출물 위치와 사용할 JDK를 잘못 알려 준다.
- 2는 CMake 빌드 결과와 다른 위치에서 테스트를 컴파일하므로 중복 빌드가 생기고 소스 트리에 산출물이 남는다. 그 산출물은 `pl_engine/.gitignore` 의 `build` 항목으로 가려져 눈에 띄지 않는다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

기준 소스: `CUBRID/cubrid` `origin/develop` `0eec910fc1`(2026-11-26). 처음 작성 기준인 `ca5c2153ed` 이후 아래 파일은 바뀌지 않았고, 행 번호도 같다.

### build.sh

- usage: `build.sh:502` `-i`, `:503` `-a`, `:508` `-b ... [default: <source path>/build_<mode>_<target>]`, `:512` `-j ... [default: /usr/java/default]`(`JAVA_HOME` 이 비었을 때).
- 처리: `build.sh:538` 의 `getopts ":t:m:g:is:b:p:o:aj:c:C:z:xvh"` 는 `i` 와 `a` 를 받는다. 그러나 `:539-564` 의 `case` 에는 `i` 나 `a` 분기가 없어서 `:563` 의 `h|\?|* ) show_usage; exit 1;;` 로 간다.
- 실제 기본값: `build.sh:585` `build_dir="$source_dir/build_${build_target}_${build_mode}"`, `build.sh:34` `default_java_dir="/usr/lib/jvm/java"`.

### pl_unittest

- `pl_engine/CMakeLists.txt:71,76`(`pl_build`, UNIX·Windows): `-PbuildDir=${PL_ENGINE_BUILD_DIR}`
- `pl_engine/CMakeLists.txt:83,87`(`pl_unittest`, UNIX·Windows): `-DbuildDir=${PL_ENGINE_BUILD_DIR}`

### ANALYSIS 확인 사항

1. `-i`, `-a` 를 구현할지 usage에서 지울지 정한다(빌드 번호와 autogen 단계가 지금도 필요한지).
2. `pl_unittest` 를 `-PbuildDir` 로 바꾸면 테스트 결과나 Windows 경로에 영향이 있는지 확인한다.

## Acceptance Criteria

- `build.sh -h` 가 안내하는 옵션은 모두 실제로 처리되고, 안내된 기본값은 실제 기본값과 같다.
- `pl_unittest` 는 `pl_build` 와 같은 빌드 디렉터리를 쓴다.

## Related

- CBRD-XXXXX: 이 이슈에서 분리한 3번(컴파일되지 않는 `wait_for_graph.c` 교착 그래프 코드와 정의 없는 `catalog_destroy` 선언 정리, transaction 범위)
- [CBRD-27539](https://jira.cubrid.org/browse/CBRD-27539): 에이전트 지침 감사 중 발견
