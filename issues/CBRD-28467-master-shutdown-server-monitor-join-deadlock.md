# [Master] cub_master 종료 중 서버 모니터 스레드 해제가 소켓 목록 잠금과 엇갈려 마스터가 멈출 수 있다

**한 줄 요약**: PR #8792(CBRD-28140) 코드 리뷰에서 찾은 기존 결함으로, 서버 정지 요청 처리와 `cubrid service stop`이 겹치면 cub_master의 메인 스레드와 서버 모니터 스레드가 서로를 기다려 마스터가 끝나지 않는 교착을 고친다. 디버거로 스레드 실행 순서를 맞춰 실제 cub_master에서 재현했다.

## Issue Triage

**이슈 수행 목적**: `auto_restart_server`가 켜진 환경에서 마스터 종료 요청이 서버 정지 요청과 겹쳐도, cub_master가 제한된 시간 안에 서버를 정지시키고 종료하게 한다.

**이슈 수행 이유**:
- 마스터의 메인 스레드는 소켓 목록 잠금(`css_Master_socket_anchor_lock`)을 잡은 채 종료 요청(START_SHUTDOWN)을 처리한다. 이때 서버 모니터 객체를 해제하는데(`master_Server_monitor.reset ()`), 소멸자는 모니터 스레드가 끝나기를 기다린다(join).
- 모니터 스레드가 그 직전에 SHUTDOWN_SERVER 작업을 꺼냈다면 같은 잠금을 기다리게 된다. 이 작업은 `cubrid server stop`이 보내는 재기동 서버 정지 요청에서 생긴다.
- 두 스레드는 서로 다른 뮤텍스를 쓰고, 종료 플래그는 이미 꺼낸 작업을 취소하지 못한다. 따라서 이 순서를 막는 장치가 없다.

**영향**:
- 교착이 생기면 `cubrid service stop`이 끝나지 않고, `cubrid server status`도 멈춘다. 마스터 포트도 계속 점유된다.
- 서버 정지 메시지는 모니터 해제 뒤에 보내므로, DB 서버는 정지 요청을 받지 못하고 계속 실행된다.
- 마스터를 강제 종료(`kill -9`)하기 전에는 풀리지 않는다.
- 디버거로 순서를 고정하면 매번 재현된다. 디버거 없이 동시에 요청한 10회에서는 한 번도 발생하지 않았다. 열리는 시간 폭이 짧아 드물게 일어나는 것으로 보이며, 실제 빈도는 미상이다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

HA를 끄고 `auto_restart_server=yes`(기본값)일 때만 해당한다. cub_master는 비정상 종료한 cub_server를 다시 띄우려고 `server_monitor` 스레드를 둔다.

### 교착 경로

| 행위자 | 순서 |
|---|---|
| 메인 스레드 M | `css_master_loop ()` → `css_check_master_socket_input ()`가 `css_Master_socket_anchor_lock`을 잡음(master.c) → `css_process_info_request ()` → START_SHUTDOWN → `css_process_shutdown ()` → `master_Server_monitor.reset ()` → `~server_monitor ()` → `stop_monitoring_thread ()` → `m_monitoring_thread->join ()` |
| 모니터 스레드 T | SHUTDOWN_SERVER 작업 → `server_monitor::shutdown_server ()` → `css_process_start_shutdown_by_name ()` → `pthread_mutex_lock (&css_Master_socket_anchor_lock)` (master_request.c:637) |

T가 SHUTDOWN_SERVER 작업을 꺼낸 뒤 잠금을 얻기 전에 M이 잠금을 잡고 `reset ()`에 들어가면, M은 T의 종료를 기다리고 T는 M이 가진 잠금을 기다린다.

### 언제 SHUTDOWN_SERVER가 잠금을 잡는가

