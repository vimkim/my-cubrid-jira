# [Master] cub_master 종료 중 서버 모니터 스레드 해제가 소켓 목록 잠금과 엇갈려 마스터가 멈출 수 있다

**한 줄 요약**: PR #8792(CBRD-28140) 코드 리뷰에서 소스 분석으로 찾은 기존 결함 의심 사항이다. `cubrid service stop`으로 마스터를 끄는 도중 서버 모니터 스레드를 정리하는 순서가 잘못되어 마스터가 교착에 빠지거나 해제된 모니터를 사용할 수 있는지 확인하고 고친다.

## Issue Triage

**이슈 수행 목적**: `auto_restart_server`가 켜진 환경에서 마스터 종료 요청이 서버 정지 요청과 겹쳐도, cub_master가 멈추거나 비정상 종료하지 않고 끝나게 한다.

**이슈 수행 이유**: 마스터의 메인 스레드는 소켓 목록 잠금(`css_Master_socket_anchor_lock`)을 잡은 채 종료 요청을 처리한다. 이때 서버 모니터 객체를 해제(`master_Server_monitor.reset ()`)하고, 소멸자는 모니터 스레드가 끝나기를 기다린다(join). 그런데 모니터 스레드는 SHUTDOWN_SERVER 작업을 처리할 때 같은 잠금을 잡으려 한다. 두 일이 겹치면 서로를 기다린다. 또한 해제 뒤에도 `auto_Restart_server`는 참으로 남아 있어, 이후 서버 종료 감지 경로가 빈 포인터로 작업을 넣을 수 있다.

**영향**: 조건이 맞으면 `cubrid service stop`(마스터 종료)이 끝나지 않는다. 그러면 마스터 포트와 소켓이 남아 다음 기동이나 운영 스크립트가 막힌다. 또는 종료 중 cub_master가 비정상 종료할 수 있다. **소스 분석으로만 확인했고 실행으로 재현하지 않았다.** 실제 발생 가능 시간 폭과 빈도는 미상이다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 재현 여부를 확인하고 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

소스 기준: `develop` a921084ab7df75af0d2f2fb762dd30c61ccc6495. CUBRID/cubrid#8792 head cc845fa345도 이 부분은 바뀌지 않았다. HA를 끄고 `auto_restart_server=yes`(기본값)일 때만 해당한다.

### 교착 의심 경로

| 행위자 | 순서 |
|---|---|
| 메인 스레드 M | `css_master_loop ()` → `css_check_master_socket_input ()`가 `css_Master_socket_anchor_lock`을 잡음(`master.c`) → `css_process_info_request ()` → `START_SHUTDOWN` → `css_process_shutdown ()` → `master_Server_monitor.reset ()` → `~server_monitor ()` → `stop_monitoring_thread ()` → `m_monitoring_thread->join ()` |
| 모니터 스레드 T | SHUTDOWN_SERVER 작업 → `server_monitor::shutdown_server ()` → `css_process_start_shutdown_by_name ()` → `pthread_mutex_lock (&css_Master_socket_anchor_lock)` |

T가 SHUTDOWN_SERVER 작업을 꺼낸 뒤 잠금을 얻기 전에 M이 잠금을 잡고 `reset ()`에 들어가면, M은 T의 종료를 기다리고 T는 M이 가진 잠금을 기다린다.

SHUTDOWN_SERVER 작업은 `css_process_shutdown_reviving_server ()`가 만든다. 이 함수는 `SHUTDOWN_REVIVING_SERVER` 요청을 처리한다. `cubrid server stop <db>`는 대상 서버가 마스터에 등록되어 있지 않을 때 이 요청을 보낸다(`util_service.c`의 `shutdown_reviving_server ()`). 모니터는 그 서버를 이미 다시 띄운 상태(재기동 대기 중)일 때만 `css_process_start_shutdown_by_name ()`을 호출한다. 따라서 "재기동 중인 서버에 대한 `cubrid server stop`" 직후 "마스터 종료"가 들어오는 경우가 후보다.

### 해제 뒤 사용 의심 경로

`css_process_shutdown ()`은 모니터를 해제한 뒤 `auto_Restart_server`를 바꾸지 않는다. 이어지는 `css_process_kill_master ()`는 마스터 소켓을 닫고 `er_final ()`을 호출하지만 프로세스를 바로 끝내지 않는다. 이후 `css_master_loop ()`가 한 번 더 돌면서 서버 연결 종료를 감지하면, `css_check_master_socket_input ()`의 REVIVE 경로가 `master_Server_monitor->produce_job (...)`을 빈 포인터로 호출할 수 있다. 메인 루프가 그 전에 끝나는지는 확인하지 못했다(ANALYSIS 확인 사항).

## Expected Result

- 마스터 종료 요청이 서버 정지 요청과 겹쳐도 cub_master가 제한된 시간 안에 종료한다.
- 모니터를 해제한 뒤에는 어떤 경로도 해제된 모니터에 작업을 넣지 않는다.

## Analysis Questions

- 실행으로 교착을 재현할 수 있는가? 제안 방법(미실행)은 다음과 같다. 그 뒤 마스터 프로세스가 끝나는지 확인한다.
  1. 디버거로 모니터 스레드를 `server_monitor::shutdown_server ()`의 잠금 호출 직전에 멈춘다.
  2. 재기동 중인 서버를 정지한다.
  3. `cubrid service stop`을 실행한다.
- `css_process_kill_master ()` 뒤 메인 루프가 다시 서버 연결 종료를 처리하는 일이 실제로 일어나는가?

## Additional Information

- 관련: CBRD-28140(PR #8792 코드 리뷰 중 발견, 해당 PR의 변경 범위 밖).
