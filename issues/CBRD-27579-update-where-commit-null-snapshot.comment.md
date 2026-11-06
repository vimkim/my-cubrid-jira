## 추가 사례: UPDATE 의 WHERE 에서 COMMIT 하는 함수를 부르면 cub_server 가 SIGSEGV 로 종료

규칙 1 (문장 안 TCL 거부) 이 막아야 할 또 하나의 증상이다. CBRD-27603 과 달리 임시 페이지가 아니라 MVCC snapshot 경로에서 터진다. 3행 테이블에서도 매번 재현된다.

### Test Build

- CUBRID 11.5.0.2635 debug (develop 30043f492): 2회 실행, 2회 재현.
- client/server 모드 (`csql`, autocommit on, 기본 격리 수준 READ COMMITTED). `cubrid.conf` 는 `stored_procedure=yes` 외에 메모리 크기만 줄였다.

### Repro

`csql -u dba <db> -i repro.sql`

```sql
drop table if exists t;
create table t (id int primary key, s varchar(40));
insert into t values (1, 'r1'), (2, 'r2'), (3, 'r3');
create or replace function f_commit (k int) return int as
begin
  commit;
  return k;
end;
update t set s = 'x' where f_commit (id) = 2;
```

### Actual Result

마지막 UPDATE 에서 csql 이 아래 오류를 받고, cub_server 는 SIGSEGV 로 종료한 뒤 master 가 다시 띄운다.

    ERROR: Your transaction has been aborted by the system due to server failure or mode change.

`$CUBRID/log/coredump/cub_server_*.coredump` 에는 `crash_handler` 프레임까지만 남아, 두 번째 실행은 서버에 gdb 를 붙여 스택을 받았다.

```
Thread 21 "transaction" received signal SIGSEGV, Segmentation fault.
#0  0x0000000000000000 in ?? ()
#1  locator_lock_and_get_object_with_evaluation (..., ispeeking=0, old_chn=-1, mvcc_reev_data=..., non_ex_handling_type=LOG_WARNING_IF_DELETED) at locator_sr.c:13207
#2  scan_next_heap_scan () at scan_manager.c:6050
#3  scan_next_scan_local () at scan_manager.c:5720
#4  scan_handle_single_scan () at scan_manager.c:7697
#5  scan_next_scan () at scan_manager.c:7833
#6  qexec_intprt_fnc () at query_executor.c:9731
#7  qexec_execute_mainblock_internal () at query_executor.c:16982
#8  qexec_execute_mainblock () at query_executor.c:16013
#9  qexec_execute_update () at query_executor.c:10712
#10 qexec_execute_mainblock_internal () at query_executor.c:16222
...
#13 qmgr_process_query () at query_manager.c:1237
#15 sqmgr_prepare_and_execute_query () at network_interface_sr.cpp:6412
```

frame 1 의 `*scan_cache->mvcc_snapshot` (gdb 측정):

```
lowest_active_mvccid = 0, highest_completed_mvccid = 0,
snapshot_fnc = 0x0, valid = false
```

### 원인 위치 (코드 읽기 + gdb, 추정)

- UPDATE 의 select 단계 힙 스캔은 `scan_cache->mvcc_snapshot` 에 트랜잭션의 snapshot (`tdes->mvccinfo.snapshot`) 포인터를 들고 있다.
- 함수의 `commit;` 이 서버에 오면 `logtb_complete_mvcc ()` 가 `curr_mvcc_info->reset ()` 을 부른다 (log_tran_table.c:4469). `mvcc_snapshot::reset ()` 은 `snapshot_fnc = NULL`, `valid = false` 로 만든다 (mvcc.c:727).
- 함수가 돌아온 뒤 스캔이 다음 행을 재평가하며 `locator_lock_and_get_object_with_evaluation ()` 에 들어간다. 여기서는 포인터만 검사하고 `scan_cache->mvcc_snapshot->snapshot_fnc (...)` 를 바로 부른다 (develop e64a04a79 기준 locator_sr.c:13532, origin/develop 953e83256 기준 14010). `valid` 나 `snapshot_fnc` 는 보지 않으므로 NULL 함수 포인터를 호출한다.
- release 빌드에서도 같은 호출이라 assert 없이 SIGSEGV 로 끝날 것으로 보인다 (추정, 미실행).
- 규칙 1 이 들어가면 이 재현은 `ER_SP_TCL_DDL_IN_QUERY` 로 끝나고 서버는 살아 있어야 한다. 이 SQL 을 규칙 1 의 회귀 테스트에 넣기를 제안한다.

### origin/develop

origin/develop 953e83256 에는 규칙 1 (`ER_SP_TCL_DDL_IN_QUERY`) 이 아직 없다. `logtb_complete_mvcc ()` 의 reset 과 위 snapshot_fnc 호출도 그대로다. 코드 비교만 했고 실행하지 않았다.
