# [BUILD] identifier_store.hpp 누락된 `<string>` 헤더로 인한 빌드 실패

## Issue Triage

**이슈 수행 목적**: `src/object/identifier_store.hpp` 가 `std::string` 을 자체 include 없이 사용하는 자기-모순 상태를 해소한다.

**이슈 수행 이유**:

- **현재 동작 / 배경**: `identifier_store.hpp:35` 가 `const std::string SYSTEM_CLASS_PREFIX = "_db";` 를 선언하지만 직접 include 는 `<string_view>` 뿐이다 (line 27). `std::string` 정의는 `string_utility.hpp` 가 끌어들이는 `<string>` 전이 경로에만 의존한다.
- **영향**: Rocky 8 + GCC 8 공식 CI 에서는 전이 경로가 살아 있어 통과하지만, 모던 툴체인(GCC 13+, Clang 17+, 최신 libstdc++/libc++, clangd/clang-tidy)에서는 표준 헤더가 더 엄격히 정리되어 `error: 'string' in namespace 'std' does not name a type` 가 `line 35` 에서 발생한다.

**이슈 수행 방안**: `#include <string_view>` 를 `#include <string>` 로 교체. libstdc++ 의 `<string>` 이 변환 생성자를 위해 `<string_view>` 를 전이 제공하므로 기존 `std::string_view` 시그니처는 그대로 유지된다.

---

## AI-Generated Context

### Description

`<string_view>` 는 `<string>` 을 포함하지 않는다(의존 방향은 반대). 따라서 `std::string` 식별자가 컴파일되어 온 것은 `"string_utility.hpp"` 안쪽의 `<string>` 전이 include 덕분이다. 최신 stdlib 는 헤더간 의존을 더 좁게 가져가도록 정리되어 이 전이 경로가 끊긴다.

## Test Build

- 통과: Rocky 8 + devtoolset-8 (GCC 8) + 구버전 libstdc++ — 공식 CI.
- 실패(수정 전): GCC 13+ / Clang 17+ + 최신 libstdc++/libc++, clangd / clang-tidy.

## Repro

수정 전 commit 으로 체크아웃 후 모던 툴체인에서 빌드하면:

```
src/object/identifier_store.hpp:35:13: error:
    'string' in namespace 'std' does not name a type
   35 |   const std::string SYSTEM_CLASS_PREFIX = "_db";
      |             ^~~~~~
```

## Expected Result

`identifier_store.hpp` 가 self-contained 하다. 어느 툴체인에서도 빌드 통과.

## Actual Result

수정 전 상태에서 모던 툴체인에서 위 오류로 빌드 실패.

## Drive-by fix: `<termio.h>` → `<termios.h>`

같은 PR 안에서 `src/broker/broker_monitor.c` 의 `#include <termio.h>` 를 `#include <termios.h>` 로 함께 교체했다.

- **이유**: `<termio.h>` 는 System V 시절의 레거시 헤더이며, POSIX 표준 헤더는 `<termios.h>` 다. glibc 2.34+ 및 musl 등 모던 libc 환경에서는 `<termio.h>` 가 제거되었거나 deprecated 로 처리되어, 모던 컴파일러에서 `fatal error: termio.h: No such file or directory` 가 발생한다.
- **호환성**: 해당 파일은 이 헤더에서 `struct termios` / `tcgetattr` / `tcsetattr` 류 POSIX API 만 사용하므로 1:1 치환 가능. 동작·ABI 변경 없음.
- **commit**: `88763d421` ("fix: rename termio to termios, a modern name").

## Remarks

- PR: branch `fix-identifier-include-error`, commit `f53d09dc2` (identifier_store), `88763d421` (termio→termios).
- 동일 패턴 점검(IWYU 등)은 본 이슈 범위 밖.