- SHUTDOWN_SERVER 작업은 `css_process_shutdown_reviving_server ()`가 만든다. 이 함수는 SHUTDOWN_REVIVING_SERVER 요청을 처리한다.
- `cubrid server stop <db>`는 상태 확인에서 대상 서버가 마스터에 등록되어 있지 않을 때 이 요청을 보낸다(util_service.c `shutdown_reviving_server ()`). `cub_commdb --shutdown-reviving-server <db>`도 같은 요청을 보낸다.
- 모니터는 항목이 있고 `need_revive`가 거짓일 때만 `css_process_start_shutdown_by_name ()`을 호출한다. 이것이 잠금을 잡는 경로다. 다시 띄운 서버가 아직 등록하지 않은 동안에는 `need_revive`가 참이라 잠금을 잡지 않는다.
- 따라서 교착 경로를 타는 것은 마스터에 등록된 서버를 정지하는 경우다. 예를 들면 다음과 같다.
  - `cubrid server stop`의 상태 확인 직후에, 다시 띄운 서버가 등록을 마친 경우
  - `cub_commdb`로 요청을 직접 보낸 경우
- 모니터는 작업을 FIFO로 처리하고, 앞선 재기동 확인 작업은 1초씩 쉰다. 그래서 SHUTDOWN_SERVER를 꺼내는 시점은 요청 도착보다 최대 약 1초 늦을 수 있다.

### 처음 의심했던 해제 뒤 사용 경로는 해당하지 않는다

처음 등록할 때는 모니터를 해제한 뒤 메인 루프가 서버 종료를 감지하면 빈 포인터로 `produce_job ()`을 호출할 수 있다고 의심했다. 그러나 `css_process_kill_master ()`가 `exit (1)`로 끝나므로(master_request.c:728) 메인 루프는 다시 돌지 않는다. 시험에서도 그 줄에 도달하지 않았다. 이 경로는 이 이슈의 범위에서 뺀다.

## Test Build

- 소스: CUBRID/cubrid#8792 head cc845fa345a8cdb0078881482f6d3c14706715dd(develop a921084ab7 기반), debug build, GCC, Linux x86_64. HA 꺼짐, `auto_restart_server=yes`, DB `testdb`.
- 교착과 관련된 코드는 현재 develop 08f8185500과 같다. master.c와 master_request.c는 바뀌지 않았다. master_server_monitor.cpp의 `shutdown_server ()`, `~server_monitor ()`, `stop_monitoring_thread ()`도 바뀌지 않았다(`git diff`로 확인). PR #8792는 이 함수들을 바꾸지 않는다.
- release 빌드와 11.4에서는 시험하지 않았다.

## Repro

디버거로 두 스레드의 순서를 고정한다. 터미널 두 개에서 같은 CUBRID 환경을 쓴다.

```bash
# Terminal 1
cubrid server start testdb
MASTER_PID=$(pgrep -u "$USER" -x cub_master)     # ls -l /proc/$MASTER_PID/exe 로 확인
gdb -q -iex 'set non-stop on' -iex 'set pagination off' -p "$MASTER_PID"
(gdb) break css_process_start_shutdown_by_name
(gdb) break server_monitor::stop_monitoring_thread
(gdb) continue -a &

# Terminal 2
cub_commdb --shutdown-reviving-server testdb
#   Terminal 1: 모니터 스레드가 css_process_start_shutdown_by_name (master_request.c:637) 중단점에서 멈춘다. 그대로 둔다.
cubrid service stop          # 끝나지 않는다
#   Terminal 1: 메인 스레드가 server_monitor::stop_monitoring_thread 중단점에서 멈춘다
#   (css_process_shutdown -> master_Server_monitor.reset () 안, css_Master_socket_anchor_lock 보유)

# Terminal 1
(gdb) thread 1
(gdb) continue &
(gdb) thread 2
(gdb) continue &
#   30초 기다린다: cub_master가 끝나지 않고 "cubrid service stop"도 돌아오지 않는다
(gdb) interrupt -a
(gdb) thread apply all bt
(gdb) print css_Master_socket_anchor_lock.__data.__owner      # 메인 스레드 LWP (= MASTER_PID)
(gdb) detach
(gdb) quit
gstack "$MASTER_PID"          # 디버거를 뗀 뒤에도 같은 두 스택이 남는다
```

사용자 경로로 재현하려면 `cub_commdb` 단계 대신 다음을 쓴다. 마스터 gdb는 위와 같이 붙이고 중단점을 건 상태로 계속 실행해 둔다.

