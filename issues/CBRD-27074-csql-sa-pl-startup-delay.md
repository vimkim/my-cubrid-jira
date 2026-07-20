# [CSQL] SA 모드 PL 시작의 고정 지연 제거

## Issue Triage

**이슈 수행 목적**: `csql -S` 가 PL 서버 준비 상태에 맞춰 즉시 진행하도록 바꾸고, 정상 시작 때마다 발생하는 약 2초의 고정 지연을 제거한다.

**이슈 수행 이유**:

| 구분 | 동작과 영향 |
|---|---|
| **AS-IS (현재 동작 / 배경)** | PL 함수 1회 실행에 약 2.51초가 걸린다. JVM은 약 0.39초에 준비되지만 명령은 실제 상태와 무관하게 약 2초를 더 소비한다. |
| **TO-BE (목표 상태 / 기대 동작)** | 실제 PL 준비가 끝나면 고정 최소 대기 없이 SQL 실행으로 넘어가고, Linux PL 자식은 DB 부모가 끝날 때 함께 정리된다. |
| **영향** | 성능 저하 - `csql -S`, SA 유틸리티, 관련 테스트가 실행될 때마다 불필요한 약 2초를 지불한다. 로컬 측정에서는 전체 실행 시간이 약 79% 줄었다. |

**이슈 수행 방안**: 사용자가 요청한 "`sleep(1)` workaround 제거"에 따라 시간 경과가 아니라 현재 자식의 준비 상태와 부모 생존 상태를 직접 확인한다. 기존 10초 준비 제한, JVM 시작 실패 처리, `UDS`(Unix domain socket)/TCP 연결, Windows 및 비 Linux Unix 동작은 유지한다.

---

## AI-Generated Context

> 아래는 AI가 코드와 실행 결과를 분석해 작성한 상세 자료다. 빠른 triage에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현과 리뷰 단계에서 참고하면 된다.

### 변경 범위

- `src/sp/pl_sr.cpp`, `src/executables/pl.cpp`, `src/base/process_util.c`, `src/base/process_util.h` 만 변경한다.
- SQL 문법, 저장 프로시저 API, 카탈로그, 디스크 형식, 통신 프로토콜은 바뀌지 않는다.
- Linux SA/SERVER 모드의 시작 시간과 PL 자식 수명 관리가 직접 영향을 받는다. UDS와 TCP 연결을 모두 검증한다. Windows는 기존 process handle 대기를 유지하며 오류 처리를 보완한다.

## Description

`SA`(standalone mode - DB 서버 기능을 유틸리티 프로세스 안에서 실행하는 모드)는 실행할 때마다 `PL`(Procedural Language - 저장 프로시저를 실행하는 JVM 서버)을 자식 프로세스로 시작한다. 현재 시작 흐름에는 서로 다른 목적으로 추가된 1초 대기가 세 곳에 있다.

```text
csql -S
  |
  |- 이전 PL 연결 주소 ping 실패
  |    `- 1초 대기                         [시작 지연 1]
  |
  |- fork cub_pl
  |    |- 자식: JVM 시작
  |    `- 부모: 1초 대기                   [시작 지연 2]
  |
  `- ping/bootstrap 후 SQL 실행

cub_pl
  `- PPID(부모 프로세스 ID) 변경 확인
       `- 1초 대기 후 반복                 [종료 감지 지연]
