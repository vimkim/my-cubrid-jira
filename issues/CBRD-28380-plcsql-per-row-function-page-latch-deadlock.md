# [PL/CSQL] 행마다 부르는 저장 함수가 같은 테이블을 읽으면, 그 페이지를 고치려는 vacuum 이나 다른 세션과 페이지 래치 교착에 빠진다

**한 줄 요약**: PR #8514 CI(test_sql, debug)에서 `cbrd_27742_02.sql` 이 300초 멈춘 뒤 cub_server 가 `pgbuf_timed_sleep ()` assert 로 종료한 원인을 develop `8e052e99c5` 에서 재현했다. 행마다 저장 함수를 부르는 SELECT 의 heap 스캔, 그 함수 안에서 같은 테이블을 읽는 SQL, 같은 페이지를 고치려는 vacuum 또는 다른 세션의 세 스레드가 서로를 기다리는 페이지 래치 교착이며, 이 교착이 생기지 않게 하는 것이 목표다.

## Issue Triage

**이슈 수행 목적**: select 목록 등에서 행마다 부르는 저장 함수(PL/CSQL, Java SP)가 바깥 질의와 같은 테이블을 읽어도, 그 페이지를 고치려는 vacuum 이나 다른 트랜잭션 때문에 문장이 래치 타임아웃까지 멈추지 않게 한다. debug 빌드에서 이 때문에 서버가 assert 로 종료하는 일도 없앤다.

**이슈 수행 이유**: 바깥 heap 스캔은 페이지에 READ 래치를 쥔 채 행마다 함수를 부른다. 함수 안의 SQL 은 클라이언트(csql/CAS)를 거쳐 서버의 **다른 worker 스레드**에서 실행되므로, 페이지 버퍼는 이 요청을 래치 소유자로 보지 않는다. 그 사이 vacuum 이나 다른 세션이 같은 페이지에 WRITE 래치를 요청해 대기자가 생기면, 함수의 READ 요청은 그 대기자 뒤에 줄을 선다. 바깥 스캔은 함수를, 함수는 WRITE 대기자를, WRITE 대기자는 바깥 스캔을 기다리는 교착이 되고, 페이지 래치 교착은 탐지되지 않으므로 래치 타임아웃(`page_latch_timeout_in_msecs`, 기본 300초)이 지나야 풀린다. develop `8e052e99c5` debug·release 빌드에서 재현했고, 세 스레드와 같은 BCB 를 gdb 로 확인했다. CBRD-27591 의 수정(CBRD-27579)은 함수 안의 DML 을 거부할 뿐이고, 같은 테이블을 읽기만 하는 함수는 그대로 허용한다.

**영향**: debug 빌드에서는 먼저 기다린 스레드가 래치 타임아웃 뒤 `assert (0)` 로 서버를 종료한다. CI test_sql 에서 `cbrd_27742_02.sql` 이 한 번 이렇게 실패했고, 같은 shard 의 뒤 testcase 6개가 연달아 실패했다. release 빌드에서는 서버가 죽지 않지만, 바깥 SELECT 가 교착 한 번마다 래치 타임아웃만큼 멈추고, WRITE 를 기다린 쪽이 사용자 트랜잭션이면 그 트랜잭션이 `-836`·`-72` 로 철회된다(측정). vacuum 이면 vacuum 작업이 실패하고 같은 페이지를 다시 시도하므로, 함수를 부르는 다음 행에서 교착이 다시 생긴다(측정: 래치 타임아웃 60초에서 SELECT 하나가 122초). 운영 환경에서 얼마나 자주 나는지는 모른다. 같은 페이지를 고치는 작업이 함수 호출과 겹쳐야 하므로, 작은 테이블에 쓰기가 잦을수록 잘 난다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

### 교착의 모양

`SELECT c, f5() FROM t2 WHERE c < 3` 에서 `f5` 가 `SELECT COUNT(*) INTO n FROM t2 ...` 를 실행하는 경우를 예로 든다. t2 는 10행이라 heap 페이지 하나에 모두 들어 있다.

