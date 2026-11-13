# [Broker] cubrid broker info가 REJECT_CLIENT_FLAG 자리에 CCI_DEFAULT_AUTOCOMMIT 값을 출력하는 문제

**한 줄 요약**: CodeQL `cpp/useless-expression` 경고를 확인하다가, `cubrid broker info`가 브로커의 실제 접속 거부 상태 대신 바로 앞 줄의 `CCI_DEFAULT_AUTOCOMMIT` 값을 `REJECT_CLIENT_FLAG`로 출력하는 것을 debug 빌드에서 재현했다. 출력이 실제 거부 상태를 보여 주도록 고쳐야 한다.

## Issue Triage

**이슈 수행 목적**: `cubrid broker info`의 `REJECT_CLIENT_FLAG` 줄이 브로커 공유 메모리의 실제 `reject_client_flag` 값(hang 감시가 클라이언트 접속을 거부하는 중인지)을 보여 주게 한다.

**이슈 수행 이유**: `src/broker/broker_config.c`의 `broker_config_dump ()`는 `REJECT_CLIENT_FLAG`를 출력할 때 `get_conf_string ()`의 반환값을 `tmp_str`에 대입하지 않고 버린다. 그래서 직전에 `CCI_DEFAULT_AUTOCOMMIT`을 출력하려고 구한 문자열이 그대로 출력된다. 독립 브로커를 띄워 확인한 결과, `ENABLE_MONITOR_HANG=OFF`라서 접속 거부가 일어날 수 없는 상태에서도 `CCI_DEFAULT_AUTOCOMMIT=ON`이면 `REJECT_CLIENT_FLAG=ON`, `OFF`이면 `REJECT_CLIENT_FLAG=OFF`가 출력되었다.

**영향**: 운영자와 QA가 `cubrid broker info`로 브로커가 hang 때문에 접속을 거부하는지 판단하면 잘못된 결론을 내린다. 기본 설정(`CCI_DEFAULT_AUTOCOMMIT=ON`)에서는 정상 브로커가 항상 거부 중(`ON`)으로 보인다. 반대로 autocommit을 `OFF`로 둔 브로커가 실제로 접속을 거부할 때는 `OFF`로 보일 것이다. 이 반대 경우는 코드로 판단했으며 hang을 일으켜 관찰하지는 않았다. 실제 접속 거부 동작(`broker.c`의 accept 경로)은 공유 메모리의 플래그를 직접 읽으므로 영향받지 않는다. 출력만 틀린다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

`REJECT_CLIENT_FLAG`는 `cubrid_broker.conf`의 파라미터가 아니다. 브로커 설정을 읽을 때 `false`로 초기화되고(`broker_config.c:1085`), 실행 중에는 `ENABLE_MONITOR_HANG=ON`인 브로커의 hang 감시 스레드가 hang 상태인 CAS/proxy 수에 따라 켜거나 끈다(`broker.c:2293-2305`). 이 값이 켜져 있으면 브로커는 새 클라이언트 접속을 받자마자 닫고 `REJECTED_CLIENTS_COUNT`를 늘린다(`broker.c:830-834`). 따라서 broker.conf로 이 값을 설정하는 재현은 불가능하며, 운영자가 이 상태를 보는 방법은 `cubrid broker info` 출력뿐이다.

`cubrid broker info`는 `admin_info_cmd ()`(`broker_admin_pub.c:1308`)에서 공유 메모리의 브로커 정보를 `broker_config_dump ()`로 출력한다. 문제의 코드는 다음과 같다.

```c
/* src/broker/broker_config.c:1785-1797 (develop e64a04a79a) */
      tmp_str = get_conf_string (br_info[i].cci_default_autocommit, tbl_on_off);
      if (tmp_str)
	{
	  fprintf (fp, "CCI_DEFAULT_AUTOCOMMIT\t=%s\n", tmp_str);
	}

      fprintf (fp, "MONITOR_HANG_INTERVAL\t=%d\n", br_info[i].monitor_hang_interval);
      fprintf (fp, "HANG_TIMEOUT\t\t=%d\n", br_info[i].hang_timeout);
      get_conf_string (br_info[i].reject_client_flag, tbl_on_off);
      if (tmp_str)
	{
	  fprintf (fp, "REJECT_CLIENT_FLAG\t=%s\n", tmp_str);
	}
```

1793행의 반환값이 버려지므로 `tmp_str`은 1785행에서 구한 `CCI_DEFAULT_AUTOCOMMIT` 문자열을 그대로 가리킨다. `git log -L`로 보면 이 코드는 2014년 저장소 이관 커밋(`6522201dab`) 때부터 같은 형태다.

### Test Build