```

첫 번째 대기는 이전 SA 실행의 PL이 아직 종료 중인지 확인하려고 CBRD-25925에서 보강한 재시도 경로에 있다. 새로 시작하는 일반 상황에서는 연결 대상이 없으므로 첫 ping이 실패하고 반드시 1초를 기다린다.

두 번째 대기는 CBRD-25796에서 PL 생성을 DB boot 앞부분으로 옮길 때 추가됐다. 대량 메모리 할당 뒤 `fork()` 가 실패하는 문제를 피하려는 변경이었고, 자식이 초기화할 시간을 주기 위해 생성 직후 1초를 기다렸다. 그러나 실제 준비 조건은 뒤의 PL info 읽기와 ping이 이미 확인한다.

세 번째 대기는 CBRD-25931에서 Linux와 WSL의 부모 변경을 감지하려고 추가됐다. 이 대기는 JVM 시작과 동시에 실행되므로 성공한 시작의 1초 지연 원인은 아니지만, 부모가 끝난 뒤 PL 자식이 최대 1초 더 남을 수 있다.

> **요지**: 시간 경과를 동기화 조건으로 사용한 것이 원인이다. 이전 프로세스 존재 여부, 새 연결 주소 공개, ping 성공, 부모 종료는 모두 직접 관찰할 수 있으므로 고정 1초 대기가 필요하지 않다.

관련 변경 이력은 다음과 같다.

| 이슈 | 보존해야 할 동작 |
|---|---|
| CBRD-25660 | PL 자식은 DB 프로세스에 종속되며 부모와 함께 종료된다. |
| CBRD-25712 | JVM 시작에 실패한 자식은 비정상 상태를 나타내는 dummy(실제 JVM 없이 상태만 유지하는) 프로세스로 남을 수 있다. |
| CBRD-25796 | 큰 메모리 할당 전에 PL 자식을 생성하고 `fork()` 실패를 처리한다. |
| CBRD-25908 | 실행 중인 DB의 PL을 SA 유틸리티가 종료하지 않는다. |
| CBRD-25925 | 이전 SA PL이 종료 중이면 새 시작이 잘못 연결되지 않도록 재시도한다. |
| CBRD-25931 | Linux/WSL에서 최초 부모가 사라지면 PL 자식이 종료된다. |

## Specification Changes

사용자 SQL과 설정 파라미터의 스펙 변경은 없다. 내부 시작 및 종료 시점만 다음과 같이 바뀐다.

| 내부 동작 계약 | 변경 후 동작 |
|---|---|
| SA 이전 PL 확인 | 한 번 즉시 확인하고 진행한다. |
| 새 PL 준비 확인 | 현재 자식 PID의 info와 ping 성공까지 재시도한다. |
| 준비 제한 | exponential backoff(재시도 간격을 점차 늘리는 방식)를 사용하되 전체 10초 제한을 유지한다. |
| Linux 부모 종료 | 커널이 자식에 `SIGKILL` 을 전달한다. |
| 비 Linux Unix | 기존 PPID polling을 유지한다. |
| Windows | 기존 process handle 대기를 유지하고 handle/wait 실패 시 끝낸다. |

## Implementation

### 자식 수명 설정

`create_child_process()` 에 Linux 부모 종료 알림 설정 여부를 추가한다. `server_monitor_task` 만 이 옵션을 켠다.

```text
부모: getpid()
  `- fork()
       `- 자식: prctl(PR_SET_PDEATHSIG, SIGKILL)
            |- 실패 -> 즉시 종료
            |- 설정 전에 부모가 바뀜 -> 즉시 종료
            `- exec cub_pl
```

`PR_SET_PDEATHSIG` 는 일반 `execve()` 뒤에도 유지된다. 설정 직후 `getppid()` 를 다시 확인해 부모가 `fork()` 와 `prctl()` 사이에 끝난 경우를 처리한다.

`SIGKILL` 은 PL이 DB 부모보다 오래 남지 않아야 한다는 수명 규칙을 우선한다. 기존 `SIGTERM` handler는 info 파일의 PID가 바뀌면 종료하지 않을 수 있으며, 기존 PPID 변경 경로도 JVM의 정상 종료 절차를 수행하지 않았다.

### 준비 상태 확인

`do_check_connection(timeout_ms)` 는 매번 초기화한 `PL_SERVER_INFO` snapshot(한 번에 읽은 PID와 port 묶음)을 사용한다. 새 자식을 만든 뒤에는 `pl_info.pid == m_pid` 인 경우에만 해당 연결 주소를 connection pool(PL 연결 재사용 객체)에 적용하고 ping한다. 따라서 이전 PL의 PID나 TCP random port를 새 자식의 정보로 받아들이지 않는다.

