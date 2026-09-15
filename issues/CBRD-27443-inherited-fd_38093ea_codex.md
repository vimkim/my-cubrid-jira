# [CBRD-27443] 백그라운드 서버가 호출자의 파일 디스크립터를 유지해 후속 명령의 잠금 획득을 막음

## Issue Triage

**이슈 수행 목적**: CUBRID 백그라운드 서버가 호출자의 불필요한 파일 디스크립터(FD, 열린 파일을 가리키는 번호)를 유지하지 않도록 한다.

**이슈 수행 이유**:

- **AS-IS (현재 동작 / 배경)**: `flock` 잠금을 가진 셸에서 `cubrid server start`를 실행하면, 시작 명령과 셸이 종료된 뒤에도 잠금이 남는다.
- **TO-BE (목표 상태 / 기대 동작)**: 호출자 전용 잠금은 서버 수명과 분리되어, 호출자가 종료된 뒤 다시 획득할 수 있어야 한다.
- **영향**: 설계 의도 훼손 — 같은 잠금을 사용하는 후속 운영 명령이 CUBRID 명령 실행 전에 대기하거나 잠금 획득에 실패한다.

**이슈 수행 방안**: `TBD - 합의 미확인`. FD 정리 위치와 보존 대상은 의도적인 FD 전달 및 실행 모드별 호환성을 확인한 뒤 결정한다.

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### 변경 범위

조사 대상은 Unix 계열 서비스 실행부, 서버 진입부, PL(저장 프로시저 실행 프로세스) 생성부, master(서버 등록·연결 관리 프로세스), broker(클라이언트 연결 중개 프로세스), HA(고가용성) 프로세스 관리부다. Windows 동작은 이번 분석에서 검증하지 않았다. 엔진 코드는 수정하지 않았다.

## Description

