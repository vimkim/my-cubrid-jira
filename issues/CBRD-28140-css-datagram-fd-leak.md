# [Network] 서버-마스터 handshake의 bind 실패 시 소켓이 누수되고 재시도가 폭주한다

**한 줄 요약**: CBRD-28139의 긴 Unix 소켓 경로를 재현하던 중 확인한 별도 결함으로, 서버-마스터 연결용 소켓의 bind가 실패하면 소켓을 닫지 않고 대기 없이 재연결하여 파일 기술자 고갈과 오류 로그 폭증을 일으킨다.

## Issue Triage

**이슈 수행 목적**: 서버-마스터 handshake가 실패해도 실패한 연결의 소켓을 회수하고, 반복 실패가 서버 자원 고갈과 로그 폭증으로 이어지지 않게 한다.

**이슈 수행 이유**: 현재 develop 소스에서 `css_tcp_setup_server_datagram`의 bind와 listen 실패 경로에 소켓 해제가 없고 호출자도 이를 회수하지 않는다. 기존 debug 빌드에서 bind 실패를 유발해 `/proc/<pid>/fd`와 strace로 소켓 누수와 즉시 재시도를 직접 확인했다.

**영향**: DB 서버를 기동하는 운영자와 개발자는 기동 명령이 끝나지 않는 동안 파일 기술자 한도에 도달하고 오류 로그가 계속 커지는 상황을 겪는다. 정상 기동은 fd 254개로 유지됐지만, bind 실패 실행은 soft limit를 1024로 낮춘 조건에서 1.779초 표본에서 처음 1024개를 관찰했다. 약 8초 실행 후 오류 로그 한 파일은 51,649,214바이트였다. 각 조건 1회 실행한 장애 재현값이며 일반 환경의 고갈 시간을 뜻하지 않는다. 고객 발생 빈도와 다른 릴리스의 영향은 확인하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

handshake는 `cub_server`가 `cub_master`에 등록하고 클라이언트 연결을 전달받기 위한 연결 설정 과정이다. 마스터가 `SERVER_REQUEST_ACCEPTED`로 응답하면 서버는 별도의 Unix 도메인 소켓을 열고 그 경로를 마스터에 전달한다. 함수 이름에 datagram이 있지만 실제 생성 유형은 `AF_UNIX`, `SOCK_STREAM`이다.

`css_tcp_setup_server_datagram`은 `socket()`으로 fd를 만든 뒤 bind 또는 listen이 실패하면 fd를 닫지 않고 `false`를 반환한다. 현재 서버의 `prepare_switch_to_unix_socket`도 이 fd를 닫지 않는다. 재연결은 마스터 연결 fd만 정리하고 새 handshake를 시작하므로, 실패한 Unix 소켓 fd는 다음 시도에서 덮어써진다.

