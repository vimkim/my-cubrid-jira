# [Network/PL] Unix 도메인 소켓 경로가 108바이트 한도를 넘으면 서버가 원인을 알리지 않고 늦게 실패하거나 경로를 잘라 쓴다

**한 줄 요약**: 로컬 ctest에서 설치 경로(`$CUBRID`)가 길어 PL 서버 소켓 경로가 108자가 되자, `cub_server`가 약 2분 뒤 경로와 무관한 오류로 부팅에 실패한 일에서 시작했다. develop `785021e`에서 같은 현상을 재현했고, PL 소켓 경로 외에 마스터 소켓 경로와 서버-마스터 연결용 소켓 경로도 길이를 검사하지 않고 잘라 쓰거나 늦게 실패한다는 것을 확인했다. 소켓 경로를 만들 때 길이를 검사해, 경로와 한도를 밝히는 오류로 즉시 실패하게 해야 한다.

## Issue Triage

**이슈 수행 목적**: Unix 도메인 소켓 경로가 Linux 한도(`sun_path` 108바이트, NUL 포함이므로 107자)를 넘는 설정에서, CUBRID 프로세스가 기동 시점에 그 경로와 한도를 밝히는 오류로 바로 실패하게 한다. 잘린 경로로 bind 또는 connect하는 동작을 없앤다.

**이슈 수행 이유**: CUBRID는 소켓 경로 세 종류를 `$CUBRID`, `$CUBRID_TMP`, DB 이름, 포트, pid로 조립한다. 길이 검사는 `$CUBRID_TMP` 자체가 96자 이하인지 보는 것뿐이고, 조립된 경로는 검사하지 않는다. develop `785021e` 빌드에서 경로 길이만 바꿔 실행해 다음을 확인했다.
- PL 소켓 경로가 107자이면 `cubrid server start`가 3.1초에 성공하고, 108자이면 114초 뒤 `PL server can not be started` 오류로 실패한다. 실제 원인(`java.net.SocketException: sockname too long`)은 기동 1초 만에 PL 로그에만 기록된다.
- `$CUBRID_TMP`가 80자이면 서버-마스터 연결용 소켓 경로가 111자가 되어 `cubrid server start`가 끝나지 않고, 서버 오류 로그가 약 20초에 190 MB씩 늘어난다.
- `$CUBRID_TMP`가 96자(검사를 통과하는 최댓값)이고 포트가 5자리이면 마스터 소켓 경로가 108자가 된다. `cub_master`는 잘린 경로에 쓰레기 1바이트가 붙은 이름으로 bind해, 실행 중인데도 `cubrid service status`가 "master is not running"을 출력한다. 정지 뒤 소켓 파일이 남아 다음 기동은 `Address already in use`로 실패한다.

**영향**: 경로가 긴 위치에 CUBRID를 설치하거나 `CUBRID_TMP`를 긴 경로로 지정한 운영자와 개발자가 겪는다. `$CUBRID` 길이와 DB 이름 길이의 합이 83자 이상이면 기본 설정(`stored_procedure_uds=yes`, `CUBRID_TMP` 미설정)에서 DB 서버가 기동하지 않는다. 오류 메시지가 경로를 언급하지 않아 원인을 찾으려면 PL 로그를 따로 열어 봐야 한다. 개발 환경에서는 작업별 설치 경로가 길어지기 쉽다. 다른 작업에서 PL 소켓 경로가 108자인 설치본의 OOS ctest(`test_oos_server_crash_recovery`)가 60초 제한에 걸려 매번 실패했고, 제한 없이 실행하면 약 112초 뒤 같은 오류로 부팅에 실패했다. 같은 바이너리는 짧은 `$CUBRID`에서 3.4초에 통과했다. `CUBRID_TMP`가 77~96자(pid가 7자리인 경우)이면 서버가 기동하지 않고 오류 로그를 빠르게 채운다. 고객 환경에서 보고된 사례는 아직 확인하지 못했다. 경로가 짧은 일반 설치에는 영향이 없다.

**이슈 수행 방안**: 소켓 경로를 조립하는 곳에서 길이를 검사해, 경로와 한도를 담은 오류로 즉시 실패하게 하고, `tcp.c`의 잘라 쓰는 복사를 거부로 바꾸는 방향을 제안한다. 브로커는 이미 같은 검사를 한다(`broker_admin_pub.c`). 최종 방안과 범위는 ANALYSIS 단계에서 정한다.