```bash
# Terminal 2
kill -9 "$(pgrep -u "$USER" -x cub_server)"      # 모니터가 testdb를 다시 띄운다
gdb -q -ex 'break shutdown_reviving_server' -ex run --args "$CUBRID/bin/cubrid" server stop testdb
#   "++ cubrid server 'testdb' is not running." 출력 뒤 shutdown_reviving_server 에서 멈춘다
#   다시 띄운 서버가 등록할 때까지 기다린다(다른 터미널의 "cubrid server status"에 testdb가 보일 때까지)
(gdb) continue
#   Terminal 1: 모니터 스레드가 css_process_start_shutdown_by_name 중단점에서 멈춘다
cubrid service stop          # 이후는 위와 같다
```

정리: 멈춘 마스터는 `kill -9 $MASTER_PID`로만 끝난다. DB 서버는 계속 실행 중이므로 cub_master를 다시 띄워 등록시킨 뒤 `cubrid service stop`을 실행한다.

## Actual Result

두 방법 모두 재현했다. 디버거를 뗀 뒤에도 60초 넘게 상태가 그대로였고, 마스터를 `kill -9`로 끝냈다.

```none
Thread 1 (main):
#2  std::thread::join()
#3  server_monitor::stop_monitoring_thread () at master_server_monitor.cpp:74
#4  server_monitor::~server_monitor () at master_server_monitor.cpp:55
#7  std::unique_ptr<server_monitor>::reset (this=<master_Server_monitor>, __p=0x0)
#8  css_process_shutdown (time_buffer=...) at master_request.c:789
#9  css_process_info_request (conn=...) at master_request.c:2162
#10 css_check_master_socket_input (...) at master.c:1261
#11 css_master_loop () at master.c:1414

Thread 2 (server monitor):
#0  __lll_lock_wait ()
#1  pthread_mutex_lock@@GLIBC_2.2.5 ()
#2  css_process_start_shutdown_by_name (server_name="testdb") at master_request.c:637
#3  server_monitor::shutdown_server (...) at master_server_monitor.cpp:332
#4  server_monitor::process_job (...) at master_server_monitor.cpp:385
#5  server_monitor::server_monitor_thread_worker () at master_server_monitor.cpp:104
```

- `css_Master_socket_anchor_lock`의 소유자는 메인 스레드였다.
- `cubrid service stop`이 실행한 `cub_commdb -A`는 마스터를 죽일 때까지 끝나지 않았고, 그 뒤 `master stop: fail`을 출력했다.
- 마스터 포트는 계속 점유되었고, `cubrid server status`도 멈췄다.
- DB 서버는 정지 요청을 받지 못해 계속 실행되었다. 새로 띄운 cub_master에 다시 등록되었다.
- 디버거 없이 `cub_commdb --shutdown-reviving-server testdb`와 `cubrid service stop`을 동시에 실행한 10회에서는 교착이 0회였다. `cubrid service stop`은 먼저 broker를 정지하므로, 그사이에 모니터가 잠금을 잡았다가 풀었다.

## Expected Result

- 마스터 종료 요청이 서버 정지 요청과 겹쳐도 cub_master가 서버들을 정지시키고 제한된 시간 안에 종료한다.
- 모니터 스레드를 정리하는 동안 메인 스레드가 그 스레드가 필요로 하는 잠금을 잡고 있지 않는다.

## Additional Information

- 같은 형태의 잠재 경로가 하나 더 있다(소스 분석만 함). KILL_MASTER_SERVER(master_request.c:2156)는 `reset ()` 없이 `css_process_kill_master ()` → `exit (1)`을 부른다. 그러면 `exit`가 전역 `master_Server_monitor` 소멸자를 실행해, 잠금을 쥔 채 join한다. 다만 이 요청을 보내는 코드는 현재 트리에 없다(commdb.c의 `process_master_kill`은 정의만 있고 호출되지 않는다).
- 관련: CBRD-28140(PR #8792 코드 리뷰 중 발견, 해당 PR의 변경 범위 밖), CBRD-28128(같은 모니터의 재기동 실패 처리 결함).
