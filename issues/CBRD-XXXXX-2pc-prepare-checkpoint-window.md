# [Recovery] XA prepare와 체크포인트가 겹친 뒤 서버가 죽으면 재시작 복구가 prepare된 브랜치를 ACTIVE로 보고 UNDO에서 멈춘다

**한 줄 요약**: PR #8674(CBRD-28200) 리뷰 중 찾은 develop 기존 결함으로, XA 브랜치의 prepare 로그를 쓴 직후 상태를 바꾸기 전 짧은 구간에 체크포인트가 트랜잭션 표를 저장하면 그 브랜치가 ACTIVE로 기록되고, 클라이언트가 "prepared" 응답을 받은 뒤 서버가 죽으면 재시작 복구가 in-doubt 브랜치를 되살리지 못하는 문제를 다룬다.

## Issue Triage

**이슈 수행 목적**: XA 참가자가 prepare 성공을 응답한 브랜치는 그 뒤 체크포인트가 언제 돌았든 서버가 죽었다 재시작한 뒤 항상 in-doubt(2PC prepare) 상태로 돌아와, 트랜잭션 관리자(TM)가 `xa_recover`로 찾아 commit 또는 rollback할 수 있어야 한다.

**이슈 수행 이유**: `log_2pc_prepare_global_tran`은 `LOG_2PC_PREPARE` 로그를 `prior_lsa_mutex` 안에서 붙인 뒤, mutex 밖에서 `tdes->state`를 `TRAN_UNACTIVE_2PC_PREPARE`로 바꾼다. 그 사이에 체크포인트가 트랜잭션 표를 저장하면 브랜치는 `TRAN_ACTIVE`로, `undo_nxlsa`는 PREPARE 레코드 위치로 저장된다. 이 브랜치가 prepare 응답을 받은 뒤 서버가 비정상 종료되면 재시작 복구는 체크포인트 기록대로 이 브랜치를 롤백 대상으로 삼고, UNDO가 PREPARE 레코드에서 시작해 실패한다. develop debug 빌드에서 gdb로 이 구간을 넓혀 두 번 재현했고, 체크포인트만 빼고 같은 절차를 따른 대조에서는 브랜치가 정상으로 in-doubt 상태로 돌아왔다.

**영향**: debug 빌드에서는 재시작 복구가 `log_recovery_undo`의 assert로 죽고, 재시도해도 같은 지점에서 죽어 DB를 기동할 수 없다(재현에서 확인). release 빌드에서는 코드상 이 assert를 지나 브랜치를 UNDO 없이 abort 처리하고 지운다. 그러면 TM은 prepare 성공을 받았는데도 그 브랜치를 `xa_recover`로 찾지 못하고, 브랜치가 쓴 행은 되돌려지지 않은 채 남는다. 즉 분산 트랜잭션의 원자성이 깨진다. release 빌드의 실제 결과(남은 행이 커밋된 것으로 보이는지)와 자연 발생 빈도는 측정하지 않았다. 구간은 명령 몇 개 길이로 좁지만, 이를 막는 잠금이 없고 체크포인트는 주기와 로그 양에 따라 계속 돈다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

### 문제가 생기는 순서

XA 참가자(CCI/JDBC XA로 붙은 CUBRID 서버)에서 브랜치가 prepare될 때의 순서는 다음과 같다(develop `051a19c` 기준).

```
prepare 스레드 (log_2pc_prepare_global_tran)          체크포인트 스레드 (logpb_checkpoint)
 1581  prior_lsa_next_record(LOG_2PC_PREPARE)
        └ prior_lsa_mutex 안에서 tail_lsa = undo_nxlsa = PREPARE LSA
        (mutex 해제)
                                                      TR_TABLE_CS + prior_lsa_mutex 획득
                                                      logpb_checkpoint_trans: state = TRAN_ACTIVE,
                                                        tail_lsa = undo_nxlsa = PREPARE LSA 저장
                                                      LOG_END_CHKPT 기록, 로그 헤더 갱신
 1593  tdes->state = TRAN_UNACTIVE_2PC_PREPARE
 1594  logpb_flush_pages → 클라이언트에 "prepared" 응답
```

