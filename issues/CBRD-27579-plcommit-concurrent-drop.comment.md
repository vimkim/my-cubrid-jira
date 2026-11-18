## 추가 사례: SELECT 안의 PL/CSQL COMMIT 뒤 다른 세션의 DROP TABLE 이 실행 중인 scan 의 file 을 파괴한다

규칙 1 (문장 안 TCL 거부) 이 막아야 할 또 하나의 증상이다. 앞의 사례들과 달리 server 는 종료되지 않는다. 함수의 COMMIT 이 실행 중인 SELECT 의 lock 과 MVCC snapshot 을 풀기 때문에, 다른 세션의 DROP TABLE 이 그 SELECT 를 기다리지 않고 heap, index, OOS file 을 파괴한다. SELECT 는 그 뒤에도 계속 실행되어 반환된 storage 를 읽는다.

[PR #8491 리뷰 질문](https://github.com/CUBRID/cubrid/pull/8491#pullrequestreview-5914646248) (OOS 읽기의 sector 할당 확인이 필요한가) 을 검증하다 확인했다. 검증 보고서는 [oos-read-validation.md](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-28011/oos-read-validation.md) 의 "반례 2" 다.

### Test Build

- PR #8491 head `a4fec6f8e2` (base `feature/oos-merge`), release 빌드 (RelWithDebInfo, `-DNDEBUG`), `cubrid --version` 11.5.0.2924-a4fec6f.
- 검증용 tree 는 PR head 에 환경 변수 `CUBRID_OOS_SKIP_SECTOR_PROBE` 하나만 더했다. 이 변수가 없으면 PR head 와 같은 코드를 탄다. 아래 "확인 수행" 결과는 변수 없이 실행했다.
- client/server 모드 (`csql -C`), 격리 수준 READ COMMITTED. `cubrid.conf` 는 `stored_procedure=yes`, `enable_string_compression=no` (20,000 바이트 값을 OOS 에 두기 위해) 다.
- 각 경우 1회 실행했다. 대조군 1회, table scan 과 index scan 각각 확인 수행 1회와 생략 1회다.

### Repro

```sql
CREATE TABLE t (id INT PRIMARY KEY, v VARCHAR(20000));
INSERT INTO t VALUES (1, CONCAT('AAAA1-', REPEAT('a', 19994)));
INSERT INTO t VALUES (2, CONCAT('BBBB2-', REPEAT('b', 19994)));

CREATE OR REPLACE FUNCTION f_commit (p INT) RETURN INT AS LANGUAGE PLCSQL
BEGIN
  COMMIT;
  RETURN 1;
END;

-- 세션 1
SELECT id, v FROM t WHERE f_commit (id) = 1;
-- 또는 index scan
SELECT id, v FROM t WHERE id > 0 AND f_commit (id) = 1 USING INDEX pk_t_id;

-- 세션 2, 세션 1 의 함수가 돌아온 뒤 v 를 읽기 전에
DROP TABLE t;
COMMIT;
```

두 세션의 순서는 gdb 로 맞췄다. 세션 1 의 server thread 를 `oos_read` 진입에서 멈췄다. 멈추는 조건은 같은 thread 에서 PL 함수 실행이 돌아왔고, 그 사이 같은 transaction 의 `log_commit` 이 실행된 것이다. gdb 는 breakpoint 와 읽기만 썼다. gdb 없이 이 순서를 맞추는 방법은 찾지 못했다.

### Actual Result

세션 1 이 멈춘 동안의 상태 (모든 실행에서 같았다):

- `cubrid lockdb` 가 세션 1 transaction 의 lock 을 0 개로 보고했다. 대조군 (`COMMIT` 이 없는 같은 함수) 에서는 class `t` 의 IS lock 을 포함해 11 개였다.
- 세션 1 의 transaction descriptor 에서 `mvccinfo.snapshot.valid = false`, `lowest_active_mvccid = 0` 이었다. 대조군은 `valid = true` 였다.
- query 는 계속 실행 중이었다. commit 을 처리한 `qmgr_clear_trans_wakeup ()` 이 query 를 끝내지 않았다 (gdb 에서 `died=0 abort=0`).

| 경우 | scan | sector 확인 | 세션 2 의 DROP | 세션 1 결과 |
| --- | --- | --- | --- | --- |
| 대조군 (`COMMIT` 없음) | table | 수행 | SCH-M lock 대기로 막힘 | 2 행, 정상 값 |
| A1 | table | 수행 | index, OOS, heap file 파괴를 실행한 뒤 세션 1 이 잡은 heap page latch 에서 대기 | `ER_HEAP_OOS_CORRUPTED_RECORD` (-1397) |
| A2 | index | 수행 | 세션 1 이 멈춘 동안 완료 | -1397 |
| B1 | table | 생략 | A1 과 같음 | 2 행, 파괴된 table 의 원래 값과 byte 단위로 같음, 오류 없음 |
| B2 | index | 생략 | 세션 1 이 멈춘 동안 완료 | B1 과 같음 |

- A1, A2 에서 세션 1 을 재개하자 `disk_is_page_sector_reserved` 가 OOS head page 의 sector 에 대해 `DISK_INVALID` 를 돌려주었다. OOS 읽기가 이를 -1397 로 바꾸었다.
- B1, B2 는 sector 확인을 끈 server 다. DROP 전에 checkpoint 로 OOS head page 를 disk 에 기록했다. `file_destroy` 는 buffer 의 page 를 기록하지 않고 버리므로, 재개한 scan 은 disk 에 남은 옛 image 를 읽었다.
- 같은 방식으로 세션 2 가 DROP 대신 `UPDATE t SET v = ... WHERE id = 1; COMMIT;` 을 실행하고 vacuum 이 돌게 하자, 세션 1 은 OOS slot 부재 확인에서 -1397 로 끝났다. vacuum 이 세션 1 이 아직 읽지 않은 이전 값의 OOS chain 을 회수한 것이다. 회수된 chain 이 세션 1 이 읽으려던 chain 이라는 점은 slot 부재 결과로 추론했다.

### 원인 위치 (PR #8491 head `a4fec6f8e2` 기준, 코드 읽기)

- 함수의 `COMMIT` 은 client 의 SP callback `callback_handler::end_transaction ()` 에서 `db_commit_transaction ()` 으로 간다 (`src/method/method_callback.cpp:226-235`).
- server 의 commit 은 transaction 의 모든 lock 을 푼다 (`src/transaction/log_manager.c:5318`). `logtb_complete_mvcc ()` 는 snapshot 을 무효로 만든다 (`src/transaction/log_tran_table.c:4483-4504`).
- `qmgr_clear_trans_wakeup ()` 은 PL 세션이 실행 중이면 진행 중인 query 를 끝내지 않고 둔다 (`src/query/query_manager.c:2407-2431`).
- 그래서 SELECT 의 scan 은 lock 과 snapshot 없이 이미 복사한 heap record 를 계속 처리한다. 이 상태에서는 DROP 의 SCH-M lock 도, vacuum 의 snapshot 기준도 이 scan 을 보호하지 않는다.

### 규칙 1 과의 관계

PR #8182 head `13105c1636` 의 `callback_handler::end_transaction ()` 은 commit 전에 `sp_check_statement_allowed (SP_STMT_TCL, ...)` 를 부른다 (`src/method/method_callback.cpp:233`). SQL 문 안에서 불린 SP 이면 `ER_SP_TCL_DDL_IN_QUERY` 를 돌려준다. 위 재현의 `COMMIT` 이 이 경로를 지나므로, 규칙 1 이 들어가면 세션 1 의 SELECT 는 lock 과 snapshot 을 유지한 채 오류로 끝나고 세션 2 의 DROP 은 기다릴 것이다. 코드만 확인했고, PR #8182 빌드로 실행하지는 않았다.

이 사례를 위한 별도 회귀 test 는 필요 없어 보인다. SELECT 의 WHERE 에서 부른 함수의 `COMMIT` 이 거부되는지 규칙 1 의 test 가 확인하면, 이 사례도 함께 막힌다. PR #8182 의 test 목록은 확인하지 않았다. 이 사례가 더하는 것은 영향 범위다. 문장 안 TCL 은 server 종료나 결과 불일치뿐 아니라, 실행 중인 scan 이 다른 세션의 DDL 과 vacuum 으로부터 보호받지 못하게 만든다. OOS 의 sector 할당 확인이 지금 release 빌드에서 이를 막는 유일한 확인이다. 따라서 그 확인을 줄일 수 있는지는 규칙 1 이 들어간 뒤에 다시 판단한다. 이 판단은 [CBRD-28187](https://jira.cubrid.org/browse/CBRD-28187) 에서 추적하며, CBRD-28187 은 이 이슈에 막혀 있다.

### 확인하지 않은 것

- OOS 가 아닌 column 만 읽는 scan 이 파괴된 heap file 의 page 를 읽을 때의 결과. A2 에서 DROP 이 heap file 까지 파괴한 뒤에도 SELECT 가 살아 있었으므로 같은 상태에 들어갈 수 있다. 실행하지 않았다.
- debug 빌드, CAS 또는 JDBC client, Java SP, SP 안의 ROLLBACK, 반환된 sector 를 다른 file 이 다시 예약한 경우.