재시도 간격은 `10, 20, 40, 80, 160, 320, 500...ms` 이며 최대 500ms로 제한한다. 전체 제한은 기존과 같은 10초다. 연결에 성공하거나 자식이 종료되면 즉시 반환한다.

### Linux 대기 루프

Linux `cub_pl` 의 PPID 비교와 `sleep(1)` 을 제거하고 `pause()` 로 바꾼다. 부모 종료는 커널의 `SIGKILL` 로 처리하므로 주기적으로 깨어날 필요가 없다. 비 Linux Unix에는 기존 fallback을 남긴다.

## Verification

테스트 빌드는 `CUBRID 11.5.0.2323-4caf6b9`, Linux x86_64 debug GCC 환경이다.

| 검증 | 결과 |
|---|---|
| Linux SA/CS/SERVER 및 `cub_pl` 빌드, Java PL 빌드 | 통과 |
| UDS cold `SELECT tf()` 10회 | 0.50-0.55초, 평균 0.527초, 10회 모두 42 반환 |
| `SELECT 1` 과 `SELECT tf()` SA 연속 실행 30쌍 | 60개 명령 모두 통과, 잔여 PL 없음 |
| TCP SA cold 실행 10회 | 10회 모두 통과 |
| `cubrid pl restart` | PID 교체 후 PL 함수 실행 통과 |
| 정상 server stop | 명령 반환 시 PL 자식 없음 |
| server `SIGKILL` | 기존 PL 자식 12ms 안에 종료, server/PL 자동 재시작 뒤 함수 실행 통과 |
| 잘못된 `CUBRID_JAVA_HOME` 으로 15초 제한 실행 | 예상 timeout, dummy PL 잔여 없음, 다음 정상 실행 통과 |
| CTP CBRD-25908 shell test | 1/1 통과 |
| 코드 형식과 whitespace 검사 | 통과 |

Linux process trace에서는 부모 종료 뒤 약 7.2ms 후 `cub_pl` 의 `SIGKILL` 종료가 관찰됐고, 변경한 Linux 경로에 1초 sleep이 남지 않았다.

## Acceptance Criteria

- [x] 일반 UDS 환경에서 `csql -S` PL 함수 실행이 고정 2초 대기 없이 성공한다.
- [x] TCP random port 환경에서도 현재 자식의 endpoint에 연결한다.
- [x] 이전 PL 정보가 남아 있어도 새 자식과 혼동하지 않는다.
- [x] 정상 및 비정상 DB 부모 종료 뒤 Linux `cub_pl` 이 남지 않는다.
- [x] `cubrid pl restart` 와 CBRD-25908 동작을 보존한다.
- [x] JVM 시작 실패 뒤 부모가 끝나면 dummy PL이 남지 않으며 다음 실행이 복구된다.
- [ ] Windows 빌드와 runtime 회귀를 CI에서 확인한다.
- [ ] SQL/medium/shell CI를 통과한다.

## Definition of done

- [x] 위 로컬 수락 조건을 확인한다.
- [x] 원인, 변경 흐름, race와 제한 사항을 상세 문서로 남긴다.
- [ ] CUBRID CI를 통과한다.
- [ ] 코드 리뷰에서 Linux creating-thread semantics와 `SIGKILL` 선택을 확인한다.
- [x] SQL/설정/매뉴얼 스펙 변경 없음임을 확인한다.

## Remarks

- Linux `PR_SET_PDEATHSIG` 는 `fork()` 를 호출한 thread의 종료에도 반응한다. SERVER 모드의 monitor thread가 수명 동안 유지된다는 전제를 리뷰해야 한다.
- 부모 process는 살아 있지만 creating thread가 `prctl()` 설정 전에 끝나는 매우 좁은 경우는 `getppid()` 로 구분할 수 없다. 현재 monitor 수명 구조에서는 관찰되지 않았다.
- 비 Linux Unix의 1초 PPID polling은 portability fallback으로 남는다.
- 전체 분석과 측정값은 PR의 `CSQL_SA_PL_STARTUP_REPORT.md` 에 기록한다.
