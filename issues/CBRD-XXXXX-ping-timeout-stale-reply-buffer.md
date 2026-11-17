# [Network] 서버 ping이 timeout되면 응답 버퍼 등록이 남아, request id가 한 바퀴 돈 뒤 CAS가 비정상 종료한다

**한 줄 요약**: Sidecar PR #8504의 로컬 SQL 회귀 실행에서 CAS가 비정상 종료한 원인을 추적하다 확인한 develop 결함으로, `net_client_ping_server`가 timeout으로 끝날 때 큐에 등록한 스택 응답 버퍼를 빼지 않아 같은 request id를 받은 나중 요청이 사라진 스택 주소를 쓰거나 free하는 문제를 다룬다.

## Issue Triage

**이슈 수행 목적**: 서버 ping이 timeout이나 수신 오류로 끝나도 그 연결의 이후 요청이 정상적으로 응답을 받게 하여, ping 실패 한 번이 CAS 비정상 종료나 잘못된 오류로 이어지지 않게 한다.

**이슈 수행 이유**: 현재 develop 소스에서 `net_client_ping_server`는 스택 변수 `reply_buf`를 연결의 `buffer_queue`에 등록한 뒤 응답을 기다린다. timeout이 나면 그 등록을 빼지 않고 반환한다. 이후 16비트 request id가 한 바퀴 돌아 같은 id가 다시 쓰이면 그 요청은 큐에 남은 죽은 스택 주소를 자기 응답 버퍼로 받는다. debug 빌드 CAS에서 이 경로로 SIGSEGV, `free()` abort, `-187`을 직접 재현했고, Sidecar 코드가 없는 develop 커밋에서도 같은 abort를 확인했다.

**영향**: 응용 프로그램과 QA 실행은 서버가 잠시(5초 이상) 응답하지 못한 뒤, 같은 CAS 연결의 나중 요청에서 CAS 비정상 종료나 `-187 Communications buffer not used` 오류를 겪는다. 실패는 원인이 된 ping보다 수천 요청 뒤에 나타나므로 원인을 찾기 어렵다. 재현은 debug 빌드와 로컬 SQL 회귀 실행에서만 했다. release 빌드에서의 증상, 운영 환경 발생 빈도, 같은 함수를 부르는 HA `applylogdb`(log_applier.c)의 영향은 확인하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

클라이언트 모듈은 요청을 보낼 때 request id를 붙이고, 호출자가 준 응답 버퍼를 연결의 `buffer_queue`에 그 id로 등록한다. 응답이 오면 같은 id의 첫 등록 버퍼에 받는다.

`net_client_ping_server`(src/communication/network_cl.c)는 응답 버퍼로 자기 스택 변수 `reply_buf`를 등록하고 `css_receive_data_from_server_with_timeout`으로 기다린다. CAS는 `ux_check_connection`(src/broker/cas_execute.c)에서 `db_ping_server`를 거쳐 5000ms timeout으로 이 함수를 부른다. 수신이 실패하면 함수는 `ER_NET_SERVER_DATA_RECEIVE`를 반환하지만 `buffer_queue`의 등록은 그대로 남는다. 함수가 반환하면 그 스택 주소는 다른 호출의 프레임이 쓴다.

남은 등록은 이후에도 정리되지 않는다.

- `tran_server_commit`마다 부르는 `css_remove_all_unexpected_packets`는 data, request, abort, error 큐만 비운다. `buffer_queue`는 주석("DO NOT REMOVE THE DATA BUFFERS QUEUED BY THE USER")대로 남긴다.
- `css_is_valid_request_id`는 `buffer_queue`를 보지 않는다. 그래서 request id가 한 바퀴 돌면 남은 등록과 같은 id가 다시 나간다.
- `css_get_data_buffer`는 같은 id의 첫 항목, 즉 죽은 ping 버퍼를 돌려준다.

같은 상황에서 접속 경로(src/connection/connection_cl.cpp `css_connect_to_cubrid_server`의 `error_receive_data`)와 CDC 클라이언트(src/api/cubrid_log.c의 `css_queue_find_and_remove_header_entry_ptr`)는 등록을 뺀다. ping 경로만 빠져 있다.

같은 id를 다시 쓴 요청에 따라 증상이 다르다.

- commit 요청: 응답이 죽은 스택 주소로 들어간다. 관찰한 debug 빌드에서는 그 주소가 `css_net_recv`의 return 주소 자리여서 CAS가 SIGSEGV로 죽었다.
- 응답이 등록 버퍼가 아닌 곳으로 온 요청: `-187`이 난다. 이때 그 요청의 정상 응답 버퍼가 같은 id로 큐에 남아 새 stale 등록이 되고, 다음 바퀴에서 다시 실패한다.
- abort 등 오류 경로의 요청: `net_client_request_internal`의 `COMPARE_AND_FREE_BUFFER (replybuf, reply)`가 stale 스택 주소를 `free()`해서 CAS가 abort한다.

## Test Build

- 재현 빌드: develop 커밋 `173d92e4540d93218640985209cad214e40d5458`(Sidecar 코드 없음)과 이를 base로 한 PR #8504 head `f69816c0867895a0273e790eeb30dc8eef41d3f8`. 둘 다 debug_gcc, Linux x86_64다.
- 2026-11-17에 origin/develop `3a69b54de2`를 fetch해 확인했다. network_cl.c, client_support.c, connection_cl.cpp는 `173d92e454`와 같다. 최신 tip 자체를 빌드해 실행하지는 않았다.
- release 빌드와 다른 릴리스는 확인하지 않았다.

