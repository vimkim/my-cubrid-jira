# [BUILD] Clang 빌드에서 발생하는 unknown warning option 및 -Wclobbered 호환성 문제 수정

## Description

### 배경

CUBRID 소스 트리를 Clang(`debug_clang` preset)으로 빌드할 때 GCC 전용 경고 옵션을 사용하는 `#pragma` 및 CMake 플래그로 인해 다수의 `-Wunknown-warning-option` 경고가 발생하고 있음.

현재 `debug_clang` preset으로 빌드하면 다음과 같이 17건의 `-Wunknown-warning-option` 경고가 출력됨 (유니크 4건):

```
build_preset_debug_clang/csql_grammar.c:481:1: warning: unknown warning group '-Wimplicit-fallthrough=', ignored
build_preset_debug_clang/csql_lexer.c:3191:1:  warning: unknown warning group '-Wimplicit-fallthrough=', ignored
build_preset_debug_clang/load_lexer.cpp:758:1: warning: unknown warning group '-Wimplicit-fallthrough=', ignored
src/broker/broker_shm.c:613:32:                warning: unknown warning group '-Wrestrict', ignored
```

추가로 CMake 전역 플래그에 있는 `-Wclobbered` 역시 Clang에서는 존재하지 않는 경고라 build cache 구성에 따라 `-Wunknown-warning-option` 을 유발함.

### 목적

- Clang 빌드 경고 잡음 감소 및 `-Wunknown-warning-option` 완전 제거.
- GCC/Clang 양쪽 모두에서 깨끗하게 빌드되도록 컴파일러별 경고 옵션을 올바르게 분기.
- Bison/Flex 자동 생성 코드의 pragma가 두 컴파일러에서 모두 유효하도록 수정.

---

## Analysis

### 원인

1. **`-Wimplicit-fallthrough=`** (뒤에 `=` 가 붙음)
   - GCC 전용 확장 문법으로, GCC에서는 `-Wimplicit-fallthrough=N` 형태의 level 지정이 가능하지만 level 없이 `=` 만 쓰는 것은 GCC에서도 비정식 표기임.
   - Clang은 `-Wimplicit-fallthrough` (접미사 없음)만 인식.
   - GCC 역시 `-Wimplicit-fallthrough` (접미사 없음)을 허용하며 기본 level 3과 동일하게 동작.
   - 따라서 `=` 접미사를 제거하면 GCC/Clang 양쪽에서 유효.
2. **`-Wrestrict`**
   - GCC 전용 경고로 Clang에는 존재하지 않음.
   - 현재 `src/broker/broker_shm.c:613` 의 pragma는 컴파일러 가드가 없어 Clang에서 경고 발생.
3. **`-Wclobbered`**
   - GCC 전용 경고 (`setjmp`/`longjmp` 시 지역 변수 clobber 탐지).
   - `CMakeLists.txt` 의 전역 `CMAKE_C_FLAGS`/`CMAKE_CXX_FLAGS` 에 무조건 추가되어 있어 Clang 빌드에서 경고 발생.

### 관련 파일

| 파일 | 위치 | 내용 |
|------|------|------|
| `src/parser/csql_grammar.y` | L528 | `_Pragma("GCC diagnostic ignored \"-Wimplicit-fallthrough=\"")` |
| `src/parser/csql_lexer.l` | L87 | 동일 |
| `src/loaddb/load_lexer.l` | L62 | 동일 |
| `src/broker/broker_shm.c` | L612–L616 | `#pragma GCC diagnostic ignored "-Wrestrict"` (가드 없음) |
| `CMakeLists.txt` | L603–L608 | `-Wclobbered` 무조건 추가 |

---

## Implementation

### 1. `-Wimplicit-fallthrough=` → `-Wimplicit-fallthrough`

Bison/Flex 입력 파일 3개에서 `=` 접미사를 제거.

```diff
- _Pragma("GCC diagnostic ignored \"-Wimplicit-fallthrough=\"")
+ _Pragma("GCC diagnostic ignored \"-Wimplicit-fallthrough\"")
```

적용 대상:

- `src/parser/csql_grammar.y`
- `src/parser/csql_lexer.l`
- `src/loaddb/load_lexer.l`

### 2. `-Wrestrict` pragma 를 GCC-only 로 가드

`src/broker/broker_shm.c` 의 `strcpy` 블록을 `__GNUC__ && !__clang__` 로 가드:

```c
#if defined(__GNUC__) && !defined(__clang__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wrestrict"
#endif
          strcpy (as_info_p->database_user, shard_conn_info_p->db_user);
          strcpy (as_info_p->database_passwd, shard_conn_info_p->db_password);
#if defined(__GNUC__) && !defined(__clang__)
#pragma GCC diagnostic pop
#endif
```

### 3. `-Wclobbered` 를 CMake 에서 GCC 전용으로 분기

`CMakeLists.txt` 의 Linux 블록에서 `-Wclobbered` 를 기본 플래그 집합에서 제거하고 `CMAKE_C_COMPILER_ID`/`CMAKE_CXX_COMPILER_ID` 가 `GNU` 일 때만 추가:

```cmake
# -Wclobbered is a GCC-only warning; Clang does not recognize it.
if(CMAKE_C_COMPILER_ID STREQUAL "GNU")
  set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -Wclobbered")
endif()
if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
  set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wclobbered")
endif()
```

### 4. 부수 수정

동일 브랜치에 다음 경미한 수정 포함:

- `src/broker/broker_monitor.c`: 구식 `<termio.h>` → 표준 `<termios.h>` 로 교체 (glibc 최신 헤더 정리 흐름과 일치).
- `src/executables/csql.c`: `csql_Is_echo_on` 기본값을 `false` → `true` 로 변경 (인터랙티브 세션 가시성 향상 목적; 별도 검토 필요 시 분리 가능).

---

## Acceptance Criteria

- [ ] `cmake --preset debug_clang && cmake --build --preset debug_clang` 수행 시 `-Wunknown-warning-option` 경고가 0건.
- [ ] `cmake --preset debug` (GCC) 빌드가 기존과 동일하게 `-Wclobbered` 경고/에러 동작을 유지.
- [ ] `-Wimplicit-fallthrough` pragma 가 GCC/Clang 양쪽에서 정상적으로 억제되어 bison/flex 생성 코드에서 fallthrough 경고가 발생하지 않음.
- [ ] `src/broker/broker_shm.c` 의 `strcpy` 블록이 GCC 에서는 `-Wrestrict` 경고를 계속 억제, Clang 에서는 pragma 자체가 비활성.
- [ ] 기존 shell/SQL 테스트가 모두 통과.

---

## Remarks

- 검증: 로컬에서 `cmake --build --preset debug_clang` 재빌드 후 `-Wunknown-warning-option` 17 → 0 확인됨.
- `termio.h → termios.h` 변경은 엄밀히 경고 수정과 무관하지만, 최신 glibc/커널 헤더에서 `<termio.h>` 는 deprecated 이므로 함께 반영.
- `csql_Is_echo_on` 기본값 변경은 행동 변경이므로, 리뷰 단계에서 필요하면 별도 PR/티켓으로 분리.
- 후속 작업 후보: 현재 `debug_clang` 빌드에서 가장 빈도 높은 경고 (`-Wgnu-null-pointer-arithmetic` 120건, `-Wenum-conversion` 50건, `-Wmissing-field-initializers` 45건) 에 대한 정리.