---

## AI-Generated Context

## Description

Linux의 `struct sockaddr_un.sun_path`는 108바이트이고 끝에 NUL이 필요하므로, 파일 시스템 경로를 쓰는 Unix 도메인 소켓 경로는 107자까지 쓸 수 있다. CUBRID가 쓰는 소켓 경로와 길이 처리는 다음과 같다. 소스 위치는 develop `785021eed4`(2026-11-16) 기준이다.

| 소켓 | 경로 | 만드는 곳 | 길이 검사 | 107자를 넘을 때 |
|---|---|---|---|---|
| PL 서버 | `$CUBRID_TMP/sp_<db>.sock`, 미설정 시 `$CUBRID/var/CUBRID_SOCK/sp_<db>.sock` | `src/sp/pl_comm.c:227-252` | 없음 | Java PL 서버의 bind가 실패한다. `cub_server`는 약 110초 재시도한 뒤 부팅에 실패한다. |
| 서버-마스터 연결 | `$CUBRID_TMP/cubrid_tcp_setup_server<pid>`, 미설정 시 `TMPDIR` 또는 `/tmp` | `src/connection/master_connector.cpp:452-453`, `src/connection/connection_sr.c:1165-1166` | 없음 | bind가 `EINVAL`로 실패하고, 서버가 대기 없이 재시도한다. |
| 마스터 | `$CUBRID_TMP/CUBRID<cubrid_port_id>`, 미설정 시 `/tmp/CUBRID<port>` | `src/connection/tcp.c:136-155` | `$CUBRID_TMP` 96자 이하 | `strncpy`로 107자에서 잘린다. 마스터는 잘린 경로와 쓰레기 1바이트로 bind한다. |

`$CUBRID_TMP` 길이 검사는 `envvar_check_environment`(`src/base/environment_variable.c:66-87`)에 있다. 한도 96은 `108 - 12`이고, 12는 `"CUBRID65384"`와 NUL을 뜻한다. 경로 구분자 `/`를 세지 않아 96자 `$CUBRID_TMP`와 5자리 포트로 108자 마스터 경로가 나온다. PL 소켓과 서버-마스터 연결 소켓은 이 계산의 대상이 아니다. `pl_comm.c:235`의 주석은 이 검사로 108자를 넘지 않는다고 적었지만, `$CUBRID` 경로와 DB 이름은 검사하지 않는다.

### Test Build

CUBRID 11.5.0.2928-785021e, debug_gcc 프리셋, Linux x86_64. `cubrid_port_id=37523`, Java 8(Temurin 8.0.462).

### Repro

같은 설치본을 길이가 다른 심볼릭 링크로 가리켜 `$CUBRID` 문자열 길이만 바꿨다. PL 소켓 경로 길이는 `$CUBRID` + `/var/CUBRID_SOCK/sp_` + DB 이름 + `.sock`이다.

```sh
# 설치본 INSTALL, DB 이름 sockdb 기준
ln -sfn "$INSTALL" "$LONG_ROOT"   # LONG_ROOT 문자열 길이 76 또는 77
export CUBRID="$LONG_ROOT" PATH="$LONG_ROOT/bin:$PATH" LD_LIBRARY_PATH="$LONG_ROOT/lib"
unset CUBRID_TMP
time cubrid server start sockdb </dev/null >start.out 2>start.err
cat "$CUBRID/log/pl/sockdb_pl.log"
```

`CUBRID_TMP` 사례는 `$CUBRID`를 설치본 실제 경로로 두고 `CUBRID_TMP`만 지정 길이의 디렉터리로 바꿨다.

```sh
export CUBRID_TMP="$TMP_DIR"            # 길이 80, 96, 97
cubrid service start </dev/null >master.out 2>&1
cubrid server start sockdb </dev/null >start.out 2>start.err
ss -xlp | grep "$TMP_DIR"
```

### Actual Result