누수와 재시도 제한 부재는 이 이슈에서 함께 다룬다. 같은 실패 경로에서 반복 발생하며, 소켓 회수만 고치면 오류 로그 폭증이 남고 재시도 간격만 늘리면 시도마다 누수가 남는다. 경로 길이의 검증과 오류 안내는 [CBRD-28139](https://jira.cubrid.org/browse/CBRD-28139)의 범위다. 이 이슈는 bind 실패 원인과 관계없이 실패한 소켓의 수명과 재시도를 제한하는 문제이며 Relates 관계로 연결한다.

## Test Build

- 실행 빌드는 `785021eed4d30f77b56a606cafd566cc1d066381`이다. CUBRID 11.5.0.2928-785021e, debug_gcc, Linux x86_64, Java 8이다.
- 2026-11-16에 origin/develop을 fetch한 뒤 `666bb10ae673c666c18aa9ae58dda59c9df59fdf`에서 아래 소스를 다시 확인했다. 관련 네 파일은 실행 빌드와 동일하다. 최신 tip 자체를 빌드해 실행하지는 않았다.
- 격리한 설치본과 기존 DB `sockdb`를 사용했다. `cubrid_port_id=37523`, `service=server`이며 HA 비활성 환경이다. 출력은 일반 파일로 보냈다.
- 정상 조건은 `CUBRID_TMP` 68자, 실패 조건은 80자였다. 실패 실행의 서버 pid는 109989로 원래 handshake 경로는 110자, bind 주소 길이는 113바이트였다. 두 조건 모두 soft fd limit를 1024로 낮춰 짧게 재현했다.

## Repro

전용 설치본, 미사용 마스터 포트, 실행 중이지 않은 테스트 DB를 준비한다. `service=server`로 두고 자동 기동 DB 목록은 비운다. 아래 `sockdb`는 준비한 DB 이름으로 바꾼다. 먼저 짧은 `CUBRID_TMP`로 정상 기동을 확인하고 해당 실행을 종료한 뒤 실패 조건을 실행한다. 아래 명령은 pid 자릿수와 관계없이 실패하도록 84자 경로를 사용한다. 위 빌드의 실측 조건은 80자였다.

```sh
export CUBRID=/path/to/isolated/install
export CUBRID_DATABASES=/path/to/test/database-registry
export PATH="$CUBRID/bin:$PATH"
export LD_LIBRARY_PATH="$CUBRID/lib"
export CUBRID_TMP="$(python3 -c 'import os; p="/tmp/cbrd-bind-"+str(os.getpid())+"-"; print(p+"x"*(84-len(p)))')"
mkdir "$CUBRID_TMP"
```

아래 Python을 같은 환경에서 실행한다. 약 8초간 fd와 소켓 수를 기록하고 이 환경에서 시작한 데몬을 종료한다. Linux의 `/proc`, Python의 pidfd 지원이 필요하다. timeout으로 기동 명령만 종료하면 자식 데몬이 남으므로 별도로 정리해야 한다.

```python
import os
import resource
import signal
import subprocess
import time
from pathlib import Path

install = Path(os.environ["CUBRID"]).resolve()
marker = ("CUBRID_TMP=" + os.environ["CUBRID_TMP"]).encode()
resource.setrlimit(resource.RLIMIT_NOFILE,
                   (1024, resource.getrlimit(resource.RLIMIT_NOFILE)[1]))
launchers = []
try:
    with open("master.out", "wb") as out, open("master.err", "wb") as err:
        master = subprocess.Popen(["cubrid", "service", "start"],
            stdin=subprocess.DEVNULL, stdout=out, stderr=err,
            start_new_session=True)
        launchers.append(master)
        assert master.wait(timeout=10) == 0
    with open("start.out", "wb") as out, open("start.err", "wb") as err:
        start = subprocess.Popen(["cubrid", "server", "start", "sockdb"],
            stdin=subprocess.DEVNULL, stdout=out, stderr=err,
            start_new_session=True)
        launchers.append(start)
        begin = time.monotonic()
        for tick in range(32):
            time.sleep(max(0, begin + tick * 0.25 - time.monotonic()))
            for proc in Path("/proc").glob("[0-9]*"):
                try:
                    if marker not in (proc / "environ").read_bytes().split(b"\0"):
                        continue
                    if (proc / "exe").resolve() != install / "bin/cub_server":
                        continue
                    targets = []
                    for fd in (proc / "fd").iterdir():
                        try:
                            targets.append(os.readlink(fd))
                        except FileNotFoundError:
                            pass
                    print(round(time.monotonic() - begin, 3), proc.name,
                          len(targets), sum(t.startswith("socket:[") for t in targets),
                          flush=True)
                except (FileNotFoundError, ProcessLookupError, PermissionError):
                    pass
        print("startup exit code", start.poll())
finally:
    for sig in (signal.SIGTERM, signal.SIGKILL):
        for proc in Path("/proc").glob("[0-9]*"):
            try:
                pidfd = os.pidfd_open(int(proc.name))
                try:
                    if marker not in (proc / "environ").read_bytes().split(b"\0"):
                        continue
                    exe = (proc / "exe").resolve()
                    if exe.parent != install / "bin" or exe.name not in {"cub_server", "cub_pl", "cub_master"}:
                        continue
                    signal.pidfd_send_signal(pidfd, sig)
                finally:
                    os.close(pidfd)
            except (FileNotFoundError, ProcessLookupError, PermissionError):
                pass
        time.sleep(0.5)
    for child in launchers:
        if child.poll() is None:
            child.kill()
        child.wait(timeout=5)
```

서버 pid를 확인하면 별도 터미널에서 짧게 strace를 수집할 수 있다. 수집 구간에 지연이 생기므로 이를 일반 실행의 속도로 해석하지 않는다. 재현 후 잔여 데몬이 없는지 확인하고 이번 실행에서 생성한 대용량 서버 오류 로그를 정리한다.

```sh
timeout -s INT 0.5s strace -f -ttt \
  -e trace=socket,bind,listen,close,epoll_wait,nanosleep,clock_nanosleep \
  -o syscalls.txt -p "$server_pid" </dev/null >trace.out 2>trace.err
```

## Actual Result

각 조건을 1회, 약 8초 관찰했다. 실패 실행의 약 1.0~1.5초 구간에는 strace를 연결했다. 실행 중 fd 스냅샷은 1개 정도 흔들릴 수 있다.

| 조건 | 기동 후 시점 | fd 수 | 소켓 수 | 결과 |
|---|---:|---:|---:|---|
| 정상, TMP 68자 | 1.271초 | 254 | 3 | 기동 성공, 7.272초까지 동일 |
| bind 실패, TMP 80자 | 1.273초 | 318 | 67 | 소켓 증가 |
| bind 실패 | 1.779초 | 1024 | 773 | 처음 관찰한 fd 한도 도달 |
| bind 실패 | 7.278초 | 1024 | 773 | 기동 명령이 계속 실행 중 |

strace에서 bind 실패 소켓 fd 254~564 총 311개를 확인했다. 수집 구간 전체의 모든 스레드에서 이 fd들에 대한 성공한 `close()`는 없었다. 다음은 원본에서 경로와 이벤트 세부를 줄인 발췌다.

```text
1794822785.508828 socket(AF_UNIX, SOCK_STREAM, 0) = 254
1794822785.508868 bind(254, {sa_family=AF_UNIX, sun_path="<TMP>/cubrid_tcp_setup_server109"}, 113) = -1 EINVAL
1794822785.509278 close(253) = 0
1794822785.509566 socket(AF_UNIX, SOCK_STREAM, 0) = 253
1794822785.509769 epoll_wait(10, [{events=EPOLLOUT, ...}], 512, 5000) = 1
1794822785.509850 epoll_wait(10, [{events=EPOLLIN, ...}], 512, 5000) = 1
1794822785.510015 socket(AF_UNIX, SOCK_STREAM, 0) = 255
1794822785.510066 bind(255, {sa_family=AF_UNIX, sun_path="<TMP>/cubrid_tcp_setup_server109"}, 113) = -1 EINVAL
```

`sun_path`는 구조체에 저장된 잘린 값이다. 원래 경로는 `cubrid_tcp_setup_server109989`로 끝난다. 첫 두 bind 실패 사이에는 약 1.2ms만 있다. `epoll_wait`의 timeout 5000은 이벤트가 없을 때의 대기 상한이며 재시도 간 최소 대기시간을 보장하지 않는다.

오류 로그에는 `Datagram bind error.... Invalid argument` 770건 이후 `Datagram socket error.... Too many open files` 62,044건이 기록됐다. 종료 시점의 실제 오류 로그 한 파일은 51,649,214바이트였다. `*_latest.err` 심볼릭 링크는 중복 합산하지 않았다. 고갈 뒤에도 재시도와 로그 기록이 계속됐다. 재현 후 이 실행의 `cub_server`, `cub_pl`, `cub_master`를 종료했고 같은 환경의 잔여 프로세스는 0개였다.

## Source Evidence

모든 위치는 develop `666bb10ae673c666c18aa9ae58dda59c9df59fdf` 기준이다.

| 위치 | 확인 내용 |
|---|---|
| [tcp.c:884-899](https://github.com/CUBRID/CUBRID/blob/666bb10ae673c666c18aa9ae58dda59c9df59fdf/src/connection/tcp.c#L884-L899) | socket 생성 후 bind 실패 시 close 없이 반환한다. |
| [tcp.c:910-914](https://github.com/CUBRID/CUBRID/blob/666bb10ae673c666c18aa9ae58dda59c9df59fdf/src/connection/tcp.c#L910-L914) | listen 실패에도 해제 누락이 있다. |
| [master_connector.cpp:452-461](https://github.com/CUBRID/CUBRID/blob/666bb10ae673c666c18aa9ae58dda59c9df59fdf/src/connection/master_connector.cpp#L452-L461) | 현재 서버 호출자가 m_unixsocket을 회수하지 않는다. |
| [master_connector.cpp:781-786](https://github.com/CUBRID/CUBRID/blob/666bb10ae673c666c18aa9ae58dda59c9df59fdf/src/connection/master_connector.cpp#L781-L786), [1387-1394](https://github.com/CUBRID/CUBRID/blob/666bb10ae673c666c18aa9ae58dda59c9df59fdf/src/connection/master_connector.cpp#L1387-L1394) | handshake 실패가 disconnect로 이어진다. |
| [master_connector.cpp:1258-1312](https://github.com/CUBRID/CUBRID/blob/666bb10ae673c666c18aa9ae58dda59c9df59fdf/src/connection/master_connector.cpp#L1258-L1312), [1327-1358](https://github.com/CUBRID/CUBRID/blob/666bb10ae673c666c18aa9ae58dda59c9df59fdf/src/connection/master_connector.cpp#L1327-L1358) | 마스터 연결만 정리한 뒤 즉시 connect와 handshake를 다시 시도한다. epoll timeout은 재시도 간격이 아니다. |
| [connection_sr.c:1169-1174](https://github.com/CUBRID/CUBRID/blob/666bb10ae673c666c18aa9ae58dda59c9df59fdf/src/connection/connection_sr.c#L1169-L1174), [1197-1199](https://github.com/CUBRID/CUBRID/blob/666bb10ae673c666c18aa9ae58dda59c9df59fdf/src/connection/connection_sr.c#L1197-L1199) | 다른 호출자도 경로만 unlink하고 socket_fd를 닫지 않는다. |
| [connection_cl.cpp:1053-1057](https://github.com/CUBRID/CUBRID/blob/666bb10ae673c666c18aa9ae58dda59c9df59fdf/src/connection/connection_cl.cpp#L1053-L1057), [1081-1083](https://github.com/CUBRID/CUBRID/blob/666bb10ae673c666c18aa9ae58dda59c9df59fdf/src/connection/connection_cl.cpp#L1081-L1083) | 클라이언트 쪽 호출자에도 같은 누락이 있다. |

## Expected Result

- bind 또는 listen이 실패하면 그 시도에서 만든 소켓 fd를 회수한다. 반복 실패가 열린 소켓 수의 지속 증가로 이어지지 않는다.
- 실패한 handshake의 재시도에는 대기 또는 횟수 제한을 적용해 자원과 로그를 소모하는 반복을 막는다.
- 복구할 수 없는 기동 실패는 원인을 알리고 종료한다. 일시적인 마스터 장애에 대한 정상 재연결 동작은 유지한다.

## Options for Analysis

후보 방안은 `css_tcp_setup_server_datagram`이 socket 생성 이후 모든 실패 경로에서 fd를 닫고 `INVALID_SOCKET`으로 초기화하도록 책임을 정하는 것이다. 모든 호출자의 실패 정리도 확인해 이중 close와 해제 누락을 막는다. listen 실패 시 소켓 파일의 unlink 책임도 정한다. 호출자별로 close만 추가하면 다른 호출자에서 다시 누락될 수 있다.

재시도는 최소 대기시간과 backoff, 또는 복구 불가능한 오류의 횟수 제한을 후보로 검토한다. 누수만 고치면 빠른 실패와 로그 폭증이 남는다. 재시도만 제한하면 누수는 느리게 계속된다. 이벤트 루프 전체를 sleep시키면 다른 처리를 막을 수 있으므로 재시도 예약 방식과 오류 분류를 ANALYSIS에서 정한다.

긴 경로에 의한 bind 실패는 직접 재현했다. 다른 bind 오류와 listen 실패, 다른 두 호출자의 실행 경로, HA 동작은 실행 검증하지 않았다. 후속 검증에서는 반복 실패에도 fd가 증가하지 않고 재시도가 제한되는지 확인한다.

## Related Issues

- [CBRD-28139](https://jira.cubrid.org/browse/CBRD-28139)는 긴 소켓 경로의 검증과 오류 안내를 다룬다. 이 이슈는 그 재현에서 드러난 소켓 해제 누락과 재시도 제한 부재를 분리한다.

중복 후보 20건의 제목과 signals를 검토하고 유사한 이슈의 본문과 댓글을 대조했다. [CBRD-27443](https://jira.cubrid.org/browse/CBRD-27443)와 여기에 Duplicate로 합쳐진 [CBRD-27613](https://jira.cubrid.org/browse/CBRD-27613)은 프로세스 사이의 fd 상속 문제다. 이번 문제는 현재 프로세스가 새로 만든 소켓을 실패 시 닫지 않는 결함이므로 별도 수정이 필요하다. [CBRD-28128](https://jira.cubrid.org/browse/CBRD-28128)은 execv 실패에 따른 fork 반복으로 재시도 위치와 고갈 자원이 다르다. 반환된 후보 중 같은 결함을 다루는 중복은 찾지 못했다.