1.  바깥 SELECT 의 스레드(스레드 A)가 t2 의 heap 페이지를 READ 래치로 fix 하고, 그 페이지를 쥔 채 행마다 `f5 ()` 를 부른다. 바깥 스캔이 fixed scan 이기 때문이다.
2.  `f5` 의 SQL 은 PL 서버 → cub_server(스레드 A) → 클라이언트(csql/CAS) 콜백을 거쳐, 클라이언트가 서버에 보내는 새 요청이 된다. 이 요청은 같은 트랜잭션이지만 다른 worker 스레드(스레드 C)에서 실행된다. 스레드 A 는 클라이언트의 응답을 기다린다.
3.  그 사이 vacuum worker 또는 다른 세션의 UPDATE(스레드 W)가 같은 페이지에 WRITE 래치를 요청한다. 페이지가 READ 로 잡혀 있으므로 W 는 기다리고, BCB 에 대기자 표시(`waiter_exists`)가 선다.
4.  스레드 C 가 같은 페이지에 READ 래치를 요청한다. READ 로 잡힌 페이지에 대한 READ 요청은, 대기자가 있고 요청한 스레드가 소유자가 아니면 막힌다. C 는 W 뒤에 줄을 선다.
5.  A 는 C 를(클라이언트 응답), C 는 W 를(대기열 순서), W 는 A 를(READ 래치) 기다린다. 먼저 줄을 선 W 의 래치 타임아웃이 지나야 풀린다.

W 가 2번보다 먼저 와 있어도 같다. 바깥 스캔이 페이지를 쥔 동안 W 가 대기열에 들어가면, 그 페이지에서 함수를 부르는 다음 행이 막힌다.

CBRD-27591 은 이 구조에서 함수가 같은 페이지를 **고치려** 할 때(두 스레드)의 교착이다. 그 수정(CBRD-27579, `4b0fe300b1`)은 SELECT 안에서 부른 함수의 DML 을 `ER_SP_DML_IN_QUERY` 로 거부한다. 함수가 같은 테이블을 **읽기만** 하면 READ 끼리라 막히지 않으므로 허용된다. 이 이슈는 그 읽기 전용 경우에 세 번째 스레드(WRITE 대기자)가 끼는 경우다.

### Test Build

-   CUBRID 11.5.0.3038-8e052e9 (develop `8e052e99c5`) debug: 재현.
-   CUBRID 11.5.0.3038-8e052e9 (develop `8e052e99c5`) release: 재현.
-   PR #8514 head `337e4f5867` debug (CI): 한 번 관측. PR 변경(serial NEXT VALUE)과는 무관하다. PR 없는 develop 에서 같은 스택으로 재현했다.
-   모두 client/server 모드. 대기 시간을 줄이려고 `cubrid.conf` 의 `[common]` 에 `page_latch_timeout_in_msecs=60000` 만 더했다. 기본값 300000 에서도 같은 경로를 탄다(CI 가 기본값으로 300초 뒤 종료).

### Repro

#### 재현 1: 세션 둘, 결정적 재현

함수 안에 `SLEEP` 을 넣어, 바깥 스캔이 페이지를 쥔 동안 다른 세션의 UPDATE 가 WRITE 대기자로 들어오게 한다.

``` sql
-- 준비 (csql -u dba <db>)
DROP TABLE IF EXISTS t2;
CREATE TABLE t2 (c INT);
INSERT INTO t2 SELECT ROWNUM FROM db_class LIMIT 10;
CREATE OR REPLACE FUNCTION f6 RETURN INT AS n INT;
BEGIN
 SELECT SLEEP (3) INTO n FROM db_root;
 SELECT COUNT(*) INTO n FROM t2;
 RETURN n;
END;
COMMIT;

-- 세션 A (0초)
SELECT c, f6() FROM t2 WHERE c = 1;

-- 세션 B (1초, A 가 끝나기 전)
UPDATE t2 SET c = c WHERE c = 10;
```

대조: 세션 B 없이 돌리면 A 는 3.2초에 끝난다(`f6()` = 10).

#### 재현 2: 세션 하나, vacuum 이 세 번째 스레드

CI 와 같은 모양이다. 다른 세션 없이, 앞 UPDATE 가 남긴 vacuum 작업이 WRITE 대기자가 된다. 아래 블록(UPDATE 1회 + case 6 SELECT 20회)을 200번 이어 붙인 파일을 `csql -u dba <db> -i loop.sql` 로 몇 번 실행한다.

``` sql
-- 준비: 재현 1 의 t2, 그리고 cbrd_27742_02.sql 의 f5
CREATE OR REPLACE FUNCTION f5 RETURN INT AS n INT;
BEGIN
 SELECT COUNT(*) INTO n FROM (SELECT c AS x FROM t2 GROUP BY c) z;
 RETURN n;
END;

-- loop.sql 의 블록 (자동 커밋)
UPDATE t2 SET c = c;
SELECT c, f5() FROM t2 WHERE c < 3 ORDER BY c;   -- 20번
```

#### 재현 3: 원래 testcase