| 사례 | 소켓 경로 길이 | 결과 |
|---|---|---|
| `$CUBRID` 58자 | PL 89 | 3.10초에 기동 성공 |
| `$CUBRID` 76자 | PL 107 | 3.11초에 기동 성공 |
| `$CUBRID` 77자 | PL 108 | 113.98초 뒤 실패(종료 코드 1) |
| `CUBRID_TMP` 80자 | 마스터 92, PL 95, 서버-마스터 연결 111 | `cubrid server start`가 끝나지 않음(20초, 400초 제한에서 강제 종료) |
| `CUBRID_TMP` 96자 | 마스터 108 | 마스터에 접속할 수 없음, 재기동 시 `Address already in use` |
| `CUBRID_TMP` 97자 | 마스터 109 | 즉시 `The $CUBRID_TMP is too long.`로 거부 |

#### PL 소켓 108자

`cubrid server start`의 출력은 다음과 같다.

```text
++ cubrid server start: fail
PL server can not be started: Error occured while starting Java SP Server by CallStaticIntMethod().
Unable to restart/initialize the database server. PL server can not be started: sockdb.
```

서버 오류 로그에는 기동 111초 뒤 다음 오류만 남는다. 어느 것도 소켓 경로나 길이를 언급하지 않는다.

```text
18:15:24.933 ERROR src/sp/pl_sr.cpp, line 546 ERROR CODE = -901
PL server can not be started: Failed to initialize the PL server. Verify that the server environment and configurations are properly set up.
18:15:24.933 ERROR src/sp/pl_sr.cpp, line 282 ERROR CODE = -901
18:15:24.933 ERROR src/transaction/boot_sr.c, line 2765 ERROR CODE = -113
Unable to restart/initialize the database server. PL server can not be started: sockdb.
```

원인은 기동 1초 만에 `$CUBRID/log/pl/sockdb_pl.log`에만 기록된다.

```text
SEVERE: java.net.SocketException: sockname too long
	at org.newsclub.net.unix.NativeUnixSocket.sockname(Native Method)
	at com.cubrid.jsp.Server.initializeSocket(Server.java:131)
```

지연은 PL 서버 감시 로직의 재시도에서 나온다(코드에서 추론). `cub_pl`은 JVM 기동이 실패해도 종료하지 않고 정보 파일을 쓴다(`src/executables/pl.cpp:447-457`). `cub_server`는 초기화 시도마다 1초 간격으로 최대 10회 ping하고(`src/sp/pl_sr.cpp:449-450`, `566-580`), 실패 횟수가 10을 넘으면 포기한다(`pl_sr.cpp:539-551`). 11회 × 약 10초가 측정된 약 110초와 맞는다. debug 빌드 로그의 `pl_connection_pool: connection retire` 110건도 이 계산과 맞는다. Java 쪽 경로는 C 쪽 `pl_get_socket_file_path`가 만들어 인자로 넘긴다(`src/sp/pl_sr_jvm.cpp:526`). 서버가 PL 서버에 접속할 때는 같은 경로를 `snprintf`로 `sun_path`에 맞게 잘라 쓴다(`src/sp/pl_comm.c:270`).

#### 서버-마스터 연결 소켓 111자

마스터는 `SERVER_REQUEST_ACCEPTED`로 응답하고, 서버는 `$CUBRID_TMP/cubrid_tcp_setup_server<pid>`에 소켓을 만들어 그 경로를 마스터에 보낸다. `css_tcp_setup_server_datagram`은 경로를 잘라 복사하면서 주소 길이는 원래 경로 길이로 계산한다.

```c
/* src/connection/tcp.c:893-900 */
  strncpy (serv_addr.sun_path, pathname, sizeof (serv_addr.sun_path) - 1);
  servlen = strlen (pathname) + 1 + sizeof (serv_addr.sun_family);

  if (bind (*sockfd, (struct sockaddr *) &serv_addr, servlen) < 0)
    {
      er_set_with_oserror (ER_ERROR_SEVERITY, ARG_FILE_LINE, ERR_CSS_TCP_DATAGRAM_BIND, 0);
      return false;
    }
```

주소 길이가 `sizeof (struct sockaddr_un)`보다 커서 bind가 `EINVAL`로 실패한다. 관찰한 결과는 다음과 같다.