- 정적 분석: CodeQL 2.27.4, 질의 `cpp/useless-expression`, build-mode none, CUBRID develop `e64a04a79a`. 이 질의는 오탐이 많아 `cubrid-bugs.qls`에서는 빠졌으나, 질의 선별 과정에서 이 경고는 실제 결함으로 분류되었다.
- 재현: 이미 설치되어 있던 CUBRID 11.5.0.2635-30043f4 (64bit debug build, GCC, Linux). `30043f4`는 `e64a04a79a`의 조상이며, 두 리비전 사이에 `broker_config.c`, `broker_admin_pub.c`, `broker_admin.c`는 바뀌지 않았다. `broker.c`의 변경은 hang 감시와 접속 거부 코드에 닿지 않는다. `e64a04a79a` 빌드에서는 실행하지 않았다.

### Repro

DB 서버나 cub_master 없이 브로커만 띄운다. 다른 브로커와 겹치지 않도록 `MASTER_SHM_ID`, `BROKER_PORT`, `APPL_SERVER_SHM_ID`와 로그 경로를 따로 정하고, `CUBRID_BROKER_CONF_FILE`로 설정 파일을 지정한다. `<dir>`은 쓰기 가능한 임시 디렉터리다.

```ini
# <dir>/broker_ac_on.conf
[broker]
MASTER_SHM_ID           =47801
ADMIN_LOG_FILE          =<dir>/log/cubrid_broker.log

[%rcf_test]
SERVICE                 =ON
BROKER_PORT             =47811
MIN_NUM_APPL_SERVER     =1
MAX_NUM_APPL_SERVER     =1
APPL_SERVER_SHM_ID      =47812
LOG_DIR                 =<dir>/log/sql_log
ERROR_LOG_DIR           =<dir>/log/error_log
SQL_LOG                 =ON
KEEP_CONNECTION         =AUTO
CCI_DEFAULT_AUTOCOMMIT  =ON
ENABLE_MONITOR_HANG     =OFF
```

`<dir>/broker_ac_off.conf`는 `CCI_DEFAULT_AUTOCOMMIT =OFF`만 다르다.

```sh
export CUBRID_BROKER_CONF_FILE=<dir>/broker_ac_on.conf
cubrid broker start
cubrid broker info | grep -E 'ENABLE_MONITOR_HANG|REJECTED_CLIENTS_COUNT|CCI_DEFAULT_AUTOCOMMIT|REJECT_CLIENT_FLAG'
cubrid broker stop
```

같은 명령을 `broker_ac_off.conf`로 반복한다.

### Expected Result

`ENABLE_MONITOR_HANG=OFF`이면 hang 감시가 돌지 않아 `reject_client_flag`는 초기값 `false`로 남는다. 두 설정 모두 `REJECT_CLIENT_FLAG\t=OFF`가 출력되어야 한다.

### Actual Result

`REJECT_CLIENT_FLAG`가 `CCI_DEFAULT_AUTOCOMMIT` 값을 따라간다.

```text
# broker_ac_on.conf
ENABLE_MONITOR_HANG	=OFF
REJECTED_CLIENTS_COUNT	=0
CCI_DEFAULT_AUTOCOMMIT	=ON
REJECT_CLIENT_FLAG	=ON

# broker_ac_off.conf
ENABLE_MONITOR_HANG	=OFF
REJECTED_CLIENTS_COUNT	=0
CCI_DEFAULT_AUTOCOMMIT	=OFF
REJECT_CLIENT_FLAG	=OFF
```

두 경우 모두 `cubrid broker start`, `info`, `stop`은 성공했다.

### Additional Information

관련 이슈: 다른 `cubrid broker info` 출력 누락을 다룬 [CBRD-23715](https://jira.cubrid.org/browse/CBRD-23715)(SSL, 10.2.1)와 [CBRD-24142](https://jira.cubrid.org/browse/CBRD-24142)(DBLink, 11.0.5)는 이 문제를 다루지 않았다. 다만 CBRD-23715에 붙은 10.2.1 출력에도 `ENABLE_MONITOR_HANG=OFF`, `CCI_DEFAULT_AUTOCOMMIT=ON`인 브로커에서 `REJECT_CLIENT_FLAG=ON`이 찍혀 있어, 같은 증상이 그 버전에도 있었음을 보여 준다. CBRD-24142의 출력에도 `REJECT_CLIENT_FLAG =ON`이 보이지만, 그 브로커의 hang 감시 설정은 출력에 없어 판단할 수 없다.

ANALYSIS에서 확인할 사항:

- hang 감시가 실제로 접속을 거부하는 상태(`ENABLE_MONITOR_HANG=ON`, `CCI_DEFAULT_AUTOCOMMIT=OFF`, CAS hang 유도)에서 `REJECT_CLIENT_FLAG=OFF`가 출력되는지. 이번 재현에서는 hang을 일으키지 않았다.
- `cubrid broker info` 출력을 파싱하는 도구(CMS, CUBRID Manager, QA 스크립트 등)가 `REJECT_CLIENT_FLAG` 값을 사용하는지. 사용한다면 그 도구의 판단도 같은 영향을 받는다.
- 회귀 테스트로 `ENABLE_MONITOR_HANG=OFF`, `CCI_DEFAULT_AUTOCOMMIT=ON`에서 `REJECT_CLIENT_FLAG=OFF`를 확인하는 shell 테스트를 추가할지.
