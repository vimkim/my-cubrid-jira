# [CBRD-27443] 백그라운드 서버가 호출자의 파일 디스크립터를 유지해 후속 명령의 잠금 획득을 막음

## Issue Triage

**이슈 수행 목적**: 대화형 도구(interactive tool)와 AI agent에서 CUBRID 시작·종료 작업을 호출했을 때, 정상적인 처리가 끝나면 호출 도구도 완료를 확인하고 다음 작업으로 진행할 수 있도록 한다. 이를 위해 백그라운드 서버가 호출자의 불필요한 파일 디스크립터(FD, 열린 파일이나 통신 통로를 가리키는 번호)를 계속 붙잡는 결함을 수정한다.

**이슈 수행 이유**:

| 현재와 목표 | 내용 |
|---|---|
| **AS-IS (현재 동작 / 배경)** | 사용자는 대화형 도구와 특히 AI agent에서 `cubrid server start`, `cubrid server stop` 등을 호출할 때, 금방 끝날 것으로 예상한 작업을 끝없이 기다리는 사례를 경험적으로 여러 번 겪었다고 보고했다. 독립 시험에서는 시작 명령과 호출 셸이 종료된 뒤에도 백그라운드 프로세스가 호출자의 잠금 파일을 유지하는 현상을 확인했다. |
| **TO-BE (목표 상태 / 기대 동작)** | 서버가 계속 실행 중이어도 시작을 요청한 도구의 작업은 완료되어야 하며, 호출자 전용 잠금이 후속 명령을 막아서는 안 된다. 복구·종료 처리에 실제로 필요한 대기와, 처리가 끝나도 호출 도구가 빠져나오지 못하는 대기를 구분한다. |

**영향**: 운영 도구와 자동화 작업의 진행이 막힌다. 사람이 메뉴에서 DB를 선택해도 응답을 기다리게 되고, AI agent가 명령 완료를 기다리는 동안 후속 질의·테스트·정리 작업도 시작할 수 없다. CUBRID를 다른 도구에서 안정적으로 실행하고 자동화하는 데 직접 영향을 준다. 위 반복 경험은 사용자의 보고이며, 모든 사례를 같은 FD 문제로 재현하거나 실제 무한 대기로 입증한 것은 아니다.

**이슈 수행 방안**: 이슈 유형은 `Correct Error`로 유지한다. 소스 검토상 **백그라운드 프로세스의 불필요한 FD 정리가 빠진 구현 결함이 유력하다**. 일반 master(서버 등록·연결 관리 프로세스)에는 같은 목적의 정리 코드가 이미 있어, 이번 현상을 의도된 제품 정책으로 볼 근거는 부족하다. 다만 특정 사람의 코딩 실수인지와 누락의 도입 경위는 확정하지 않았다. 구체적인 수정 위치·보존할 FD·표준 입출력 처리 정책은 `TBD - 합의 미확인`이다.

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### 변경 범위

조사 대상은 Unix 계열 서비스 실행부, 서버 진입부, PL(저장 프로시저 실행 프로세스) 생성부, master, broker(클라이언트 연결 중개 프로세스), HA(고가용성) 프로세스 관리부다. Windows 동작은 이번 분석에서 검증하지 않았다. 엔진 코드는 수정하지 않았다.

## Description

### 실제 사용에서 드러난 문제와 중요성

2026-09-15 사용자는 다음과 같이 추가 보고했다.

> "특히 ai agent 에서 cubrid server stop, cubrid server start 등을 호출했을 때, 금방 끝나야 하는 작업임에도 불구하고 무한정 기다려서 문제가 발생하는 시나리오가 경험적으로 많았다는 사실"

이 진술은 반복해서 겪은 사용 경험을 기록한 것이다. 발생 횟수·각 사례의 대기 시간·당시 프로세스 상태를 모두 수집한 통계는 아니다. 여기서 '금방 끝나야 하는 작업'은 사용자가 당시 환경에서 예상한 소요 시간을 뜻한다. 시작 시 복구나 종료 시 정리 작업 때문에 합당하게 오래 걸리는 경우까지 결함으로 분류하지 않는다.