- 첫 오류는 `tcp.c, line 898 ERROR CODE = -359 Datagram bind error.... Invalid argument`와 `master_connector.cpp, line 459 ERROR CODE = -368`이다. 첫 1초에 이 쌍이 238번 기록되었다.
- 오류 로그가 약 20초에 약 190 MB로 늘었다. 400초를 기다린 첫 실행에서는 6분 안에 512 MB 오류 로그가 `.bak`으로 회전했다.
- `cubrid server start`의 stderr에 `try to re-establish the connection with master...`가 20초에 23만 줄 넘게 출력되었다.
- 400초 실행에서는 기동 후 5분 안에 오류가 `Datagram socket error.... Too many open files`로 바뀌었다. bind가 실패하면 `css_tcp_setup_server_datagram`과 호출자(`master_connector.cpp:457-461`)가 만든 소켓을 닫지 않으므로 파일 기술자가 새는 것으로 보인다(코드에서 추론).
- `cubrid server start`가 제한 시간에 강제 종료된 뒤에도 `cub_server`와 `cub_pl`은 계속 실행되어 직접 종료해야 했다.

`CUBRID_TMP`를 설정하지 않으면 이 경로는 `std::filesystem::temp_directory_path()`, 즉 `TMPDIR` 또는 `/tmp`를 쓴다(`src/base/filesys_temp.cpp:112-118`). `TMPDIR`은 길이를 검사하지 않으므로 긴 `TMPDIR`도 같은 문제를 일으킬 것으로 보인다(추론, 실행하지 않음).

#### 마스터 소켓 108자

```c
/* src/connection/tcp.c:652, 675-676, css_tcp_master_open */
  struct sockaddr_un unix_srv_addr;
  ...
  unix_srv_addr.sun_family = AF_UNIX;
  strncpy (unix_srv_addr.sun_path, css_get_master_domain_path (), sizeof (unix_srv_addr.sun_path) - 1);
```

`unix_srv_addr`를 0으로 초기화하지 않아 `sun_path`의 마지막 바이트가 스택에 남은 값이 된다. 실행 중인 `cub_master`의 소켓 이름은 `.../CUBRID3752` 뒤에 `0xDF` 1바이트가 붙은 108바이트였다(`ss -xlp`, `od -c`로 확인). 클라이언트는 같은 경로를 0으로 초기화한 구조체에 107자로 잘라 접속하므로(`tcp.c:377-379`) 이름이 달라진다. 그 결과 `cub_master`가 실행 중인데도 `cubrid service status`가 `++ cubrid master is not running.`을 출력하고, `cubrid service start`는 끝나지 않았다.

마스터는 기동과 정지 때 잘리지 않은 경로로 기존 소켓을 확인하고 삭제한다(`tcp.c:738-763`, `src/executables/master.c:242`). 실제로 만든 파일은 이름이 달라 삭제되지 않는다. 정지 뒤 다시 기동하자 다음 오류가 반복되었다.

```text
cub_master: Cannot bind local address... aborting.... Address already in use
FAILURE: Master does not exist. Try to start it again.
```

### Expected Result

- 조립한 소켓 경로가 107자를 넘으면 그 경로를 만드는 프로세스가 기동 시점에 실패한다. 오류 메시지에는 경로, 길이, 한도, 줄일 수 있는 설정(`CUBRID_TMP`, 설치 경로)이 들어간다.
- 잘린 경로로 bind 또는 connect하지 않는다.
- PL 서버가 소켓을 만들지 못하면, 서버 오류 로그의 PL 기동 실패 오류에서 그 원인을 알 수 있다.

### 매뉴얼과의 차이

매뉴얼(`cubrid-manual` develop `3b6ae97b`, `en/env.rst:43-66`, `ko/env.rst:42-48`)은 `CUBRID_TMP`가 108자보다 길면 오류를 낸다고 설명한다. 실제 한도는 96자다. cub_pl 소켓이 `$CUBRID/var/CUBRID_SOCK`에 생긴다는 설명은 있지만, 그 경로의 길이 제한은 브로커에 대해서만 적혀 있다.

### 우회 방법