`LOG_COMMIT`, `LOG_ABORT`는 레코드를 붙이는 순간 `prior_lsa_mutex` 안에서 `commit_abort_lsa`를 기록하고, 체크포인트는 이 값이 있으면 그 트랜잭션의 상태를 무시한다(`log_append.cpp:1537-1541`, `log_page_buffer.c:7253-7257`). `LOG_2PC_PREPARE`에는 이런 처리가 없다.

서버가 이 뒤 비정상 종료되면 재시작 복구는 다음과 같이 진행한다.

1. 분석(analysis)은 마지막 체크포인트에서 시작한다. `LOG_END_CHKPT` 처리가 저장된 `TRAN_ACTIVE`를 `TRAN_UNACTIVE_UNILATERALLY_ABORTED`(롤백 대상)로 바꾼다(`log_recovery.c:1970-1972`). PREPARE 레코드가 체크포인트 시작보다 앞에 있으면 분석은 그 레코드를 다시 읽지 않는다. 체크포인트 시작이 PREPARE보다 앞인 순서에서도 `LOG_END_CHKPT`가 나중에 상태를 덮어써 결과는 같다(코드 확인, 실행하지 않음).
2. UNDO는 `undo_nxlsa`, 즉 PREPARE 레코드에서 시작한다. `LOG_2PC_PREPARE`는 `log_recovery_undo`에서 "분석 단계의 시스템 오류"로 다루는 종류다(`log_recovery.c:5251`). debug 빌드는 `assert (false)`(`log_recovery.c:5268`)로 종료한다. release 빌드는 MVCCID를 비우고 `LOG_ABORT`를 쓴 뒤 트랜잭션을 지운다. 브랜치가 바꾼 데이터는 UNDO하지 않는다(`log_recovery.c:5270-5284`).

### Test Build

- CUBRID 11.5.0 (11.5.0.3034) (64 debug build), develop `051a19c358fd13bef2cdd4110f5e4443e81c5757`, `SUPPORT_XA=true`(CCI_XA)
- JDBC XA 클라이언트(`CUBRIDXADataSource`, 설치본의 `cubrid_jdbc.jar`), OpenJDK 1.8, gdb 14.2

### Repro

구간이 짧아 gdb로 prepare 스레드 하나만 멈춰 구간을 넓힌다. 다른 스레드는 계속 돈다(non-stop 모드).

1. 준비: `cubrid.conf`에 DB별로 `auto_restart_server=no`, `checkpoint_interval=1min`을 둔다. DB를 만들고 서버와 broker를 기동한다.

   ```sql
   CREATE TABLE t_p1 (id INT PRIMARY KEY, u INT UNIQUE, v INT);
   INSERT INTO t_p1 SELECT ROWNUM, ROWNUM, 0 FROM db_class a, db_class b LIMIT 100;
   ```

2. gdb를 non-stop 모드로 `cub_server`에 붙이고, prepare 로그를 붙인 뒤 상태를 바꾸기 직전에 멈추는 breakpoint를 둔다.

   ```
   gdb -nx -q -iex "set non-stop on" -ex "attach <cub_server pid>"
   (gdb) break log_2pc.c:1593
   (gdb) continue -a &
   ```

3. XA 클라이언트에서 브랜치 하나를 시작해 `INSERT INTO t_p1 VALUES (1003, 1003, 1)`, `xa_end`, `xa_prepare`를 호출한다. 연결은 닫지 않는다. prepare 스레드가 breakpoint에서 멈춘다.
4. 서버 에러 로그에 `Checkpoint finished`(-978)가 새로 찍힐 때까지 기다린다(1분 안팎).
5. gdb를 `detach`한다. 클라이언트가 `xa_prepare` 성공(XA_OK)을 받는다.
6. `kill -9 <cub_server pid>`로 서버를 종료하고 `cubrid server start <db>`로 재시작한다.

### Expected Result