Linux에서 `fork()`로 복제한 FD는 같은 열린 파일 상태를 참조한다. `flock` 잠금도 여기에 연결되므로 명시적으로 잠금을 해제하거나 모든 참조 FD를 닫아야 풀린다. `exec`를 거쳐도 잠금은 유지된다. 이는 OS의 정상 동작이다. [flock(2)](https://man7.org/linux/man-pages/man2/flock.2.html)

실행 파일을 바꿀 때 닫으라는 `FD_CLOEXEC` 표시가 없으면 FD는 기본적으로 `exec` 이후에도 열린다. CUBRID의 일반 서버 시작 경로에는 호출자에게서 받은 불필요한 FD를 정리하는 처리가 없으며, 서버의 `setsid()`는 세션을 분리할 뿐 이 참조를 없애지 않는다. [execve(2)](https://man7.org/linux/man-pages/man2/execve.2.html)

호출 스크립트에서 전용 FD를 자식 명령에 넘기지 않는 방어도 필요하다. 다만 이번 독립 재현은 개인 도구 없이 표준 셸과 CUBRID 명령으로 구성했으므로, CUBRID 백그라운드 실행 경계의 처리도 별도로 검토할 수 있다. 전통적인 daemon의 초기 FD 정리와 서비스 관리자가 의도적으로 FD를 넘기는 실행 방식은 요구가 다르다. [daemon(7)](https://man7.org/linux/man-pages/man7/daemon.7.html)

### 서버에서 PL까지의 경로

```text
셸: exec 9>잠금파일 → flock -x 9
  └ cubrid server start DB
      └ util_service.c:1777 proc_execute(..., false, false, false, &pid)
          └ util_service.c:890 fork()
              ★ stdout/stderr의 선택적 close만 수행
              └ util_service.c:910 execv(cub_server)
                  └ server.c:322 setsid() → net_server_start()
                      └ pl_sr.cpp:365 create_child_process(cub_pl, ...)
                          └ process_util.c:262 fork()
                              ★ 표준 입출력 경로 인수가 모두 nullptr
                              └ process_util.c:350 execv(cub_pl)
```

FD 9는 재현용으로 고른 일반 FD이며 제품의 예약 번호나 임계값이 아니다. `create_child_process()`는 지정된 파일로 표준 입출력을 바꿀 수 있지만, 위 호출에는 해당 파일 인수가 없고 다른 FD를 정리하는 루프도 없다. 따라서 이미 서버에 들어온 FD가 PL까지 전달되는 경로가 소스상 연결된다.

### 서비스별 확인 범위

아래 소스 위치는 모두 `38093ea859a8a08e20405b72b0cb395205bedb2f` 기준이다. 실행 시험과 소스상 후보를 구분한다.

| 경로 | 확인한 처리 | 판단 범위 |
|---|---|---|
| 일반 서버 → PL | 위 호출 흐름 | 실제 FD 유지 관찰. 출력은 Actual Result에 수록한다. |
| 일반 master 시작 | `master.c:1313`에서 `CUBRID_NO_DAEMON`이 없으면 `css_daemon_start()` 호출. `master.c:1684`에서 FD 3 이상, `css_get_max_socket_fds()` 미만을 닫음 | 서버와 달리 정리 코드가 있다. FD 0·1·2는 의도적으로 남긴다. 실험하지 않았다. |
| daemon 분리를 생략한 master | `CUBRID_NO_DAEMON`이 있으면 위 초기 정리를 건너뜀 | 해당 실행 계약과 감독 프로세스의 FD 전달 정책을 함께 확인해야 한다. 실험하지 않았다. |
| broker 최초 실행 | `util_service.c:1969` → `broker_admin_pub.c:3158` fork → `:3216` exec. 일부 조건부 관리 소켓만 닫음 | 일반 FD 정리가 없는 실행 경로로 확인했다. 동일한 잠금 유지 여부는 미재현이다. |
| 관리 명령의 CAS·proxy 최초 실행 | `broker_admin_pub.c:3467/3510`, `:3700/3737`의 fork/exec | CAS(질의를 처리하는 응용 서버)와 shard proxy(샤드 연결 중개 프로세스)의 해당 생성 경로에서 일반 FD 정리를 찾지 못했다. 미재현이다. |
| broker 내부 CAS·proxy 생성/재시작 | `broker.c:1552`, `:3192`에서 FD 3부터 `max_open_fd`까지 닫음 | 최초 실행 경로와 처리 방식이 다르다. broker 하위 프로세스 전체를 동일하게 분류할 수 없다. |
| HA 도구 직접 시작 | `util_service.c:3316`, `:3597`의 log copy/apply 실행이 공통 `proc_execute` 사용 | 시작 도우미가 FD를 전달한다. 대상 프로그램의 최종 유지 여부는 미검증이다. |
| master의 HA 시작·재시작 | `master_heartbeat.c:3137/3166`, `:6678/6703`의 fork/exec | 해당 분기에 일반 정리가 없다. master의 초기 정리 이후 생성된 내부 FD도 별도 검토 대상이다. 미재현이다. |
| 일반 서버 자동 재기동 | `master_server_monitor.cpp:266/273`의 fork/exec | 명령을 실행한 셸이 아니라 master가 부모다. 이번 셸 FD 9 재현과 동일한 조건으로 볼 수 없다. |

### 의도적인 전달과 정리 경계

| 계약 | 소스 근거 | 수정 시 보존할 동작 |
|---|---|---|
| master → 서버의 클라이언트 소켓 전달 | `master.c:723` → `tcp.c:1168`, `SCM_RIGHTS` | Unix 소켓 메시지로 FD를 명시적으로 전달한다. 실행 중 소켓을 일괄 정리하는 방식은 피해야 한다. |
| broker → CAS/proxy의 클라이언트 소켓 전달 | `broker.c:1120/1274` → `broker_send_fd.c:82`, `cas_common_main.c:1012` | 프로세스 실행 후 이루어지는 연결 인계가 유지되어야 한다. |
| PL 연결 | `pl_sr.cpp:365`의 인수는 실행 파일·DB 이름이며, `pl_comm.c:256/288`은 Unix/TCP 소켓으로 새로 연결 | 이 경로에서 호출자 잠금 FD를 PL에 전달할 필요는 찾지 못했다. 모든 실행 모드의 계약이 검증됐다는 뜻은 아니다. |
| 동기 실행 유틸리티 | `util_service.c:482` 등도 `proc_execute_internal()` 공유 | 표준 입출력 리다이렉션 등 일반 명령 실행 계약을 보존해야 한다. 백그라운드 전용 정책과 구분해야 한다. |

`SCM_RIGHTS`는 실행 중 소켓을 통해 FD를 전달하는 방식으로, 부모가 자식에게 우연히 남기는 상속과 구분한다. 정리 후보 경계는 백그라운드 프로세스의 실행 직전 또는 자체 초기화 직후다. 서비스 소켓과 파일을 연 뒤 정리하면 필요한 자원까지 닫을 수 있다.

## Test Build

| 항목 | 확인값 |
|---|---|
| 재현 일자 | 2026-09-15 |
| 서버 배너 | `CUBRID 11.5.0 (11.5.0.2672) (64 debug build)` |
| OS | `Linux 5.14.0-570.30.1.el9_6.x86_64`, x86_64 |
| 분석 소스 | `feat/oos`, `38093ea859a8a08e20405b72b0cb395205bedb2f` |
| 서버 ELF Build ID | `7730fa6405e3527d0beebf66aaddf2e6e6e3b0f7` |
| 설치된 cub_server SHA-256 | `087a077cbaf01d50d56f7ef8a85332a60c88945414bdd22c53eba6b555541c01` |
| 설치된 cub_pl SHA-256 | `83b4077da17d7fca4a355f13d8f077550bfa75f3e776740913def4e4ae05963e` |

디버그 정보의 소스 위치와 빌드 로그가 가리키는 작업 디렉터리는 일치했다. 그러나 이를 분석 커밋으로 빌드했다는 기록은 확보하지 못했다. 설치 파일과 현재 빌드 디렉터리 파일의 SHA-256도 달라, 위 분석 커밋과 테스트 바이너리의 정확한 대응은 **미확인**이다. ELF Build ID는 바이너리 식별값이며 Git 커밋이 아니다.

깨끗한 develop 빌드에서는 아직 재현하지 않았다. `feat/oos`라는 브랜치명만으로 OOS(큰 가변 컬럼을 행 밖에 저장하는 방식)가 결함 원인이라고 판단하지 않는다. 영향받는 최초 버전도 미확인이다.

## Repro

```bash
#!/usr/bin/env bash
# 전제: Linux, Bash, flock, timeout, awk, readlink, ps 및 설치된 CUBRID.
# CUBRID/PATH/LD_LIBRARY_PATH는 시험할 설치본으로 설정한다.
# 해당 설치본의 master가 이미 실행 중이어야 한다.
# 아래 내용을 repro-inherited-fd.sh로 저장한 뒤 bash repro-inherited-fd.sh로 실행한다.
# Requires an installed CUBRID environment and a reachable CUBRID master.
# Creates and cleans up only a uniquely named database in a private registry.
set -euo pipefail
: "${CUBRID:?Set CUBRID to the installation to test}"
command -v cubrid >/dev/null
command -v flock >/dev/null
command -v timeout >/dev/null
repro_dir=$(mktemp -d /tmp/cbrd27443.XXXXXXXX)
repro_db="fd${repro_dir##*.}"
export CUBRID_DATABASES="$repro_dir/registry"
mkdir -p "$CUBRID_DATABASES" "$repro_dir/volume"
export REPRO_LOCK="$repro_dir/inherited.lock" REPRO_DB="$repro_db"
printf 'Evidence directory: %s\nDatabase: %s\n' "$repro_dir" "$repro_db"
cd "$repro_dir"

# Do not start/stop the master or any pre-existing database.
status=$(cubrid server status)
if [[ $status == *'master is not running'* ]]; then
  echo 'Start a dedicated CUBRID test environment before running this reproduction.' >&2
  exit 2
fi
if REPRO_DB="$repro_db" awk '$2 == ENVIRON["REPRO_DB"] {found=1} END {exit !found}' <<<"$status"; then
  echo 'Generated name already running; rerun to choose another name.' >&2
  exit 2
fi
created=0
cleanup()
{
  if [[ $created == 1 ]]; then
    timeout 30 cubrid server stop "$repro_db" >>"$repro_dir/cleanup.log" 2>&1 || true
    timeout 30 cubrid deletedb "$repro_db" >>"$repro_dir/cleanup.log" 2>&1 || true
  fi
}
trap cleanup EXIT
timeout 60 cubrid createdb --db-volume-size=20M --log-volume-size=20M \
  "$repro_db" en_US.utf8 -F "$repro_dir/volume" -L "$repro_dir/volume" >createdb.log 2>&1
created=1

# Output goes to a regular file so an inherited stdout pipe cannot mask the lock test.
timeout 30 bash >start.log 2>&1 <<'START'
  exec 9>"$REPRO_LOCK"
  flock -x 9
  cubrid server start "$REPRO_DB"
START
echo 'CUBRID start command and its launching shell have exited.'

if flock -n "$REPRO_LOCK" true; then
  echo 'NOT REPRODUCED: lock became available after the start command exited.'
  exit 1
else
  result=$?
  [[ $result == 1 ]] || exit "$result"
  echo 'REPRODUCED: lock is still held after the launcher exited.'
fi

# Record the exact process and descriptor that retain this unique lock file.
for proc_fd in /proc/[0-9]*/fd/*; do
  target=$(readlink "$proc_fd" 2>/dev/null) || continue
  if [[ $target == "$REPRO_LOCK" ]]; then
    pid=${proc_fd#/proc/}; pid=${pid%%/*}
    printf 'Inherited descriptor: %s -> %s\n' "$proc_fd" "$target"
    ps -p "$pid" -o pid=,comm=,args=
  fi
done

timeout 30 cubrid server stop "$repro_db" >stop.log 2>&1
flock -w 5 "$REPRO_LOCK" true
echo 'CONFIRMED: stopping only the test server released the inherited lock.'
timeout 30 cubrid deletedb "$repro_db" >deletedb.log 2>&1
created=0
echo 'Test database deleted; evidence files retained.'
```

## Expected Result

```text
시작 명령과 호출 셸 종료 후: flock -n "$REPRO_LOCK" true → 종료 코드 0
cub_server/cub_pl의 /proc/<pid>/fd: 해당 잠금 파일을 가리키는 FD 없음
테스트 서버: 실행 상태 유지
```

## Actual Result

```text
Evidence directory: /tmp/cbrd27443.UxrZ0uDY
Database: fdUxrZ0uDY
CUBRID start command and its launching shell have exited.
REPRODUCED: lock is still held after the launcher exited.
Inherited descriptor: /proc/3456033/fd/9 -> /tmp/cbrd27443.UxrZ0uDY/inherited.lock
3456033 cub_server      cub_server fdUxrZ0uDY
Inherited descriptor: /proc/3456039/fd/9 -> /tmp/cbrd27443.UxrZ0uDY/inherited.lock
3456039 cub_pl          cub_pl fdUxrZ0uDY
CONFIRMED: stopping only the test server released the inherited lock.
Test database deleted; evidence files retained.
```

## Additional Information

### 재현 판정과 정리

수록 스크립트는 결함이 재현되고 서버 종료 후 잠금 해제를 확인하면 0으로 끝난다. 수정본의 회귀 검사에서는 서버 실행 중 잠금 획득 성공을 정상 결과로 바꿔야 한다. 현재 스크립트의 1은 미재현 또는 작업 실패일 수 있으므로 출력과 작업 로그를 함께 확인한다.

20M 볼륨은 시험용 DB 크기를 줄이기 위한 값이다. 30·60초 timeout은 작업 대기 상한이며, `flock -w 5`는 종료 직후 잠금 해제를 확인하는 최대 대기 시간이다. 모두 결함 발생의 제품 임계값은 아니다. 출력은 일반 파일로 보내 잠금 시험에 출력 파이프가 개입하지 않도록 했다.

수록 스크립트는 ShellCheck를 통과했다. 이번 실행은 시작·종료 성공 로그와 DB 삭제 명령 성공을 확인했다. 기존 DB와 master에는 중지 명령을 보내지 않았다. EXIT trap의 정리 실패는 종료 코드에서 드러나지 않을 수 있으므로, 다른 환경에서 실패한 실행은 보존된 `cleanup.log`와 상태를 확인해야 한다.

### 수정 후보와 호환성 검토

아래는 AI 분석 후보이며 확정한 구현 방안이 아니다.

| 후보 | 적용 위치 | 고려사항 |
|---|---|---|
| 백그라운드 실행에 FD 보존 목록 도입 | 서비스별 fork/exec 경계 | 동기 유틸리티와 정책을 분리할 수 있다. 직접 cub_server 실행, PL, HA 재시작처럼 다른 경로도 포함할지 결정해야 한다. |
| 서버 자체의 초기 FD 정리 | 자체 자원을 열기 전 서버 진입부 | 직접 실행도 포괄한다. 이미 연 오류 로그·메시지 파일의 처리 순서와 감독 프로세스의 의도적인 전달을 검토해야 한다. |
| 내부 자원 생성 시 close-on-exec 적용 | 파일·소켓 생성부 | 서버 내부 FD의 PL·HA 전파를 줄이는 보완책이다. 외부 셸이 이미 넘긴 FD는 이것만으로 제거되지 않는다. |

구현 선택 시 지원 OS에서 사용할 수 있는 정리 API, 높은 FD 번호, 표준 FD 보존 정책, 다중 스레드 프로세스의 fork 이후 안전한 호출 범위를 검토한다. 공통 도우미에서 모든 FD를 무조건 닫는 변경은 아직 정당화되지 않았다.

### 추가 검증 항목

- 실제 배포할 수정본에서 일반 서버·PL의 시작과 재시작, 질의·저장 프로시저 실행을 확인한다.
- broker의 최초 실행과 내부 재시작, HA의 시작과 재기동, master의 daemon/비-daemon 모드를 각각 검증한다.
- 의도적인 소켓 전달과 표준 입출력 리다이렉션을 보존하는지 확인한다.
- pipe EOF(남은 데이터를 모두 읽고 모든 쓰기 끝이 닫혔을 때 확인하는 입력 종료) 대기는 아직 재현하지 않았다. 이번 잠금 결과를 파이프 멈춤이나 CUBRID 명령 자체의 무한 대기 증거로 사용하지 않는다.

### 소스 참조

- [서비스 실행 및 서버 시작](https://github.com/vimkim/cubrid/blob/38093ea859a8a08e20405b72b0cb395205bedb2f/src/executables/util_service.c#L867)
- [서버 세션 분리](https://github.com/vimkim/cubrid/blob/38093ea859a8a08e20405b72b0cb395205bedb2f/src/executables/server.c#L322)
- [PL 생성](https://github.com/vimkim/cubrid/blob/38093ea859a8a08e20405b72b0cb395205bedb2f/src/sp/pl_sr.cpp#L365), [공통 자식 프로세스 생성](https://github.com/vimkim/cubrid/blob/38093ea859a8a08e20405b72b0cb395205bedb2f/src/base/process_util.c#L262)
- [master 초기 FD 정리](https://github.com/vimkim/cubrid/blob/38093ea859a8a08e20405b72b0cb395205bedb2f/src/executables/master.c#L1677)
- [broker 관리 명령의 프로세스 생성](https://github.com/vimkim/cubrid/blob/38093ea859a8a08e20405b72b0cb395205bedb2f/src/broker/broker_admin_pub.c#L3158), [broker 내부 생성 시 FD 정리](https://github.com/vimkim/cubrid/blob/38093ea859a8a08e20405b72b0cb395205bedb2f/src/broker/broker.c#L1552)
- [HA 재시작](https://github.com/vimkim/cubrid/blob/38093ea859a8a08e20405b72b0cb395205bedb2f/src/executables/master_heartbeat.c#L3137), [일반 서버 재기동](https://github.com/vimkim/cubrid/blob/38093ea859a8a08e20405b72b0cb395205bedb2f/src/executables/master_server_monitor.cpp#L266)