- 설치 경로를 짧게 하거나, 짧은 `CUBRID_TMP`를 지정해 PL 소켓을 그 디렉터리로 옮긴다.
- `stored_procedure_uds=no`로 PL 연결을 TCP로 바꾼다(매뉴얼 `admin/config.rst:2394`, 이번에 실행하지 않음).
- `CUBRID_TMP`는 76자 이하로 둔다. 서버-마스터 연결 소켓에는 `cubrid_tcp_setup_server`(24자)와 최대 7자리 pid가 붙는다.

## Options for Analysis

아래는 후보이며, 최종 선택은 ANALYSIS에서 한다.

| 후보 방안 | 기대 효과와 장점 | 한계·단점과 실패 조건 | 비용·위험·호환성 | 근거와 ANALYSIS 확인 사항 |
|---|---|---|---|---|
| A. 각 경로를 조립하는 함수(`pl_get_socket_file_path`, `css_get_master_domain_path`, 서버-마스터 연결 경로)에서 길이를 검사하고 오류 반환 | 원인 지점에서 경로와 한도를 담은 오류를 낸다. PL 기동 전에 실패해 110초 대기가 없어진다. | 호출자가 오류를 처리해야 한다. 현재 두 함수는 정적 버퍼를 반환하고 실패를 표현하지 않는다. | 수정 범위가 중간이다. 새 오류 코드 또는 기존 코드 재사용 여부를 정해야 한다. | 브로커의 `broker_admin_pub.c:325-333` 검사가 선례다. pid 자릿수는 `pid_max`에 따른다. |
| B. 기동 시 `envvar_check_environment`에서 만들 수 있는 최장 경로를 미리 계산해 거부 | 모든 프로세스가 같은 위치에서 일찍 실패한다. 구현이 작다. | DB 이름, 포트, pid를 알아야 정확하다. 보수적으로 잡으면 지금 동작하는 설정을 거부할 수 있다. | 기존 `CUBRID_TMP` 한도를 바꾸면 호환성에 영향이 있다. | 구분자 `/`를 세지 않은 현재 계산을 고쳐야 한다. |
| C. `tcp.c`의 잘라 쓰는 복사를 길이 검사와 거부로 교체 | 잘린 이름으로 bind, connect하는 동작과 쓰레기 바이트 문제를 없앤다. | 단독으로는 오류가 늦게, 낮은 수준에서 난다. 사용자가 원인을 알기 어렵다. | 수정이 작고 위험이 낮다. | A 또는 B와 함께 적용하는 보완책으로 보인다. `unix_srv_addr` 초기화, bind 실패 시 소켓 닫기, 재시도 대기도 함께 검토한다. |

A는 오류 위치와 메시지가 가장 정확하지만, 정적 버퍼 반환 함수의 계약을 바꿔야 한다. B는 일찍 실패하지만 DB 이름과 pid를 아는 시점이 프로세스마다 달라 한도를 정확히 잡기 어렵다. C는 잘린 경로를 쓰는 동작을 막는 최소 안전장치이며, A 또는 B와 함께 쓰는 쪽이 사용자 경험에 맞다. 서버-마스터 연결 실패의 재시도 폭주와 파일 기술자 누수는 경로 길이와 별개로 다른 bind 실패에서도 생길 수 있으므로, 분리할지 ANALYSIS에서 정한다.

## 관련 이슈

- [CBRD-23474](https://jira.cubrid.org/browse/CBRD-23474) "the max value of installation path' length isn't 108": 설치 경로가 길 때 브로커가 `The socket path is too long (>108)`을 출력하는지 확인하는 셸 테스트의 회귀 이슈다. 브로커에는 이 검사와 테스트가 있지만, PL, 마스터, 서버-마스터 연결 소켓에는 없다.
- [CBRD-25712](https://jira.cubrid.org/browse/CBRD-25712) "PL 서버가 반복해서 재구동에 실패하는 경우의 처리": JVM 기동 실패 시 `cub_pl`을 남겨 두는 현재 동작을 만든 이슈다. 이번 이슈는 재시도 정책이 아니라, 재시도로는 해결되지 않는 원인을 기동 시점에 알리지 않는 문제를 다룬다.
- [CBRD-27026](https://jira.cubrid.org/browse/CBRD-27026) "CDC: localhost 접속 시 ... Unix domain socket으로 ... 접속": 같은 `css_get_master_domain_path` 경로를 다루지만, 경로 길이가 아니라 어느 포트의 마스터에 접속하는지의 문제다.