재시작이 성공하고 `cubrid tranlist`에 `(2PC1)` 브랜치가 1개 보인다. `XAResource.recover()`가 그 XID를 돌려주고, commit하면 행 1003이 보인다.

### Actual Result

- 체크포인트가 저장한 항목(gdb, `LOG_END_CHKPT` 기록 직전): `{trid = 168, state = TRAN_ACTIVE, tail_lsa = {178, 4616}, undo_nxlsa = {178, 4616}}`. `{178, 4616}`은 PREPARE 레코드의 LSA다.
- 재시작: 분석과 REDO가 끝나고 `UNDO Phase is started. ... transactions to undo: 1` 직후 서버가 종료된다. `cubrid server start`는 실패하고, master의 server monitor가 1초마다 다시 띄우지만 매번 같은 곳에서 죽는다.
- gdb로 띄운 재시작:

  ```
  cub_server: src/transaction/log_recovery.c:5268: void log_recovery_undo(THREAD_ENTRY*): Assertion `false' failed.
  #5 log_recovery_undo        log_recovery.c:5268
  #6 log_recovery             log_recovery.c:906
  #9 boot_restart_server      boot_sr.c:2441
  #10 net_server_start        network_sr.c:1221
  ```

- 새로 만든 DB에서 다시 해도 같다(2회 중 2회).

대조: 같은 breakpoint에서 75초 멈췄다 풀되 그동안 체크포인트가 돌지 않게 하면(`checkpoint_interval=60min`), 같은 kill과 재시작 뒤 `tranlist`에 `1(2PC1)`이 보이고 `xa_recover`가 브랜치를 찾아 commit이 성공한다. gdb로 멈추는 것, kill, 재시작 자체는 원인이 아니고, 체크포인트가 이 구간에 트랜잭션 표를 저장해야 문제가 생긴다.

### 같은 구조의 다른 2PC 레코드

coordinator 쪽(dblink 2PC)의 `log_2pc_append_decision`도 `LOG_2PC_COMMIT_DECISION`/`LOG_2PC_ABORT_DECISION`을 붙인 뒤 mutex 밖에서 상태를 바꾼다(`log_2pc.c:1940-1956`). `LOG_2PC_START`도 같은 구조다(1894, 1904). `LOG_2PC_COMMIT_DECISION`도 UNDO에서 같은 오류 목록에 있다(`log_recovery.c:5254`). 다만 coordinator는 결정 직후 `LOG_COMMIT`을 써 `commit_abort_lsa`가 채워지므로 문제가 되는 구간이 더 좁다. 이 경로는 재현하지 않았다. 이번 수정 범위에 넣을지는 ANALYSIS에서 정한다.

### ANALYSIS 확인 사항

- release 빌드에서 같은 재현을 했을 때 재시작이 성공하는지, 브랜치의 INSERT가 다른 세션에 커밋된 것으로 보이는지, unique index와 vacuum에 남는 영향이 있는지.
- 체크포인트 시작이 PREPARE보다 앞서는 순서(분석이 PREPARE를 읽은 뒤 `LOG_END_CHKPT`가 덮어씀)도 같은 결과인지 실행으로 확인한다.
- 회귀 시험: 구간이 짧아 자연 재현이 어렵다. prepare 로그 직후에 멈추는 debug용 fault injection으로 shell TC를 만들 수 있는지.

### 관련 이슈

- CBRD-27223: prepare된 XA 브랜치가 `max_clients`보다 많을 때 재시작 복구가 죽고 DB를 기동할 수 없다. 증상은 비슷하지만 원인(트랜잭션 표 크기)이 다르다.
- CBRD-28305, CBRD-28262: 재시작 뒤 prepare된 브랜치의 상태 일부가 사라지는 다른 경로다(공간 예약, 11.4 redo의 PREPARE 레코드 읽기 위치).
- CBRD-28065: 클라이언트가 성공 응답을 받은 상태가 디스크 기록과 어긋나 재시작에서 사라지는 같은 부류의 결함이다(COMMIT, `logpb_flush_pages` 대기 조건). 코드 경로는 다르다.
