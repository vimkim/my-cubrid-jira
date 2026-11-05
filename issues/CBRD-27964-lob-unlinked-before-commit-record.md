# [STORAGE] commit 중 이전 LOB 파일을 commit 레코드보다 먼저 지워 crash 뒤와 옛 snapshot에서 LOB를 읽지 못한다

**한 줄 요약**: CBRD-27237 결정 Q5에 따라 LOB 삭제 알림의 crash 구간을 재현하다가 확인한 결함으로, UPDATE나 DELETE로 버린 이전 LOB 파일이 commit이 확정되기 전에 즉시 삭제되어 crash 복구 뒤 행이 없는 파일을 가리키고, 옛 snapshot을 가진 reader도 그 LOB를 읽지 못하는 문제를 다룬다.

## Issue Triage

**이슈 수행 목적**: commit이 디스크에 확정되기 전에 crash가 나도, 그리고 옛 snapshot을 가진 트랜잭션이 아직 읽는 중이어도, 행이 가리키는 LOB 파일이 남아 있어야 한다.

**이슈 수행 이유**: develop `21c6e635d` debug build에서 BLOB 컬럼 UPDATE를 commit하는 도중 commit 레코드를 쓰기 직전에 서버를 kill -9하면, 재시작 뒤 행은 옛 locator를 가리키고 그 파일은 없다. crash 없이도 REPEATABLE READ reader가 옛 행의 BLOB를 읽으면 `External file ... was not found`로 실패한다. 두 경우 모두 실행으로 재현했다.

**영향**: BLOB/CLOB 컬럼을 UPDATE하거나 그 행을 DELETE하는 모든 사용자가 대상이다. crash 시점이 맞으면 commit되지 않은 트랜잭션 때문에 이미 commit된 LOB 데이터가 영구히 사라진다. 동시 실행 환경에서는 crash 없이도 다른 트랜잭션의 조회가 오류로 끝난다. 실제 운영에서의 발생 빈도는 확인하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

CUBRID는 BLOB/CLOB 값을 lob 디렉터리의 외부 파일로 저장하고 행에는 그 경로(locator)만 둔다. 트랜잭션은 이번에 만들거나 버린 LOB 파일을 트랜잭션별 목록에 기록한다. commit 처리 `log_commit_local`은 commit 레코드를 쓰기 전에 `tx_lob_locator_clear`로 이 목록을 정리한다.

목록에서 버린 파일은 두 갈래로 처리된다.

- 같은 트랜잭션이 만들고 다시 버린 파일(`LOB_PERMANENT_DELETED`)은 `RVES_NOTIFY_VACUUM` 로그를 남기고 vacuum이 나중에 지운다.
- 이전 트랜잭션이 commit한 파일을 버린 경우(`LOB_TRANSIENT_DELETED`)는 그 자리에서 `es_delete_file`로 바로 지운다(`src/transaction/transaction_transient.cpp:452`). 이 삭제에는 로그가 없다.

일반 SQL UPDATE와 DELETE가 버리는 LOB는 대부분 이전 commit 파일이므로 두 번째 갈래를 탄다. 이 삭제는 commit 레코드 append(`src/transaction/log_manager.c:5300`)와 flush(`:5309`)보다 먼저 일어난다(`:5250`). 따라서 두 가지 문제가 생긴다.

1. 삭제 뒤 commit 레코드가 디스크에 닿기 전에 서버가 죽으면, 복구는 그 트랜잭션을 되돌리거나(로그가 일부 내려간 경우) 아예 없던 일로 만든다. 행은 옛 locator로 남고 파일은 없다.
2. commit 직후에도 옛 snapshot을 가진 트랜잭션은 MVCC 규칙상 옛 행을 본다. 그러나 그 행의 파일은 이미 없다. vacuum 경로라면 MVCC 가시성을 기다리지만 직접 삭제는 기다리지 않는다.

이 분기는 2019년 CBRD-22822(`773153460`)에서 지금 모양이 됐다.

## Test Build

- 소스 `CUBRID/CUBRID` develop `21c6e635d404cd67a10a25e4f52c17d1cc8deed0`
- `CUBRID 11.5.0 (11.5.0.2835) (64 debug build)`, Linux x86_64, gcc debug preset
- 다른 버전과 release build는 시험하지 않았다. 해당 코드는 2019년부터 있으므로 11.x 전반이 대상일 가능성이 크지만 확인하지 않았다.

## Repro

### 준비

```sql
create table t (id int primary key, b blob);
insert into t values (1, bit_to_blob(X'aaaa'));
insert into t values (2, bit_to_blob(X'bbbb'));
insert into t values (3, bit_to_blob(X'cccc'));
insert into t values (4, bit_to_blob(X'dddd'));
```

### A. crash 없이 옛 snapshot에서 실패 (gdb 불필요)

