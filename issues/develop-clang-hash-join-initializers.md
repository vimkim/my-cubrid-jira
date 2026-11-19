# [BUILD] Clang 최적화 빌드에서 해시 조인 구조체 초기화 경고로 컴파일 실패

**한 줄 요약**: develop을 Clang으로 `RelWithDebInfo` 빌드하면 `query_hash_join.c`의 구조체 초기화 경고 두 건이 `-Werror`로 처리되어 컴파일이 중단된다.

## Issue Triage

**이슈 수행 목적**: Clang 최적화 빌드에서 경고 설정을 유지하면서 해시 조인 소스를 컴파일한다.

**이슈 수행 이유**: develop `9ca709eef327be1784d0cb4d5611ac6f4196fc2f`의 전체 빌드에서 `-Wmissing-field-initializers` 오류 두 건을 재현했다.

**영향**: 확인한 Linux Clang 구성에서 `cubridsa` 빌드가 중단된다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

`QFILE_TUPLE_VALUE_TYPE_LIST merge_type_list`와 `QFILE_TUPLE_RECORD tr`의 초기화 목록은 각각 앞의 두 멤버만 명시한다. Linux 최적화 빌드에는 프로젝트가 `-Wextra`와 `-Werror`를 설정한다. Clang은 목록에서 생략한 첫 멤버인 `column_layout_array`와 `type_list`를 진단한다. [CMake 옵션](https://github.com/CUBRID/cubrid/blob/9ca709eef327be1784d0cb4d5611ac6f4196fc2f/CMakeLists.txt#L619-L631)

## Test Build

- 기준 커밋은 [develop `9ca709eef3`](https://github.com/CUBRID/cubrid/commit/9ca709eef327be1784d0cb4d5611ac6f4196fc2f)이다.
- Rocky Linux 9.6 x86_64, CMake 3.26.5, Ninja 1.10.2에서 Clang 23.1.5의 `RelWithDebInfo` 전체 빌드를 실행했다.
- 같은 C++ 컴파일 명령을 Clang 19.1.7로도 실행해 동일한 두 오류를 확인했다.

## Repro

기준 커밋에서 프로젝트 CMake 구성으로 Standalone 라이브러리 대상을 빌드한다. 이 명령은 로컬 검증에서 사용한 컴파일러와 빌드 유형을 지정한다.

```sh
git submodule update --init cubrid-cci cubrid-jdbc
CC=clang CXX=clang++ cmake --preset release -B build-clang
cmake --build build-clang --target cubridsa
```

## Actual Result

```text
query_hash_join.c:1013:59: error: missing field 'column_layout_array' initializer [-Werror,-Wmissing-field-initializers]
query_hash_join.c:4681:37: error: missing field 'type_list' initializer [-Werror,-Wmissing-field-initializers]
```

## Expected Result

두 초기화가 각 구조체의 의도된 초기 상태를 보존하고, `query_hash_join.c`가 기존 경고 설정으로 컴파일된다.