`sql/_05_plcsql/_01_testspec/_05_bug_fix/cbrd-27742/cases/cbrd_27742_02.sql`(cubrid-testcases). case 6 `SELECT c, f5() FROM t2 WHERE c < 3 ORDER BY c;` 직전에 같은 파일의 `INSERT INTO t2` 가 남긴 vacuum 작업이 있다.

### Expected Result

세 재현 모두 SELECT 가 바로 끝난다(재현 1 은 약 3초). 다른 세션의 UPDATE 는 바깥 SELECT 가 페이지를 놓은 뒤 끝나고, vacuum 은 오류 없이 지나간다.

### Actual Result

| 재현 | debug | release |
|---|---|---|
| 1 (세션 둘) | 1/1 재현. 9초 시점에 세 스레드 교착(gdb). 약 61초에 UPDATE 스레드가 `-836 LATCH ON PAGE(1\|641) TIMEDOUT` 뒤 `pgbuf_timed_sleep ()` 의 `assert (0)` 로 서버 종료 | 1/1 재현. SELECT 가 88.2초 뒤 정상 결과를 돌려줌. 세션 B 는 `-836` 뒤 `ERROR: Your transaction (index 2, ...) has been unilaterally aborted by the system.`(`-72`) |
| 2 (vacuum) | 3번째 실행(SELECT 약 9,100회 뒤) 재현. vacuum worker 가 `-836`(Tran = 0) 뒤 `assert (0)` 로 서버 종료. CI 와 같은 스택 | 6번째 실행에서 SELECT 하나가 122.4초. vacuum 이 `-836`·`-72` 를 두 번 남김(17:10:46, 17:11:48). 클라이언트 오류는 없음 |
| 3 (testcase) | 40/40 정상(재현 안 됨) | 실행 안 함 |

-   release 재현 1 의 88초는 래치 타임아웃 60초(+61초에 `-836`)와 그 오류의 호출 스택을 서버 로그에 쓰는 시간(약 27초, `-72` 는 +88초)이다.
-   release 재현 2 의 122초: vacuum 이 첫 타임아웃(60초) 뒤 대기열에서 빠지면 뒤에 선 함수의 READ 가 허가되고(`pgbuf_timed_sleep_error_handling ()`, page_buffer.c:7899-7943) 첫 행의 `f5 ()` 가 끝난다. vacuum 은 같은 페이지를 곧 다시 요청했고, 바깥 스캔이 아직 쥔 그 페이지에서 둘째 행의 `f5 ()` 가 다시 막혀 60초를 더 기다렸다. 래치 타임아웃 기본값(300초)이면 같은 상황에서 약 10분이다. vacuum 이 오류 뒤 같은 페이지를 다시 처리하는 동작은 CBRD-27979 와 관련된다.
-   debug 에서는 누가 먼저 타임아웃 나든 `pgbuf_timed_sleep ()` 의 `assert (0)`(page_buffer.c:8062-8063, "FIXME: remove it. temporarily added for debugging")에 걸린다.

### 세 스레드 (gdb, debug 재현 2, 교착 10초 뒤)

`gdb -batch -p <cub_server pid> -ex 'thread apply all bt'` 와 프레임 변수로 확인했다.

| 스레드 | 트랜잭션 | 하는 일 | 스택(요약) |
|---|---|---|---|
| 바깥 SELECT | tran 1 | 페이지 `1\|641` 을 READ 로 쥠(holder fix_count=1, 쥔 페이지 1개). 함수 결과를 기다림 | `qexec_intprt_fnc` → `qexec_batch_scan` → `scan_batch_project_consume` → `qexec_batch_emit_row` → `qexec_end_one_iteration` → `fetch_peek_dbval_slow`(TYPE_SP, fetch.c:1904) → `cubpl::executor::execute` → `callback_execute`(pl_executor.cpp:759) → `xs_receive_data_from_client` |
| vacuum worker | tran 0 | 같은 BCB 에 WRITE 요청, 대기열 첫째 | `vacuum_process_log_block` → `vacuum_heap` → `vacuum_heap_page`(vacuum.c:1769) → `pgbuf_fix`(WRITE, UNCONDITIONAL) → `pgbuf_block_bcb` |
| 함수 안의 SELECT | tran 1 | 같은 BCB 에 READ 요청, 대기열 둘째 | `net_server_request` → `xqmgr_execute_query` → `qexec_intprt_fnc` → `scan_next_heap_scan` → `scan_heap_next_listed_page` → `heap_page_list_fix_next`(heap_file.c:2975) → `pgbuf_ordered_fix` → `pgbuf_block_bcb` |

