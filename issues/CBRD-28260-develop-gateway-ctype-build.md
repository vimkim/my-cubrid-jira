# [BUILD] develop에서 ODBC 게이트웨이의 toupper·tolower 선언 누락으로 빌드 실패

**한 줄 요약**: [PR #7723](https://github.com/CUBRID/cubrid/pull/7723)에서 추가한 ODBC 식별자 변환 코드가 `toupper()`와 `tolower()`의 선언 없이 컴파일되어 GCC와 Clang 빌드가 실패한다.

## Issue Triage

**이슈 수행 목적**: Linux에서 GCC와 Clang으로 CUBRID ODBC 게이트웨이의 소스를 컴파일한다.

**이슈 수행 이유**: develop `9ca709eef327be1784d0cb4d5611ac6f4196fc2f`의 `cas_cgw_odbc.c`에서 두 함수의 선언 누락을 재현했다.

**영향**: ODBC 게이트웨이를 포함하는 빌드는 이 소스 파일의 오브젝트를 생성하지 못한다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

`cgw_fold_identifier()`는 ODBC 드라이버가 보고한 대소문자 규칙에 따라 식별자를 변환한다. 이 함수가 호출하는 `toupper()`와 `tolower()`는 `<ctype.h>`에 선언되어 있다. PR #7723은 두 호출을 추가했으며, 현재 소스의 기존 헤더를 포함한 상태에서 두 컴파일러 모두 해당 선언을 찾지 못했다. [호출부](https://github.com/CUBRID/cubrid/blob/9ca709eef327be1784d0cb4d5611ac6f4196fc2f/src/broker/cas_cgw_odbc.c#L1880-L1897)

## Test Build

- 기준 커밋은 [develop `9ca709eef3`](https://github.com/CUBRID/cubrid/commit/9ca709eef327be1784d0cb4d5611ac6f4196fc2f)이다.
- Rocky Linux 9.6 x86_64, CMake 3.26.5, Ninja 1.10.2에서 `RelWithDebInfo` 구성으로 검사했다.
- GCC 11.5.0 및 Clang 23.1.5에서 CMake가 생성한 `cas_cgw_odbc.c`의 C++ 컴파일 명령을 각각 실행했다.

## Repro

기준 커밋에서 CCI 및 JDBC 서브모듈을 초기화한다. 아래 예시는 GCC로 재현할 때의 프로젝트 CMake 명령이다. Clang으로 같은 소스를 확인하려면 새 빌드 디렉터리를 사용해 `CC=clang CXX=clang++`으로 구성하고, 선행 대상에서 멈출 경우 `compile_commands.json`의 `broker/CMakeFiles/cas_cgw_lib.dir` 항목에서 `cas_cgw_odbc.c` 컴파일 명령을 실행한다.

```sh
git submodule update --init cubrid-cci cubrid-jdbc
CC=gcc CXX=g++ cmake --preset release -B build-gcc
cmake --build build-gcc --target cas_cgw_lib
```

## Actual Result

```text
GCC:   cas_cgw_odbc.c:1890:27: error: 'toupper' was not declared in this scope
GCC:   cas_cgw_odbc.c:1894:27: error: 'tolower' was not declared in this scope
Clang: cas_cgw_odbc.c:1890:20: error: use of undeclared identifier 'toupper'
Clang: cas_cgw_odbc.c:1894:20: error: use of undeclared identifier 'tolower'
```

동일한 컴파일 명령에 `-include ctype.h`만 추가하면 두 컴파일러 모두 해당 소스의 오브젝트를 생성했다.

## Expected Result

GCC와 Clang의 기본 빌드에서 `cas_cgw_odbc.c`를 컴파일할 수 있다.