대화형 도구는 사용자가 선택한 동작을 하위 명령으로 실행하고 그 결과를 받아 화면을 갱신한다. AI agent도 명령 호출 결과를 받아야 성공 여부를 판단하고 다음 단계를 수행한다. 이때 **CUBRID의 작업이 끝나는 것과 호출 도구가 완료를 확인하는 것은 별개**다. 자식 프로세스의 종료 외에도 잠금 획득이나 출력 수집을 기다리는 실행 방식에서는, 다른 프로세스에 남은 자원이 전체 호출을 붙잡을 수 있다.

예를 들어 `서버 시작 → SQL 시험 → 서버 종료 → 결과 보고`라는 자동화에서 첫 호출의 완료를 받지 못하면 이후 단계는 실행되지 않는다. 사용자에게는 DB 자체가 시작하지 못한 것처럼 보일 수 있어, DB 상태 확인과 도구의 대기 원인 확인을 따로 해야 한다. 시간 제한을 늘리는 것만으로 남아 있는 자원 참조가 사라지지는 않는다.

### 관찰한 대기와 아직 확인하지 못한 원인

| 구분 | 근거와 해석 |
|---|---|
| 대화형 DB 종료 선택기에서 확인한 대기 | 이전 조사 기록에서 `fzf`(대화형 목록 선택 도구)로 DB를 고른 뒤 실행 래퍼가 `flock -w 300`에서 대기했다. 300초는 그 래퍼에 설정된 잠금 대기 상한이다. 당시 서버가 같은 잠금 파일의 FD 10을 상속해 유지하고 있었으며, `cubrid server stop` 본체는 아직 실행되지 않았다. |
| 사용자 경험으로 보고된 start/stop의 끝없는 대기 | 각 사례에서 CUBRID 명령 본체가 실행 중이었는지, 실행 전 잠금을 기다렸는지, 종료 후 출력 수집을 기다렸는지는 아직 분류하지 못했다. 앞 행의 유한한 대기를 곧바로 모든 사례의 무한 대기 원인으로 확대하지 않는다. |
| 출력 파이프에 대한 원인 후보 | 출력을 파이프(프로세스 사이의 데이터 통로)로 모으는 도구가 EOF(입력 종료)를 기다릴 경우, 백그라운드 프로세스에 쓰기 FD가 남으면 실행한 명령이 끝나도 출력 수집이 끝나지 않을 수 있다. OS 동작에 따른 가능한 설명이며 CUBRID에서의 해당 대기는 아직 독립 재현하지 않았다. |

