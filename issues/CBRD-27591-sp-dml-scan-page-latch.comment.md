## 추가 재현: develop e64a04a79 debug

최근 develop 두 빌드에서 같은 현상을 재현했다. 바깥 SELECT 스레드가 쥔 페이지와 함수의 UPDATE가 기다리는 페이지가 같은 버퍼임을 gdb로 확인했다. 원인 위치도 함께 정리한다.

### Test Build

- CUBRID 11.5.0.2802 debug (develop e64a04a79): 3회 실행, 3회 재현.
- CUBRID 11.5.0.2635 debug (develop 30043f4): 1회 실행, 재현.
- 두 빌드 모두 client/server 모드. 대기 시간을 줄이려고 `cubrid.conf`에 `page_latch_timeout_in_msecs=30000`만 더했다. 기본값 300000에서도 같은 경로를 탄다. (기존 본문 재현)

### Repro

`csql -u dba <db> -i repro.sql`

```sql
drop table if exists t;
create table t (id int primary key, s varchar(100));
insert into t values (1, 'r1'), (2, 'r2'), (3, 'r3');
create or replace function f_upd (k int) return int as
begin
  update t set s = 'changed' where id = k;
  return k;
end;
-- id + 0 은 PK 인덱스를 쓰지 않게 해서 바깥 스캔을 힙 스캔으로 만든다
select f_upd (id) from t where id + 0 = 2;
```

### Actual Result

약 30초 뒤 csql에 `ERROR: Server no longer responding`이 나오고 서버가 종료한다. 서버 에러 로그는 다음과 같다.

    ERROR CODE = -836, Tran = 1, CLIENT = <host>:csql(<pid>)
    LATCH ON PAGE(1|705) TIMEDOUT

이어서 `pgbuf_timed_sleep ()`의 `assert (0)`에서 종료한다. 소스 기준 page_buffer.c:7461이고, 스택에는 7490으로 찍힌다.

### 두 스레드 (gdb 측정)

대기 중에 `gdb -batch -p <cub_server pid>`로 모든 스레드 스택을 받았다.

- 바깥 SELECT 스레드: `qexec_intprt_fnc` → `qexec_end_one_iteration` → `fetch_peek_dbval_slow` (TYPE_SP, fetch.c:1917) → `cubpl::executor::callback_execute` (pl_executor.cpp:759) → `xs_receive_data_from_client`. 함수가 보낸 UPDATE의 결과를 클라이언트로부터 기다린다. 이 스레드의 힙 스캔은 `S_HEAP_SCAN`, `fixed=1`, `cache_last_fix_page=true`이고 `page_watcher`가 READ 래치로 페이지를 쥐고 있다.
- 함수의 UPDATE 스레드: `net_server_request` → `qexec_execute_update` → `locator_attribute_info_force` → `heap_get_last_version` → `heap_prepare_object_page` → `pgbuf_block_bcb`. 페이지 (1|705)를 기다린다.
- UPDATE가 기다리는 BCB의 페이지 주소가 바깥 스캔의 `page_watcher.pgptr`과 같다 (`0x7fc46c02f0d8`). 같은 트랜잭션의 두 스레드가 서로를 기다리므로, 래치 타임아웃 말고는 풀리지 않는다.

### 원인 위치 (코드 읽기, 추정)

- `qexec_execute_mainblock_internal ()`은 행마다 다른 질의를 실행할 수 있는 경우 fixed scan을 끈다 (query_executor.c:21902-21929). 대상은 인덱스 스캔, `XASL_NO_FIXED_SCAN`, 상관 부질의, `XASL_LINK_TO_REGU_VARIABLE`이다.
- 컴파일러는 스캔 도중 스토리지에 다시 들어가는 연산자에 `XASL_NO_FIXED_SCAN`을 붙인다. serial NEXT_VALUE/CURRENT_VALUE (CBRD-27062, xasl_generation.c:11321-11327)와 통계 함수가 그 예다.
- `pt_stored_procedure_to_regu ()` (xasl_generation.c:8799)는 이 플래그를 붙이지 않는다. 그래서 저장 함수를 부르는 블록도 fixed scan으로 열리고, 바깥 스캔은 페이지를 쥔 채 함수를 실행한다.
- CBRD-27579 규칙 2가 들어가 SQL 문장 안 함수의 DML을 거부하면, 이 재현은 멈추는 대신 `ER_SP_DML_IN_QUERY`로 끝날 것으로 보인다 (추정, 미실행). 같은 테이블을 SELECT만 하는 함수는 READ 래치끼리라 멈추지 않는다 (기존 본문 측정).

### origin/develop

origin/develop 21c6e635d (2026-11-05)에서 fetch.c, src/sp, heap_file.c, page_buffer.c는 e64a04a79와 같다. scan_manager.c와 query_executor.c의 변경은 이 경로와 무관하다. 코드 비교만 했고 실행하지 않았다.
