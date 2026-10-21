# [BUILD] broker_monitor.c의 `<termio.h>` 의존으로 발생하는 빌드 실패 해결

## Issue Triage

**이슈 수행 목적**: `<termio.h>`를 제공하지 않는 Linux 개발 환경에서도 `broker_monitor.c`의 터미널 제어 코드를 컴파일할 수 있도록 빌드 호환성을 확보한다. Ubuntu 26.04와 Fedora 등 최신 glibc를 사용하는 환경에서 구버전 빌드 환경으로 우회해야 하는 제약을 줄이고 CUBRID 소스 빌드와 개발을 쉽게 한다.

**이슈 수행 이유**: `broker_monitor.c`는 `struct termios`, `tcgetattr`, `tcsetattr`를 사용하면서 `<termio.h>`를 포함한다. glibc 2.42에서 이 호환 헤더가 제거되었으므로, 해당 헤더를 제공하지 않는 환경에서는 실제 터미널 API 사용 여부와 관계없이 전처리 단계에서 빌드가 차단된다. 기존 이슈에 빌드 실패가 보고되어 있으며, 현재 develop 소스에도 같은 의존이 남아 있음을 확인한다.

**영향**: 해당 환경에서 CUBRID를 소스 빌드하는 개발자와 패키지 관리자가 영향을 받는다. `broker_monitor`와 `gateway_monitor`가 같은 소스를 사용하므로 두 대상의 빌드 경로가 관련된다. 배포판별 실제 재현 여부, 영향받는 CUBRID 릴리스, 발생 빈도는 미확인이다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

> 아래는 기존 이슈와 확인한 소스 및 외부 근거를 바탕으로 작성한 상세 맥락이다. 기존 보고, 직접 확인한 사실, 미확인 사항을 구분한다.

## Description

### 무엇이 문제인가

브로커 모니터는 터미널 입력 모드를 설정하고 종료할 때 원래 설정을 복원한다. 확인한 develop 커밋 `f6cac312310f39f46711693da157a08f0e725693`에서 `src/broker/broker_monitor.c:52`는 비 Windows 분기에서 `<termio.h>`를 포함한다. 반면 실제 터미널 설정에는 `struct termios`와 `tcgetattr`, `tcsetattr`를 사용한다. 관련 위치는 전역 설정 보관부 405행, 복원 함수 `endwin` 2123행, 설정 함수 `tty_noblock` 2231-2248행이다.

