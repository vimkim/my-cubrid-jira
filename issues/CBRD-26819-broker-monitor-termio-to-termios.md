# [BUILD] broker_monitor.c 의 `<termio.h>` 를 POSIX 표준 `<termios.h>` 로 교체

## Issue Triage

**이슈 수행 목적**: `src/broker/broker_monitor.c` 가 모던 libc (glibc 2.42+, musl) 환경에서도 빌드되도록, 레거시 System V 헤더 `<termio.h>` 의존을 POSIX 표준 `<termios.h>` 로 교체한다.

**이슈 수행 이유**:

- **현재 동작 / 배경**: `src/broker/broker_monitor.c:52` 가 `#include <termio.h>` 를 사용한다. 그러나 같은 파일이 실제로 끌어다 쓰는 심볼은 `struct termios` (line 390, 2139), `tcgetattr` (line 2141), `tcsetattr` (line 2031, 2156) — 모두 POSIX 표준 `<termios.h>` 에 정의된 인터페이스다. `<termio.h>` 자체는 System V 시절의 레거시 헤더로 POSIX.1 (1988) 이 등장하면서 obsolete 로 분류돼 왔고, glibc 는 후방 호환 shim 으로만 유지해 왔다.
- **영향**: glibc 2.42 (2025-07 릴리스) 가 `<termio.h>` 와 `<sys/ioctl.h>` 의 `struct termio` 정의를 완전히 제거했다. 결과적으로 Arch Linux (rolling, glibc 2.42+), Fedora 42+, Debian trixie+, musl 기반 Alpine 등 모던 개발 환경에서 `./build.sh` 가 `fatal error: termio.h: No such file or directory` 로 끊긴다. 공식 CI (Rocky 8 + glibc 2.28) 는 영향이 없으나, 개발자가 로컬에서 빌드를 시도하지 못해 기여 장벽이 된다.

**이슈 수행 방안**:

- `src/broker/broker_monitor.c:52` 의 `#include <termio.h>` 를 `#include <termios.h>` 로 1:1 교체한다.
- 동작 / ABI 변경 없음. 파일이 헤더에서 사용하는 심볼은 모두 `<termios.h>` 에 그대로 정의돼 있어 컴파일러가 보는 선언이 동일하다.
- 본 이슈는 [CBRD-26809] (`identifier_store.hpp` 에 `<string>` 누락 include 추가) 의 follow-up 이다. 두 변경 모두 "모던 툴체인에서 self-contained 하지 않은 헤더 의존 때문에 빌드가 끊긴다" 는 동일 패턴이라 처음에는 한 PR 로 묶었으나, 리뷰어 피드백("두 변경은 서로 무관한 drive-by 다")에 따라 본 이슈로 분리한다.

---

## AI-Generated Context

> 아래 내용은 AI 가 코드/맥락을 분석해 작성한 상세 자료입니다. 빠른 triage 에는 위 **Issue Triage** 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하시면 됩니다.

### Summary

- **문제**: `broker_monitor.c` 가 비표준 레거시 헤더 `<termio.h>` 에 의존.
- **원인**: System V 시절 관행이 남아 있던 코드. glibc 가 호환 shim 으로 오래 유지해 와서 드러나지 않았다.
- **변경**: 한 줄 헤더 교체 (`<termio.h>` -> `<termios.h>`).
- **영향 범위**: 빌드 portability. 동작 / ABI / 성능 변화 없음. CUBRID 트리에서 `<termio.h>` 를 직접 include 하는 다른 파일은 없다 (`grep -rn 'termio.h' src/` 가 본 파일 한 곳만 매치).

## Description

`<termio.h>` 는 System V 시절의 레거시 인터페이스 헤더로, `struct termio` 와 ioctl 기반 터미널 제어를 위한 것이었다. POSIX.1 (1988) 이 등장하며 `<termios.h>` 와 `struct termios` 가 표준으로 자리잡아 `<termio.h>` 는 obsolete 로 분류됐다.

glibc 는 후방 호환을 위해 `<termio.h>` 를 사실상 `<termios.h>` 의 얇은 wrapper 로 유지해 왔으나, 2025-07 릴리스된 **glibc 2.42** 에서 `<termio.h>` 와 `<sys/ioctl.h>` 의 `struct termio` 정의를 함께 제거했다. musl libc 는 처음부터 `<termio.h>` 를 제공한 적이 없다.

`broker_monitor.c` 는 이 헤더에서 실제로는 POSIX API 만 사용한다 — `struct termios`, `tcgetattr`, `tcsetattr`. 즉 처음부터 `<termios.h>` 만 포함했어야 옳다.

해당 include 는 `#if defined(WINDOWS)` / `#else` 분기의 비(非)-Windows 쪽에만 있으므로 (`broker_monitor.c:45-54` 근처), 본 변경은 Linux/Unix 빌드에만 영향을 준다. Windows 빌드 경로는 `<conio.h>` 등을 사용하므로 영향 밖이다.

## Test Build

- **통과 (현재)**: Rocky 8 + devtoolset-8 (GCC 8) + glibc 2.28 — 공식 CI. `<termio.h>` 가 호환 shim 으로 남아 있다.
- **실패 (현재)**: Arch Linux (rolling, glibc 2.42+), Fedora 42+, Debian trixie+, Alpine (musl). `fatal error: termio.h: No such file or directory` 로 컴파일 중단.
- **통과 (수정 후)**: 위 두 환경 모두 빌드 성공 예상. `<termios.h>` 는 모든 모던 libc 에 존재.

## Repro

modern libc 환경 (예: Arch Linux, 또는 glibc 2.42+ 인 어떤 배포판이든) 에서:

```bash
./build.sh -m debug
```

다음 컴파일 오류로 빌드 중단:

```
src/broker/broker_monitor.c:52:10: fatal error: termio.h: No such file or directory
   52 | #include <termio.h>
      |          ^~~~~~~~~~
compilation terminated.
```

## Expected Result

`broker_monitor.c` 가 모던 libc (glibc 2.42+, musl) 환경에서도 빌드 성공한다.

## Actual Result

수정 전 상태에서 glibc 2.42+ / musl 환경의 빌드가 `termio.h: No such file or directory` 로 실패한다.

## Additional Information

- **glibc 2.42 release announcement**: <https://lists.gnu.org/archive/html/info-gnu/2025-07/msg00011.html>
- **glibc upstream commit removing `<termio.h>`**: <https://sourceware.org/pipermail/glibc-cvs/2025q2/088038.html>
- **관련 Debian FTBFS 사례**: #1115213 (sredird), #1115215 (xtel), #1124068 (missing termio.h header)
- **CUBRID 내 다른 사용처**: 없음. `grep -rn 'termio.h' src/` 가 본 파일 한 곳만 매치.

## Remarks

- **선행 이슈**: [CBRD-26809] (`identifier_store.hpp` 에 `<string>` 누락 include 추가). 같은 "모던 툴체인에서 self-contained 하지 않은 헤더 의존" 카테고리지만, 모듈·원인이 달라 리뷰어 요청대로 분리.
- **범위 밖**: 다른 모듈의 IWYU (include-what-you-use) 점검은 본 이슈 범위 밖.
- **PR**: 분리된 단일 commit 으로 별도 PR 예정.