파이프는 남은 데이터를 읽은 뒤 모든 쓰기 FD가 닫혀야 EOF를 전달한다. 따라서 위 출력 수집 후보는 잠금 시험과 별도로 검증해야 한다. [pipe(7)](https://man7.org/linux/man-pages/man7/pipe.7.html)

또한 소스의 `server stop` 경로는 `util_service.c:1835`에서 종료 요청 도구를 동기 실행한다. 서버를 생성하는 `start` 경로와 다르므로, 종료 호출이 멈췄다는 경험만으로 `stop` 자체가 같은 FD를 유출했다고 판단할 수 없다. 이번 독립 시험에서는 래퍼의 잠금을 거치지 않고 테스트 서버를 직접 중지하는 데 성공했다.

### 설계 선택인지 코딩 누락인지

판단 대상은 호출자가 우연히 넘긴 전용 FD다. 아래 근거는 그 FD를 서버가 계속 보존할 기능적 필요를 찾지 못했음을 보여준다.

| 검토 근거 | 판단에 미치는 의미 |
|---|---|
| `master.c:1678`의 주석은 부모 셸에서 상속한 불필요한 FD를 daemon이 계속 열어 두지 않도록 닫는다고 명시한다. 바로 아래에 실제 정리 루프가 있다. | 자원 정리의 필요성은 CUBRID 내부에서 이미 인식하고 구현한 내용이다. |
| 일반 서버는 세션 분리 후 실행을 계속하며, 서버 생성 도우미와 PL 생성 도우미에는 일반 상속 FD 정리가 없다. | 현재까지의 증거는 서버·PL 실행 경계에서 자원 정리가 누락됐다는 해석을 지지한다. |
| 잠금 파일은 CUBRID 설정이나 명령 인수로 전달하지 않았는데도 독립 시험에서 유지됐다. | 서버가 기능 수행에 사용하도록 요청받은 자원이라는 근거가 없다. |
| 같은 실행 도우미를 동기 유틸리티도 사용하고, 제품 내부에는 명시적인 소켓 전달도 존재한다. | 공통 도우미의 FD 상속 자체를 모두 잘못된 코드로 볼 수는 없다. 백그라운드 실행에 필요한 정리 책임이 어느 경계에 빠졌는지를 찾아야 한다. |

**현 단계의 기술적 판단은 자원 수명 관리의 구현 누락이며, 코딩 과정에서 필요한 정리를 빠뜨린 실수일 가능성이 높다.** 다만 코드와 재현만으로 작성자의 의도나 특정 개인의 실수를 확정할 수는 없다. 수정 대상 행의 작성자를 보여 주는 Git 이력도, 애초에 추가되지 않은 정리 코드의 누락 책임까지 증명하지는 않는다.

확인된 일반 FD 문제와 표준 출력·오류의 처리 정책은 구별해야 한다. master도 표준 FD 0·1·2는 남기도록 명시하고 있기 때문이다. 향후 출력 파이프 대기가 재현된다면, 해당 실행 모드의 로그 전달 계약을 검토해 별도로 원인을 판정해야 한다. 수정 방법을 정할 때 호환성 설계가 필요하다는 사실은, 확인된 자원 정리 누락을 기능 개선 과제로 바꿔 분류할 근거가 되지 않는다.

### FD가 유지되는 동작 원리

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
- 사용자 경험의 대기 사례를 실행 전 잠금·명령 본체 실행·종료 후 출력 수집으로 분류하고, Description의 출력 파이프 후보를 별도 시험으로 검증한다.

### 소스 참조

- [서비스 실행 및 서버 시작](https://github.com/vimkim/cubrid/blob/38093ea859a8a08e20405b72b0cb395205bedb2f/src/executables/util_service.c#L867)
- [서버 세션 분리](https://github.com/vimkim/cubrid/blob/38093ea859a8a08e20405b72b0cb395205bedb2f/src/executables/server.c#L322)
- [PL 생성](https://github.com/vimkim/cubrid/blob/38093ea859a8a08e20405b72b0cb395205bedb2f/src/sp/pl_sr.cpp#L365), [공통 자식 프로세스 생성](https://github.com/vimkim/cubrid/blob/38093ea859a8a08e20405b72b0cb395205bedb2f/src/base/process_util.c#L262)
- [master 초기 FD 정리](https://github.com/vimkim/cubrid/blob/38093ea859a8a08e20405b72b0cb395205bedb2f/src/executables/master.c#L1677)
- [broker 관리 명령의 프로세스 생성](https://github.com/vimkim/cubrid/blob/38093ea859a8a08e20405b72b0cb395205bedb2f/src/broker/broker_admin_pub.c#L3158), [broker 내부 생성 시 FD 정리](https://github.com/vimkim/cubrid/blob/38093ea859a8a08e20405b72b0cb395205bedb2f/src/broker/broker.c#L1552)
- [HA 재시작](https://github.com/vimkim/cubrid/blob/38093ea859a8a08e20405b72b0cb395205bedb2f/src/executables/master_heartbeat.c#L3137), [일반 서버 재기동](https://github.com/vimkim/cubrid/blob/38093ea859a8a08e20405b72b0cb395205bedb2f/src/executables/master_server_monitor.cpp#L266)