세션 1과 세션 2를 동시에 실행한다.

```sh
# 세션 1
csql -u dba --no-auto-commit testdb -c "set transaction isolation level repeatable read; select id, b from t where id=4; select sleep(6); select id, b, blob_to_bit(b) from t where id=4; commit;"
# 세션 2 (세션 1 시작 2초 뒤)
csql -u dba testdb -c "update t set b = bit_to_blob(X'd1d1') where id=4;"
```

### B. commit 레코드 직전 crash (gdb 사용)

1. `gdb -p <cub_server pid>`로 attach하고 `log_append_commit_log`에 breakpoint를 건다.
2. 다른 세션에서 `update t set b = bit_to_blob(X'a2a2') where id=1;`을 auto commit으로 실행한다.
3. breakpoint에서 멈추면 lob 디렉터리에서 행 1의 원래 파일이 이미 없는지 본다.
4. (선택) gdb에서 `call logpb_force_flush_pages(thread_p)`로 이 트랜잭션의 레코드를 디스크에 내린다. 이때 복구가 이 트랜잭션을 undo한다.
5. gdb에서 `kill`로 서버를 SIGKILL하고 `cubrid server start testdb`로 다시 띄운다.
6. `select id, blob_to_bit(b) from t where id=1;`을 실행한다.

## Expected Result

- A의 세션 1 마지막 SELECT가 `X'dddd'`를 돌려준다.
- B의 재시작 뒤 행 1이 `X'aaaa'`로 읽힌다.

## Actual Result

A. 세션 2의 commit 직후 옛 파일 디렉터리가 비었고, 세션 1은 실패했다. server log에 vacuum 삭제 기록은 없었다.

```text
ERROR: External file "70517040/ces_067/dba.t.00001793880423322744_2726" was not found.
Query execution error. ERROR_CODE = -1020
```

B. 삭제는 commit 경로 안에서 일어났다.

```text
#0 xes_posix_delete_file (path="70517040/ces_423/dba.t.00001793880423317176_4477") at es_posix.c:559
#1 es_delete_file (...) at es.c:333
#2 tx_lob_locator_clear (..., at_commit=true, savept_lsa=0x0) at transaction_transient.cpp:452
#3 log_commit_local (...) at log_manager.c:5250
```

| 경우 | 복구 로그 | 재시작 뒤 행 | 파일 |
| --- | --- | --- | --- |
| flush 없이 kill (행 1) | `transactions to undo: 0` | 옛 locator `...ces_423/..._4477` | 없음, `External file ... was not found` |
| flush 후 kill (행 2) | `transactions to undo: 1` | 옛 locator `...ces_606/..._6314` | 없음, `External file ... was not found` |
| 대조군. COMMIT 전 kill (행 3) | 해당 없음 | 옛 locator | 있음, `X'cccc'`로 읽힘 |

## Additional Information

- 원래 의심한 `RVES_NOTIFY_VACUUM` 경로도 실행했다. vacuum은 commit되지 않은 트랜잭션의 notify 레코드도 처리해 파일을 지운다. 그러나 notify가 붙는 파일은 같은 트랜잭션이 만든 것이라 rollback 뒤 이를 가리키는 행이 없다. 따라서 지금은 손상으로 이어지지 않았다. 직접 삭제를 단순히 notify로 바꾸면 이 성질이 깨진다. 이전 commit 파일에 대한 notify는 rollback 뒤 행이 다시 가리키는 파일이기 때문이다. ANALYSIS에서 두 경로를 함께 봐야 한다.
- 서버 측 DML에서는 같은 트랜잭션이 만든 LOB도 직접 삭제로 처리됐다. 파일을 클래스 디렉터리로 옮길 때 목록 항목의 키가 temp 이름으로 남아 이후 조회가 실패하기 때문이다. 의도인지 확인하지 않았다.
- READ COMMITTED에서 한 문장이 실행되는 동안 같은 문제가 생기는지, HA 복제와 백업 복원에서 어떤 영향이 있는지는 확인하지 않았다.
- 기존 이슈 CBRD-20009(2016, RQG)는 READ COMMITTED에서 DELETE와 LOB 조회를 동시에 돌리다 같은 `External file ... was not found`를 보고했다. 원인 분석 없이 열려 있으며, 위 A와 같은 증상으로 보인다. 그 테스트를 다시 돌려 확인하지는 않았다.
- CBRD-27892(트리거 테이블에서 UPDATE한 LOB가 재부팅 뒤 사라짐)는 원인이 다른 별개 결함이다. 같은 LOB 파일 수명 영역이라 함께 볼 만하다.

## Triage Request

결함으로 접수할지, CBRD-27237(OOS 삭제 알림 설계)과 같은 crash 구간 문제로 묶어 ANALYSIS할지 정해 주기 바란다.