-   BCB 의 래치 상태는 `latch_mode=READ, waiter_exists=1, fcnt=1` 이다. CI 코어의 vacuum 스레드가 막힐 때 본 값은 `READ, waiter_exists=0, fcnt=1` 로, vacuum 이 첫 대기자로 들어가기 직전 상태와 같다.
-   재현 1 에서는 vacuum 자리에 세션 B 의 UPDATE(`qexec_execute_update` → `locator_attribute_info_force` → `heap_get_last_version` → `heap_prepare_object_page` → `pgbuf_block_bcb`, WRITE)가 있고, 나머지 둘은 같다.
-   CI(PR #8514 run 45385469421 attempt 1, test_sql shard 01)는 vacuum 스레드 스택만 남았다. 위 vacuum 스택과 같다(`vacuum_heap_page` vacuum.c:1769, `pgbuf_timed_sleep` page_buffer.c:8063).

### 원인 위치 (코드 읽기, develop `8e052e99c5`)

-   **바깥 스캔이 페이지를 쥔 채 함수를 부른다.** `qexec_execute_mainblock_internal ()` 은 인덱스 스캔이 없으면 가장 안쪽 heap 스캔을 fixed scan 으로 연다(query_executor.c:23230-23345). 끄는 조건은 `XASL_NO_FIXED_SCAN`(23307), 상관 부질의, HAVING 부질의, `XASL_LINK_TO_REGU_VARIABLE` 이다. fixed scan 은 scan cache 의 `cache_last_fix_page` 로 페이지를 다음 호출까지 쥔다. batch 경로도 같은 이유로 페이지를 쥔다(scan_manager.c:8115-8122, `assert (xasl == NULL || scan_id->fixed)`). 이번 재현의 바깥 스캔은 batch 경로였고, batch 이전의 행 단위 경로도 함수 호출 중 페이지를 쥔다(CBRD-27591 코멘트의 gdb, `fixed=1`, `cache_last_fix_page=true`).
-   **저장 함수 호출은 fixed scan 을 끄지 않는다.** serial 연산자(xasl_generation.c:12802-12808, CBRD-27062)와 `INDEX_CARDINALITY`·`ESTIMATED_*`(13038-13080)는 스캔 도중 스토리지에 다시 들어가므로 `XASL_NO_FIXED_SCAN` 을 붙인다. `pt_stored_procedure_to_regu ()`(xasl_generation.c:9442)는 붙이지 않는다.
-   **함수 안의 SQL 은 다른 스레드에서 실행된다.** `fetch_peek_dbval ()` 의 `TYPE_SP`(fetch.c:1872-1904)가 `cubpl::executor::execute ()` 를 부르고, 함수의 SQL 실행 요청은 `callback_execute ()`(pl_executor.cpp:759)가 `send_data_to_client_recv ()` 로 클라이언트에 넘긴다. 클라이언트가 다시 보낸 요청은 `css_server_task` 의 다른 worker 스레드가 처리한다(gdb 확인). SA 모드는 같은 스레드에서 처리하므로(network_callback_sr.cpp 의 SA 분기) 이 교착이 없다(코드 읽기, 실행 안 함).
-   **소유자가 아닌 READ 는 대기자 뒤에 선다.** `pgbuf_latch_bcb_upon_fix ()` 는 READ 로 잡힌 페이지에 대한 READ 요청을, `waiter_exists` 가 서 있고 요청한 스레드가 그 BCB 의 holder 가 아니면 막는다(page_buffer.c:7050-7072). holder 는 스레드 단위라, 같은 트랜잭션의 바깥 스캔이 쥔 페이지라도 함수 스레드는 소유자가 아니다.
-   **페이지 래치 교착은 탐지하지 않는다.** `pgbuf_block_bcb ()` 는 시간 제한이 있는 대기로 처리하고(page_buffer.c:7815-7823 주석), 타임아웃 난 쪽을 희생자로 삼는다.

### 관련 이슈

-   CBRD-27591(Resolved): 같은 구조에서 함수의 DML 이 바깥 스캔의 페이지를 기다리는 두 스레드 교착. 수정(CBRD-27579)은 DML 거부이고, 읽기 전용 함수는 남는다. 그 이슈 코멘트가 `pt_stored_procedure_to_regu ()` 에 `XASL_NO_FIXED_SCAN` 이 없다는 점을 이미 짚었다.
-   CBRD-27062(Done): serial `NEXT_VALUE` 를 부르는 스캔의 페이지 래치 교착. 수정은 해당 블록의 fixed scan 끄기.
-   CBRD-28163(Confirmed): 래치 타임아웃 뒤 남는 `waiter_exists` 때문에 READ 요청이 막히는 결함. 이 이슈의 READ 막힘도 같은 판정(page_buffer.c:7050-7072)을 거친다. 그 수정만으로는 이 교착이 풀리지 않는다(WRITE 대기자가 실제로 대기열에 있음).
-   CBRD-27979(Develop): release 의 `vacuum_heap` 이 페이지 오류 뒤 같은 페이지를 다시 처리. release 재현 2 에서 교착이 두 번 생긴 것과 관련된다.
-   CBRD-28031: 커버링 인덱스 스캔도 리프를 쥔 채 행을 처리하므로(`qexec_covered_visit ()`), 같은 모양이 B-tree 리프에서도 날 수 있다(CBRD-27591 코멘트, 이 이슈에서는 실행 안 함).
-   CBRD-28368(Open): 읽는 쪽이 페이지 래치 대신 버전에 의존하게 하는 큰 개편. 이 교착의 근본 해소와 겹친다.

### ANALYSIS 확인 사항

-   Java SP, 프로시저 안 커서 루프(`FOR r IN (SELECT ...)`), WHERE 절·부질의·트리거에서 부른 함수도 같은 경로인지.
-   커버링 인덱스 스캔(리프 래치)에서도 읽기 전용 함수 + WRITE 대기자로 교착이 나는지.
-   해결 뒤 SP 를 부르는 질의의 스캔 성능 변화(fixed scan 대신 cached scan 또는 행마다 fix).

## Options for Analysis

아래는 후보이며, 선택은 ANALYSIS 에서 한다.

| 후보 방안 | 기대 효과와 장점 | 한계·단점과 실패 조건 | 비용·위험·호환성 | 근거와 ANALYSIS 확인 사항 |
|---|---|---|---|---|
| A. `pt_stored_procedure_to_regu ()` 에서 `XASL_NO_FIXED_SCAN` 을 붙여, SP 를 부르는 블록은 fixed scan 을 쓰지 않음 | serial·통계 함수와 같은 기존 방식. 함수 호출 중 바깥 스캔이 페이지를 쥐지 않으므로 함수의 읽기·쓰기 모두 막히지 않음. batch 경로도 이 플래그를 이미 따름(`qexec_batch_filter_eligible ()`) | 플래그는 블록 단위라, SP 가 부모 블록이 아닌 곳(부질의, 다른 블록의 regu)에 있으면 놓칠 수 있음. 커버링 인덱스 방문(`qexec_covered_visit ()`)도 같이 꺼지는지 확인 필요 | SP 를 부르는 질의의 스캔이 cached scan 또는 행마다 fix 로 바뀌어 느려질 수 있음 | CBRD-27062 와 같은 수정 모양. 플래그가 닿지 않는 SP 위치를 찾아야 함 |
| B. SP 를 부르기 전에 바깥 스캔이 쥔 페이지를 놓고, 돌아온 뒤 다시 fix | fixed scan 의 이점을 SP 없는 행에서는 유지 | peek 한 레코드가 페이지를 놓은 뒤 무효가 되므로 복사나 재검증이 필요. 스캔 종류(heap, batch, 커버링 인덱스)마다 따로 구현 | 변경 범위가 크고 행 위치 재확인 버그 위험이 큼 | batch 경로의 "page let go and fixed again" 처리(scan_manager.c:8115-8122)가 참고가 됨 |
| C. 같은 트랜잭션의 다른 스레드가 쥔 페이지에 대한 READ 는 대기자를 앞질러 허가 | 페이지 버퍼만 바꾸고 질의 실행은 그대로 | holder 가 스레드 단위라 트랜잭션 단위 판정을 새로 만들어야 함. WRITE 대기자 굶주림 가능. 함수가 WRITE 를 원하는 경우(CBRD-27591 꼴)는 여전히 막힘 | 페이지 버퍼 공정성·교착 성질이 바뀌어 위험이 큼 | 다른 사용처(병렬 스캔 워커 등)에 주는 영향 확인 필요 |

A 는 이미 쓰는 방식이라 위험이 가장 작지만 SP 를 부르는 질의의 성능을 대가로 한다. B 는 성능을 지키는 대신 구현 위험이 크고, C 는 범위가 페이지 버퍼 전체로 넓어진다. SP 를 부르는 질의의 성능 측정과, `XASL_NO_FIXED_SCAN` 이 닿지 않는 SP 호출 위치가 있는지가 선택을 가른다.