기존 glibc의 `<termio.h>`는 `<termios.h>`와 `<sys/ioctl.h>`를 포함하는 호환 헤더였다. 따라서 기존 환경에서는 이 경유 경로로 필요한 선언을 얻을 수 있었다. 그러나 [glibc 2.42 NEWS](https://github.com/bminor/glibc/blob/glibc-2.42/NEWS#L53-L61)에는 Linux에서 `<termio.h>`와 `<sys/ioctl.h>`의 `struct termio` 정의를 제거했다고 명시되어 있다. [제거 커밋](https://sourceware.org/pipermail/glibc-cvs/2025q2/088038.html)에서도 해당 헤더 파일과 설치 목록의 삭제를 확인한다.

문제는 터미널 제어 API 자체의 부재가 아니라, 사용 중인 API의 선언을 얻기 위해 제거된 호환 헤더를 요구한다는 점이다. 이 헤더가 없는 환경에서는 `broker_monitor.c`를 컴파일할 수 없다. 필요한 상태는 기존 터미널 제어 기능을 유지하면서 해당 호환 헤더 없이도 관련 소스를 컴파일하는 것이다.

### 왜 문제인가

이 오류는 실행 중 특정 모니터 기능을 선택했을 때 발생하는 문제가 아니다. 소스를 컴파일하는 단계에서 헤더를 찾지 못하므로, 해당 빌드 대상이 포함된 빌드는 결과물을 만들기 전에 중단된다. 그 환경에서 CUBRID를 개발하거나 패키징하려는 사용자는 소스를 별도로 수정하거나 다른 빌드 환경을 마련해야 한다.

`broker/CMakeLists.txt:78-99,113-125`에서는 `broker_monitor.c`를 공통 소스 목록에 넣고 `LANGUAGE CXX`로 지정하여 컴파일하며, 이 목록으로 `broker_monitor`와 `gateway_monitor`를 생성한다. 따라서 파일명만 보고 브로커 모니터 한 대상에만 영향이 있다고 한정할 수 없다. 두 대상의 실제 실패 로그와 전체 빌드에 미치는 결과는 ANALYSIS에서 확인한다.

기존 이슈는 여러 배포판과 musl 환경을 실패 환경으로 나열했으나, 정확한 패키지 버전과 CUBRID 빌드 로그를 제시하지 않았다. 따라서 모든 해당 환경의 실패를 검증된 결과로 보지 않는다. 소스와 glibc 변경 기록으로 확인한 것은 `<termio.h>` 미제공 환경에서 발생하는 빌드 장애 조건이다. 운영 중인 DB의 장애나 데이터 손실을 보여주는 근거는 없다.

### 왜 해결해야 하는가

현재 의존이 남아 있으면 개발자가 다른 빌드 요구사항을 갖추더라도 이 헤더가 없는 환경에서는 관련 빌드 대상을 생성할 수 없다. 라이브러리의 폐기된 호환 헤더 제공 여부가 소스 빌드 가능 여부를 결정하게 되므로, 환경 갱신이나 패키지 유지보수 시 같은 우회 작업이 반복될 수 있다.

기존 환경이나 별도의 빌드 컨테이너를 사용하는 것은 우회 수단이 될 수 있으나, 대상 환경에서 직접 빌드해야 하는 요구를 충족하지 못하며 추가 환경 관리가 필요하다. 환경마다 임의의 호환 헤더를 배치하는 방법도 프로젝트가 요구하는 선언과 검증 범위를 명확히 하지 못한다. 해결 후에는 이 헤더의 유무 때문에 빌드가 차단되지 않아야 하며, 기존 환경에서 모니터의 입력 처리와 터미널 설정 복원이 유지되어야 한다.

glibc의 제거가 이미 릴리스에 반영되었고 현재 확인한 소스에도 의존이 남아 있다는 점이 분석 착수 근거다. 다만 고객 영향 규모나 납기 근거는 없으므로 긴급도와 우선순위는 별도로 판단한다.

### 최신 개발 환경에서의 기대 효과

Ubuntu 26.04와 Fedora 등 최신 glibc를 사용하는 개발 환경에서도, 이 헤더 문제 때문에 별도의 구버전 OS나 빌드 컨테이너로 옮기지 않고 CUBRID 소스 빌드를 진행할 수 있도록 하는 것이 장점이다. 개발자가 평소 사용하는 환경에서 코드 수정, 빌드와 검증을 이어갈 수 있어 환경 준비 비용과 외부 기여의 진입 장벽을 줄일 수 있다. 패키지 관리자에게도 배포판별 임시 헤더나 별도 소스 패치를 관리할 필요를 줄이는 효과가 있다.

2026-10-21에 확인한 공식 자료의 환경 예시는 다음과 같다. 표의 버전은 배포판이 제공하는 glibc 버전이며, CUBRID 전체 빌드 성공을 검증한 목록은 아니다.

| 개발 환경 예시 | glibc 버전 | 확인 근거 |
|---|---|---|
| Ubuntu 26.04 LTS | 2.43 | [Ubuntu 공식 릴리스 노트](https://documentation.ubuntu.com/release-notes/26.04/changes-since-previous-interim/) |
| Fedora 43 | 2.42 | [Fedora 공식 패키지 목록](https://packages.fedoraproject.org/pkgs/glibc/glibc/) |
| Fedora 44 | 2.43 | [Fedora 개발 헤더 패키지](https://packages.fedoraproject.org/pkgs/glibc/glibc-devel/fedora-44.html) |
| Fedora 45 | 2.44 | [Fedora 개발 헤더 패키지](https://packages.fedoraproject.org/pkgs/glibc/glibc-devel/fedora-45.html) |

이 기대 효과는 기존 빌드 요구사항과 다른 소스의 호환성 문제도 해결되어 있다는 전제에서 평가한다. 본 변경이 제거하는 것은 터미널 호환 헤더에 따른 장애이며, 각 환경에서 CUBRID 전체 빌드가 성공하는지는 별도 실행으로 확인한다.

### glibc 버전 범위의 해석

`<termios.h>`로 교체한다고 해서 최소 glibc 버전이 2.42로 올라가지는 않는다. [glibc 2.28의 헤더](https://github.com/bminor/glibc/blob/glibc-2.28/termios/termios.h)에도 `struct termios` 관련 정의의 포함과 `tcgetattr`, `tcsetattr` 선언이 있으며, 이번 확인 환경인 glibc 2.34에서는 해당 API를 사용하는 구문 검사가 성공하였다. [glibc 2.42의 헤더](https://github.com/bminor/glibc/blob/glibc-2.42/termios/termios.h)에도 이 인터페이스가 유지된다. 따라서 기존 환경의 인터페이스를 유지하면서 glibc 2.42부터 발생한 호환 헤더 제거에 대응하는 방향이다.

이 근거로 CUBRID 전체의 빌드 가능 범위를 “glibc 2.28부터 2.44까지”로 확정하지는 않는다. 2.28은 소스에서 API를 확인한 기존 버전의 예시이고, 2.44는 위 배포판 예시의 glibc 버전이다. 실제 최소 버전, 검증된 최신 버전, 아키텍처별 차이는 CUBRID 전체 소스와 의존 라이브러리의 빌드 검증으로 결정한다. 또한 특정 CUBRID 릴리스에 이 수정이 포함되거나 적용되기 전까지 그 릴리스의 호환성이 자동으로 바뀌지는 않는다.

## Test Build

| 구분 | 환경 또는 기준 | 확인 결과와 한계 |
|---|---|---|
| 소스 확인 | develop `f6cac312310f39f46711693da157a08f0e725693` | `<termio.h>` 의존과 공통 빌드 대상 구성을 확인하였다. 이 커밋의 전체 빌드는 미실행이다. |
| 이번 확인 환경 | Rocky Linux 9.6, glibc 2.34, GCC 11.5.0 | `<termio.h>`만 포함한 코드와 `<termios.h>`로 사용 API를 선언한 코드의 구문 검사가 각각 성공한다. CUBRID 전체 빌드나 수정 후 검증 결과가 아니다. |
| 기존 실패 보고 | glibc 2.42 이상 및 일부 배포판, musl 환경 | 기존 이슈에 실패 주장이 있다. 전체 빌드 버전, 커밋, OS와 개발 헤더 패키지 버전, 원본 로그는 TBD다. 이번 작성에서는 독립 재현하지 않았다. |
| 릴리스 영향 | 이전에 릴리스된 CUBRID 버전 | TBD - 소스 기준만으로 영향을 확정하지 않고 버전별로 확인한다. |

## Repro

### 재현 전제

아래는 ANALYSIS에서 실행할 제안 절차이며, 해당 환경에서 실행한 CUBRID 재현 기록이 아니다. Linux에서 `<termio.h>`는 없고 `<termios.h>`는 제공되는 개발 환경이 필요하다. glibc 2.42는 upstream에서 헤더를 제거한 기준이며, 실제 배포판의 개발 헤더 패키지와 추가 호환 패키지 유무도 기록한다.

전체 빌드에는 [확인 커밋의 빌드 요구사항](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/docs/install_build_requirements.md)과 [3rdparty 준비 조건](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/3rdparty/README.md)을 충족해야 한다. 실패 환경의 정확한 패키지 목록과 준비 기록은 TBD다.

### 헤더 제공 여부 확인

환경 정보와 컴파일러를 기록한 뒤 두 구문 검사를 각각 실행한다.

```sh
cat /etc/os-release
getconf GNU_LIBC_VERSION
c++ --version

c++ -x c++ -fsyntax-only - <<'CPP'
#include <termio.h>
CPP

c++ -x c++ -fsyntax-only - <<'CPP'
#include <termios.h>
int probe(int fd)
{
  struct termios term;
  if (tcgetattr(fd, &term) < 0) return -1;
  term.c_iflag &= ~(BRKINT | INPCK | ISTRIP | IXON);
  term.c_cflag |= CS8;
  term.c_lflag &= ~(ECHO | ICANON | IEXTEN | ISIG);
  term.c_cc[VMIN] = 0;
  term.c_cc[VTIME] = 8;
  return tcsetattr(fd, TCSAFLUSH, &term);
}
CPP
```

이슈의 장애 조건에 해당하는 환경에서는 첫 검사가 헤더 부재로 실패하고 두 번째 검사는 성공해야 한다. 이번 확인 환경인 glibc 2.34에서는 두 검사 모두 성공한다. 이 검사는 헤더와 선언의 가용성만 판별하며 CUBRID 빌드를 대신하지 않는다.

### CUBRID 빌드 확인

빌드 요구사항을 준비한 새 작업 디렉터리에서 다음을 실행하고, 전체 출력과 종료 코드를 보존한다.

```sh
git clone --recursive https://github.com/CUBRID/cubrid.git cubrid-cbrd-26819
cd cubrid-cbrd-26819
git checkout f6cac312310f39f46711693da157a08f0e725693
git submodule update --init --recursive
./build.sh -m debug build
```

앞선 의존성 오류로 중단된다면 그 결과만으로 본 이슈를 재현했다고 판단하지 않는다. `broker_monitor.c` 컴파일이 실제로 시도되었는지와 헤더 부재 진단을 확인한다.

## Expected Result

`<termio.h>`를 제공하지 않고 필요한 POSIX 터미널 인터페이스를 제공하는 대상 Linux 환경에서 `broker_monitor.c`의 헤더 의존 때문에 빌드가 실패하지 않아야 한다. 이를 사용하는 `broker_monitor`와 `gateway_monitor`의 빌드 결과를 확인한다.

Ubuntu 26.04와 Fedora 등 최신 glibc 환경을 검증 후보로 포함하고, 이 헤더를 보충하거나 이 문제 때문에 구버전 환경으로 전환할 필요가 없어졌는지 확인한다. 전체 빌드 결과와 이 헤더 문제의 해소 여부를 함께 기록한다.

기존 빌드 환경에서도 컴파일이 유지되고, 모니터의 터미널 입력 설정과 종료 시 복원 동작이 유지되어야 한다. 검증할 환경 조합과 상세 실행 절차는 ANALYSIS에서 확정한다. 이 이슈 하나로 해당 환경의 모든 CUBRID 빌드 문제 해결이나 새 플랫폼의 공식 지원을 보장하지 않는다.

## Actual Result

기존 이슈는 다음 진단으로 CUBRID 빌드가 중단된다고 보고한다. 아래는 기존 본문에 기재된 진단이며, 이번 작성에서 수집한 실행 로그가 아니다.

```text
src/broker/broker_monitor.c:52:10: fatal error: termio.h: No such file or directory
```

확인한 develop 소스에는 해당 include가 남아 있다. 다만 glibc 2.42 환경의 CUBRID 전체 빌드 실패와 수정 후 성공은 이번 작성에서 독립 검증하지 않았다.

## Additional Information

- [glibc 2.42 NEWS](https://github.com/bminor/glibc/blob/glibc-2.42/NEWS#L53-L61): Linux의 `<termio.h>`와 `struct termio` 제거를 명시한다.
- [glibc 제거 커밋 e04afb71771710cdc6025fe95908f5f17de7b72d](https://sourceware.org/pipermail/glibc-cvs/2025q2/088038.html): 삭제된 호환 헤더가 `<termios.h>`와 `<sys/ioctl.h>`를 포함했음을 확인할 수 있다.
- [확인한 CUBRID 소스](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/broker/broker_monitor.c#L45-L54), [공통 빌드 대상](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/broker/CMakeLists.txt#L78-L125)을 근거로 한다. `src`에서 `<termio.h>`를 직접 포함하는 위치는 이 파일 한 곳으로 확인한다.
- 기존 본문이 제안한 `<termios.h>` 직접 포함은 실제 사용 인터페이스와 부합하는 해결 후보다. 필요한 선언의 누락 여부와 기존 환경의 호환성을 확인한 뒤 ANALYSIS에서 방안을 결정한다. 동작이나 ABI에 영향이 없다는 결론도 검증 전에 확정하지 않는다.
- 배포판 이름만으로 영향 여부를 판정하지 않는다. 기존 본문의 Fedora 42 이상, Debian trixie 이상, Arch Linux 및 Alpine/musl에 대한 일괄 실패 주장과 공식 CI 통과 주장은 환경별 기록이 없어 확인 대상으로 남긴다.
- [CBRD-26809](https://jira.cubrid.org/browse/CBRD-26809)는 별도 파일의 표준 라이브러리 헤더 의존 문제다. 기존 본문은 리뷰 의견에 따라 이 이슈를 분리했다고 설명한다. 본 이슈는 `broker_monitor.c`의 터미널 헤더 의존 문제로 범위를 한정한다.

## Triage Request

현재 이슈는 Confirmed 상태다. 위 빌드 호환성 문제를 분석 범위로 확인하고, 작성자 측에 ANALYSIS를 배정하여 다음을 확인할 것을 요청한다. 실제 배정과 우선순위는 담당자의 판단에 따른다.

1. 실패 환경의 OS, libc 및 개발 헤더 패키지, 컴파일러, 전체 CUBRID 빌드 버전과 커밋, 원본 로그를 확보한다. 기존 보고 환경과 이전 릴리스의 영향을 구분한다.
2. `broker_monitor`와 `gateway_monitor`의 빌드 경로를 확인하고, 실제 사용하는 선언을 기준으로 해결 방안과 변경 범위를 결정한다.
3. Ubuntu 26.04와 Fedora 등 헤더 미제공 환경과 기존 빌드 환경을 대상으로 검증할 버전 조합을 정한다. 전체 빌드, 터미널 입력 설정 및 복원 동작 확인 절차와 검증 결과를 기록한다.