## Repro

### 1. 자연 발생 (관찰)

CI test_sql shard 하나의 실행 순서대로 앞 122개 case를 debug 빌드에서 `call_stack_dump_on_error=yes`로 실행했다. vacuum의 `-1127` 알림 콜스택을 덤프하는 7~11초 동안 서버가 요청을 처리하지 못했고, 그 사이 CAS의 ping이 `-186`으로 실패해 CAS 로그에 `SERVER DOWN`이 남았다. 그 뒤 같은 CAS 연결에서 request id가 한 바퀴 돈 122번째 case `sql/_33_elderberry/cbrd_24141/cases/column_name_serial_03.sql`에서 CAS가 죽었다.

- PR #8504 head: 3/3 실행에서 크래시(request id 6840). `call_stack_dump_on_error`를 끈 실행은 0/2.
- `173d92e454`: 0/2. 서버 정지가 timeout이 없는 `create table` 실행 중에 걸려 ping이 timeout되지 않았다. 다른 1회 실행에서는 ping timeout이 났다.
- 두 커밋의 차이는 서버 정지와 ping 사이의 타이밍이다. 결함 코드는 두 커밋에 같다.

### 2. ping 하나를 강제로 timeout (관찰, 진단 설정 없음)

`call_stack_dump_on_error`를 기본값으로 둔 채 같은 122개 case를 실행하면서 CAS에 gdb를 붙여, 43번째 `net_client_ping_server` 호출에서만 `css_receive_data_from_server_with_timeout`이 데이터를 읽지 않고 poll timeout과 같은 값을 반환하게 했다.

```gdb
set breakpoint pending on
break client_support::css_receive_data_from_server_with_timeout
disable 1
commands 1
  silent
  return (int) 7
  continue
end
break net_client_ping_server
ignore 2 42
commands 2
  silent
  enable once 1
  disable 2
  continue
end
```

- `173d92e454`: 강제 timeout된 ping은 request id 6840이었다. case 122의 `tran_server_abort` → `net_client_request_internal`(network_cl.c:544 `COMPARE_AND_FREE_BUFFER`)에서 CAS가 `free()` abort했다(1/1).
- PR #8504 head: 같다(1/1).
- 43번째 ping과 case 번호는 이 실행의 요청 순서에 묶인 값이다. 다른 순서에서는 timeout 뒤 같은 연결로 약 65,536개 요청이 지나야 증상이 나타난다.

### 3. 제안 재현 (미실행)

broker와 CAS 하나를 띄우고 한 연결에서 `ux_check_connection`이 ping을 보내는 순간 `cub_server`를 5초 넘게 SIGSTOP으로 멈췄다가 재개한다. 같은 연결로 request id가 한 바퀴 돌 만큼 짧은 요청을 반복한 뒤 commit과 rollback을 섞어 보낸다. 이 절차는 실행하지 않았다.

## Expected Result

ping이 timeout으로 끝나도 이후 요청은 자기 응답 버퍼로 응답을 받는다. request id가 한 바퀴 돌아도 CAS가 비정상 종료하지 않고 `-187`도 나지 않는다.

## Actual Result

timeout된 ping의 스택 버퍼 등록이 `buffer_queue`에 남는다. 같은 id를 받은 나중 요청에서 CAS가 SIGSEGV나 `free()` abort로 죽거나, 요청이 `-187`로 실패한다.

## Additional Information

- 같은 실행에서 이어진 다른 실패도 이 결함으로 설명된다. 122번째 case가 `-187`로 끝나며 남긴 새 stale 등록 때문에 다음 바퀴의 `cbrd_25147_3.sql`에서 CAS가 `net_client_request_with_callback`의 `free()`에서 abort했다. 이어진 두 case는 그 case가 지우지 못한 사용자 때문에 결과가 달라졌다.
- 기본값 `STATEMENT_POOLING=ON`에서 `ux_check_connection`은 ping 실패 시 -1만 반환하고 서버 연결을 닫지 않는다(코드). 그래서 stale 등록이 있는 연결을 CAS가 계속 쓴다. `OFF`일 때의 제자리 재접속 결함은 [CBRD-27951](https://jira.cubrid.org/browse/CBRD-27951)이 다루며, 이 이슈와 Relates 관계다. 중복 검색에서 같은 결함을 다루는 이슈는 찾지 못했다.
- `cas_sig_handler`가 쓰는 `$CUBRID/log/coredump/*.coredump`은 이 크래시에서 비어 있었다. 스택은 gdb를 CAS에 붙여 얻었다.
- ANALYSIS 확인 사항:
  - 응답을 포기하는 다른 클라이언트 경로(사용자 버퍼를 등록한 뒤 timeout이나 오류로 반환하는 경로)가 더 있는가.
  - release 빌드에서 같은 stale 주소 쓰기가 어떤 증상으로 나타나는가.
  - `applylogdb`의 `db_ping_server` 실패 경로가 같은 연결을 계속 쓰는가.
- 수정 방향 후보(미선택): ping처럼 응답을 포기하는 경로에서 등록을 빼는 방법, 또는 `css_is_valid_request_id`가 살아 있는 사용자 버퍼가 있는 id를 거르게 하는 방법. 위 2번 절차에서 abort가 사라지는지로 확인할 수 있다.
