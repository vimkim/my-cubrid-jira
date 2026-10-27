# [OOS] rollback 된 UPDATE 의 옛 OOS 체인을 vacuum 이 삭제해 살아있는 행이 손상됨

## Issue Triage

**이슈 수행 목적**: UPDATE 를 포함한 트랜잭션이 어떤 방식으로 abort 되더라도(명시적 ROLLBACK, deadlock 희생, 연결 끊김, 서버 장애 후 복구 undo) 복원된 행의 OOS (Out-of-row Storage — heap 레코드의 큰 가변 컬럼 값을 별도 OOS 파일에 저장하는 방식) 값이 vacuum 이후에도 그대로 읽히도록 한다. commit 된 UPDATE 가 버린 옛 체인은 지금처럼 vacuum 이 회수해야 한다.

**이슈 수행 이유**: vacuum 의 OOS forward-walk(`vacuum_forward_walk_reclaim_oos`)는 `RVHF_UPDATE_NOTIFY_VACUUM` 과 `RVHF_DELETE_NEWHOME_NOTIFY_VACUUM` 로그의 undo image(변경 전 행을 로그에 남긴 사본)에 있는 OOS 참조를 삭제 근거로 삼는다. 이때 그 연산이 commit 되었는지도, 현재 행이 그 체인을 아직 참조하는지도 확인하지 않는다. rollback 은 undo image 를 행에 바이트 그대로 복원하므로, 복원된 행이 참조하는 체인을 vacuum 이 지운다. 2026-08 소스 분석으로 제기했고, 2026-09 SERVER_MODE 단위 테스트로 재현했다. 2026-10-27 에는 PR #7990 리뷰어(shparkcubrid)가 SQL 수준에서 재현해 머지 차단 사유로 지적했다.

**영향**: OOS 값을 가진 행을 UPDATE 한 트랜잭션이 abort 되면, vacuum 이 지난 뒤 그 값을 읽는 질의가 `-1389`(`ER_HEAP_OOS_CORRUPTED_RECORD`)로 실패한다. 리뷰어는 이를 값의 영구 손실로 보고했다. 리뷰어 재현에 따르면 OOS 가 아닌 작은 컬럼만 바꾼 UPDATE, OOS 컬럼을 NULL 로 바꾼 UPDATE, 미커밋 UPDATE 중 서버 kill -9 후 재기동한 경우에도 같다. DELETE 와 INSERT 의 rollback, commit 된 UPDATE 는 정상이다. OOS 는 출시되지 않아 고객 영향은 없지만, `develop` 머지(PR #7990)와 CBRD-27089 최종 검증을 막는다. 발생에 경쟁 조건이 필요하지 않아, abort 뒤 vacuum 이 해당 로그를 처리하면 매번 발생한다(리뷰어 재현과 소스 분석). 운영 환경에서의 빈도는 측정하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다. 2026-09-09 코멘트에 따라 CBRD-27230 이 이 결함을 해결한다고 가정하지 않고 CBRD-27237 전용 수정으로 다룬다. 후보 비교는 Options for Analysis 에 둔다.

---

## AI-Generated Context

> 아래는 제공된 자료와 확인한 근거를 바탕으로 작성한 상세 맥락이다. 미확인 사항은 본문에 구분한다.

## Description

### 무엇이 문제인가

**배경.** OOS 는 heap 레코드가 커질 때 큰 가변 컬럼 값을 OOS 파일의 체인(chunk 연결)으로 옮기고, heap 레코드에는 24 바이트 inline stub(head OOS OID 8 + 길이 8 + identity stamp 8, `src/storage/oos_file.hpp:79-80`)만 남긴다. vacuum(어떤 트랜잭션에도 더 이상 보이지 않는 옛 레코드 버전을 회수하는 백그라운드 프로세스)은 로그를 고정 크기 블록 단위로 읽어 회수할 대상을 찾는다.

SERVER_MODE 의 MVCC UPDATE 는 OOS 값을 새 체인으로 다시 쓴다. 옛 체인은 UPDATE 로그(`RVHF_UPDATE_NOTIFY_VACUUM`)의 undo image 에서만 참조된다고 보고, vacuum 은 forward-walk 로 undo image 의 stub 을 읽어 옛 체인을 지운다. 호출부 주석도 이 전제를 적고 있다: "The old ones survive only in the undo image; the live slot no longer points at them"(`src/query/vacuum.c:3608-3615`). relocated 행(home 에는 REC_RELOCATION, 실제 데이터는 forward 페이지의 REC_NEWHOME)의 UPDATE 가 옛 forward 레코드를 지울 때는 `RVHF_DELETE_NEWHOME_NOTIFY_VACUUM` 로그의 undo image 로 같은 일을 한다(`vacuum.c:3757-3770`, 기록 지점은 `heap_update_relocation`, `src/storage/heap_file.c:24886-24895`).

heap 회수 경로는 이와 다르다. heap vacuum 은 현재 레코드를 다시 읽고, 연산이 rollback 되었으면 아무것도 하지 않는다("... it was rollbacked and reused", `vacuum.c:1855-1856`). forward-walk 만 현재 페이지 상태를 보지 않는다.

**현재 동작.** rollback 이 위 전제를 깬다. PR #7990 head `dcbf09e4f` 소스에서 확인한 사실은 다음과 같다.

1. MVCC 연산 로그는 append 시점에 vacuum 용 연결 목록에 들어간다(`prior_lsa_next_record_internal`, `src/transaction/log_append.cpp:1378`, 연결은 `:1446`). rollback 은 보상 로그를 덧붙일 뿐 이미 기록된 UPDATE 로그를 목록에서 빼지 않는다.
2. abort 도 commit 과 같이 MVCCID 를 은퇴시킨다. `log_abort_local`(`src/transaction/log_manager.c:5368`)은 `log_rollback`(`:5383`)을 마친 뒤 `logtb_complete_mvcc`(`:5396`)를 호출한다. oldest visible MVCCID 가 그 뒤로 전진하면 해당 로그 블록이 vacuum worker 에 배포된다.
3. `vacuum_process_log_record`(`vacuum.c:4121`)는 dropped file(`:4243-4272`)과 rcvindex(로그 레코드에 붙는 복구 루틴 태그) 목록(`:4275-4283`)만 거르며, commit 과 abort 를 구분하지 않는다. 두 분기(`:3616-3626`, `:3757-3770`)는 조건 없이 `vacuum_forward_walk_reclaim_oos`(`src/query/vacuum_oos.cpp:266-369`)를 호출한다. 이 함수와 실제 삭제를 하는 `vacuum_forward_walk_oos_delete_atomic`(`:152-210`)도 트랜잭션 결과나 현재 행을 확인하지 않는다.
4. rollback 의 undo 는 pre-image 를 바이트 그대로 복원한다. `RVHF_UPDATE_NOTIFY_VACUUM` 의 undo 인 `heap_rv_undo_update`(`src/transaction/recovery.c:352-357`, `heap_file.c:18620`)는 undo image 를 `heap_update_physical` 로 그대로 쓴다. `RVHF_DELETE_NEWHOME_NOTIFY_VACUUM` 의 undo 인 `heap_rv_undo_delete`(`recovery.c:921-926`, `heap_file.c:18585`)는 옛 forward 레코드를 같은 슬롯에 다시 넣는다. UPDATE 가 새로 만든 체인은 `RVOOS_INSERT` 의 undo(`oos_rv_redo_delete`, `recovery.c:881-886`)로 지워진다. 결과적으로 undo image 의 stub 이 가리키는 체인이 곧 복원된 행의 체인이 된다.
5. CBRD-26950 의 identity stamp 로도 막히지 않는다. `oos_delete` 는 head chunk 의 stamp 가 참조의 stamp 와 같을 때만 체인을 지운다(`oos_file.hpp` 의 `oos_delete` 설명). 복원된 stub 과 undo image 의 stub 은 같은 바이트이므로 (head OID, stamp) 가 일치하고, 삭제가 진행된다.
6. 모든 UPDATE 가 OOS 체인을 새로 쓴다. `heap_attrinfo_transform_to_disk_internal`(`heap_file.c:14171`)은 UPDATE 가 지정하지 않은 컬럼도 옛 레코드에서 다시 읽는다(`heap_attrinfo_set_uninitialized`, `:12933`). 이어서 행 전체로 OOS 배치를 다시 정하고(`heap_attrinfo_determine_disk_layout`, `:13137`), 선택된 모든 컬럼을 새 체인으로 넣는다(`heap_attrinfo_insert_to_oos`, `:13520`). CBRD-27230 이 다루는 미지정 컬럼의 체인 재사용은 구현되지 않았다. 따라서 OOS 가 아닌 작은 컬럼만 바꾼 UPDATE 와 OOS 컬럼을 NULL 로 바꾼 UPDATE 의 undo image 에도 옛 체인 참조가 모두 들어 있어 같은 결과가 된다.

사고 시퀀스:

```
1. UPDATE (OOS 값을 가진 행; 바꾼 컬럼과 무관)
     -> 모든 OOS 컬럼을 새 체인으로 기록
     -> RVHF_UPDATE_NOTIFY_VACUUM 로그 (undo image = 옛 stub 을 담은 pre-image)
2. abort (ROLLBACK, deadlock 희생, 연결 끊김, 재기동 후 복구 undo)
     -> pre-image 를 바이트 그대로 복원, 새 체인만 RVOOS_INSERT undo 로 제거
     => 옛 체인 = 복원된 행이 참조하는 체인
3. abort 한 MVCCID 은퇴 -> 로그 블록이 vacuum worker 에 배포
4. forward-walk 가 undo image 의 (head OID, stamp) 로 oos_delete
     -> stamp 일치, 삭제는 vacuum sysop 으로 commit (vacuum_oos.cpp:190)
     => 복원된 행의 체인 삭제. 이 시점에는 오류나 경고가 없음
5. 이후 그 값을 읽는 질의 -> -1389 ER_HEAP_OOS_CORRUPTED_RECORD
```

**발생 경로와 근거.** 경로별 확인 상태는 다음과 같다.

| 경로 | 근거 | 상태 |
|---|---|---|
| OOS 컬럼을 바꾼 UPDATE 후 ROLLBACK | 리뷰어 SQL 재현, 2026-09 SERVER_MODE gtest | 재현됨 |
| OOS 가 아닌 작은 컬럼만 바꾼 UPDATE 후 ROLLBACK | 리뷰어 SQL 재현, 위 사실 6 | 재현됨 |
| OOS 컬럼을 NULL 로 바꾼 UPDATE 후 ROLLBACK | 리뷰어 SQL 재현 | 재현됨 |
| 미커밋 UPDATE 중 서버 kill -9, 재기동 후 복구 undo, 이어서 vacuum | 리뷰어 재현. 재기동 복구의 undo 단계도 같은 undo 함수를 호출한다(`src/transaction/log_recovery.c:173`, `:288`) | 재현됨 |
| 연결 끊김 | `xboot_unregister_client`(`src/transaction/boot_sr.c:3361`)가 활성 트랜잭션을 `xtran_server_abort` 로 abort 한다(`:3414-3433`). 리뷰어 추론 | 소스 확인, 런타임 미확인 |
| deadlock 희생 | 시스템이 희생 트랜잭션을 unilateral abort 한다(`lock_set_error_for_aborted`, `src/transaction/lock_manager.c:2299`, `ER_LK_UNILATERALLY_ABORTED`). 리뷰어 추론 | 소스 확인, 런타임 미확인 |
| relocated 행의 UPDATE 후 rollback(`RVHF_DELETE_NEWHOME_NOTIFY_VACUUM` 분기) | 위 사실 3, 4. 리뷰어도 코드로 같은 구조를 지적 | 소스 확인, 런타임 미확인 |
| savepoint 로의 부분 rollback 뒤 트랜잭션 commit | `log_abort_partial`(`log_manager.c:5649`)도 savepoint 이후를 같은 undo 로 되돌리고 트랜잭션은 계속된다 | 소스 추론, 미확인(ANALYSIS) |
| DELETE 후 rollback, INSERT 후 rollback, UPDATE 후 commit | 리뷰어 SQL 재현 | 정상 |
| SA_MODE 의 UPDATE 후 rollback | 비-SERVER_MODE 에서는 `HEAP_UPDATE_IS_MVCC_OP` 가 상수 false 라(`heap_file.c:169-174`) `RVHF_UPDATE_NOTIFY_VACUUM` 이 기록되지 않는다. 옛 체인은 UPDATE 시점에 트랜잭션 안에서 지워지고(`heap_file.c:25211-25222`, `:24722-24737`), rollback 이 그 삭제를 되돌린다 | 해당 없음 |

**기존 분석과의 관계.** CBRD-26668 의 rollback 검토는 abort 진행 중 창을 다뤘다. visibility gate 와 abort 순서(`log_rollback` 이 `logtb_complete_mvcc` 보다 먼저)로 vacuum 이 abort 도중에 끼어들 수 없음을 보였다. 그러나 abort 완료 후 창, 즉 MVCCID 가 은퇴한 뒤에도 같은 undo image 가 vacuum 연결 목록에 남아 있는 구간은 그 논증의 범위 밖이다. 이 구간에서 4 단계를 막는 메커니즘은 소스에서 찾지 못했다.

### 왜 문제인가

응용은 큰 문자열이나 바이너리처럼 OOS 로 저장되는 값을 가진 행을 갱신하는 트랜잭션을 실행한다. 그 트랜잭션이 abort 되면 사용자는 행이 마지막으로 commit 한 값으로 남기를 기대하고, rollback 직후 조회도 실제로 정상이다. 그러나 이후 vacuum 이 해당 로그 블록을 처리하면 그 행의 OOS 값이 지워진다. vacuum 은 사용자 작업과 무관한 백그라운드 시점에 동작하며, 그 뒤 값을 읽는 질의가 `-1389` 로 실패한다. 이 흐름이 다음 비용과 위험으로 이어진다.

- **commit 된 데이터의 영구 손실**: 잃는 값은 abort 된 변경이 아니라 그 전에 commit 된 값이다. vacuum 의 삭제는 자체 sysop 으로 commit 되므로(`vacuum_oos.cpp:190`) 이후 어떤 rollback 으로도 복원되지 않는다. 리뷰어는 이를 "공간 누수가 아니라 데이터 손실" 로 정리했다.
- **흔한 조건에서 발생**: 특별한 SQL 이 필요하지 않다. OOS 값을 가진 행에 대한 UPDATE 와 abort 만 있으면 되며, 작은 컬럼만 바꾼 UPDATE 도 해당한다. abort 는 응용의 명시적 ROLLBACK 외에 deadlock, 연결 끊김, 서버 장애처럼 사용자가 통제할 수 없는 사건에서도 생긴다. 경쟁 조건이 필요하지 않아 abort 뒤 vacuum 이 지나가면 매번 발생한다(리뷰어 재현과 소스 분석). 운영 부하에서의 빈도는 측정하지 않았다.
- **진단이 어렵다**: rollback 직후에는 정상이고 vacuum 시점에는 오류나 경고가 없다. 사용자는 나중에 그 값을 읽을 때에야 "out-of-row storage record metadata is inconsistent or corrupted" 를 보며, 어느 트랜잭션이 원인이었는지 알 수 없다.
- **행 단위를 넘는 영향(예상)**: 손상된 행을 포함하는 전체 스캔, unloaddb 처럼 그 값을 읽는 작업도 그 행에서 실패할 것으로 예상한다. 이 범위는 확인하지 않았다.
- **현재 테스트가 놓친다**: `unit_tests/oos/sql/test_oos_sql_txn.cpp:78-107` 의 TC-02 는 SA_MODE 로 빌드되고(`unit_tests/oos/sql/CMakeLists.txt:20-34`) rollback 직후만 확인한다. SA_MODE 에서는 이 경로의 로그가 기록되지 않으므로 이 결함을 잡을 수 없다.

OOS(`feat/oos`, PR #7990 로 `develop` 머지 검토 중)는 출시되지 않아 고객 장애는 아직 없다.

### 왜 해결해야 하는가

- **rollback 계약 위반**: abort 된 트랜잭션은 이전 commit 상태를 남겨야 한다. 지금은 잠시 복원했다가 나중에 그 값을 잃는다. 데이터 손실이므로 성능 개선처럼 미룰 수 있는 문제가 아니다.
- **머지 차단**: PR #7990 리뷰어가 이 결함을 블로킹으로 지정했다(review 5662427700, CHANGES_REQUESTED, 2026-10-27). 리뷰어는 PR 본문이 미구현으로 적은 CBRD-27237 이 이 문제이며 머지 전에 고쳐야 한다고 적었다. 이 이슈의 제목 태그도 `[fix-before-release]` 다. 수정 없이 `develop` 에 들어가면 `develop` 기반 개발과 QA 에서 같은 손실이 생긴다.
- **CBRD-27089 의 선행 조건**: 2026-09-09 코멘트대로, 이 결함이 남아 있으면 rollback 직후 조회만으로는 값의 수명 보존을 입증할 수 없다. 그래서 CBRD-27089 의 SERVER lifecycle 검증과 최종 acceptance 를 완료할 수 없다.
- **우회책이 없다**: 사용자는 deadlock, 연결 끊김, 서버 장애로 인한 abort 를 피할 수 없다. vacuum 을 멈추면 MVCC 공간 회수 전체가 멈추고, OOS 값을 가진 행의 UPDATE 를 피하라는 것도 대안이 아니다.
- **CBRD-27230 과의 순서**: CBRD-27230 이 미지정 컬럼의 체인 재사용을 넣으면, 같은 체인이 undo image 와 새 레코드에 함께 남는다. 그러면 지금의 forward-walk 는 commit 된 UPDATE 에서도 살아있는 체인을 지우게 된다(소스 추론). 어느 쪽이 먼저 들어가든 forward-walk 의 삭제 근거를 바꿔야 한다. 2026-09-09 기준으로 CBRD-27230 이 이 결함을 해결한다고 가정하지 않는다.

## Test Build

- 소스 확인: `feature/oos-merge`(PR #7990 head) @ `dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67`. 본문의 줄 번호는 이 커밋 기준이다. 리뷰어 재현 엔진 `5a70787fe` 이후의 커밋(리뷰 대상 `4408135c0` 포함)은 이 이슈의 경로(`src/query/`, `src/storage/heap_file.c`, `src/storage/heap_oos.cpp`, `src/storage/oos_file.*`, `src/transaction/recovery.*`, `src/transaction/log_append.cpp`, `src/transaction/log_manager.c`, `src/transaction/log_tran_table.c`)를 바꾸지 않았다. 이 경로들에 대한 `git diff 5a70787fe dcbf09e4f` 결과가 비어 있다.
- 리뷰어 재현: 리뷰 본문 기준 PR #7990 head 엔진 코드 `5a70787fe` 의 debug 빌드다. 리뷰 대상 commit 은 `4408135c0` 이다. OS 와 설정은 리뷰에 적혀 있지 않다.
- 이전 SERVER_MODE gtest 재현(2026-09-08): CBRD-27089(PR #7600)의 기준 엔진 `b871ea386d2c5419b7abae07dda58b9b7f36377a` 와 그 위의 routing 변경 엔진, `debug_gcc` 구성.
- 최초 소스 분석: `feat/oos` @ `725a32c6e`(2026-08-13). 그 판의 예상 시퀀스는 실행하지 않았고, 아래의 리뷰어 재현으로 대체한다.
- 출시 버전: 11.4 이하는 OOS 가 없어 해당하지 않는다. 11.5 는 미출시다.

## Repro

### 리뷰어 SQL 재현

아래 SQL 은 PR #7990 리뷰어(shparkcubrid)가 인라인 코멘트(https://github.com/CUBRID/cubrid/pull/7990#discussion_r4385247867)에 적은 그대로다. 리뷰어가 debug 빌드에서 실행했고, 우리는 다시 실행하지 않았다.

```sql
-- big에는 압축되지 않는 30,000자 무작위 문자열을 넣습니다 (REPEAT 값은 압축되어 OOS로 가지 않습니다)
create table t(id int primary key, k int, big varchar(200000));
insert into t values(1, 1, '<random 30000>');  commit;
update t set k = 99 where id = 1;  rollback;
select length(big) from t;   -- 30000
-- 다른 테이블에 커밋을 몇 번 하고 vacuum이 돌게 둡니다 (또는 vacuumdb)
select length(big) from t;   -- ERROR -1389 out-of-row storage record metadata is inconsistent or corrupted
```

리뷰어는 같은 절차에서 UPDATE 를 `update t set big = ...`(OOS 컬럼 변경)와 `update t set big = NULL` 로 바꾼 경우, DELETE 와 INSERT 를 rollback 한 경우, UPDATE 를 commit 한 경우도 보고했다(Actual Result 참조).

서버 장애 경로에 대한 리뷰어 보고는 다음과 같다: "커밋하지 않은 UPDATE가 남은 상태에서 서버를 kill -9 하고 재기동해도 같습니다. 복구 undo 뒤 vacuum이 돌면 같은 오류가 납니다."

### 실행 예(제안, 미실행)

리뷰어 SQL 의 `'<random 30000>'` 자리를 채우고 서버 모드로 실행하는 예다. 우리는 실행하지 않았다. OOS 를 지원하는 debug 빌드로 만든 `testdb` 를 서버로 기동한 상태를 가정한다. vacuum 이 처리할 로그 블록이 마감되려면 로그가 충분히 쌓여야 하므로, filler 반복 횟수는 환경에 따라 늘려야 할 수 있다.

```sh
cubrid server start testdb

python3 - <<'EOF'
import random, string
rnd = lambda n: ''.join(random.choices(string.ascii_letters + string.digits, k=n))
with open('repro.sql', 'w') as f:
    f.write("create table t(id int primary key, k int, big varchar(200000));\n")
    f.write("insert into t values(1, 1, '%s');\ncommit;\n" % rnd(30000))
    f.write("update t set k = 99 where id = 1;\nrollback;\n")
    f.write("select length(big) from t;\n")
with open('filler.sql', 'w') as f:
    f.write("create table f(i int, s varchar(4000));\ncommit;\n")
    for i in range(500):
        f.write("insert into f values(%d, '%s');\ncommit;\n" % (i, rnd(3000)))
EOF

csql -C -u dba --no-auto-commit -i repro.sql testdb    # 리뷰어 보고: 30000
csql -C -u dba --no-auto-commit -i filler.sql testdb
sleep 30                                               # vacuum 이 블록을 처리할 시간
csql -C -u dba -c "select length(big) from t" testdb   # 리뷰어 보고: ERROR -1389
```

### 이전 SERVER_MODE gtest 재현

2026-09-08 CBRD-27089 작업 중 `unit_tests/oos/test_oos_real_vacuum_server.cpp` 에 `OosRealVacuum.RolledBackUpdateKeepsCommittedOosAfterVacuum` 를 추가해 재현했다(2026-09-09 코멘트). 이 테스트는 SQL 이 아닌 heap/OOS 하위 경로를 쓰며, 순서는 다음과 같다.

1. 원래 OOS 값 A 를 가진 행과, vacuum 진행 확인용 witness 행을 각각 commit 한다.
2. 실제 MVCC heap UPDATE 로 A 를 B 로 바꾼 뒤 abort 하고, A 가 정상으로 읽히는지 확인한다.
3. witness 를 DELETE 후 commit 하고, 로그 블록을 마감한 다음 witness 의 OOS 체인이 실제로 회수될 때까지 기다린다.
4. A 를 다시 읽는다.

이 테스트는 PR #7990 에 포함되어 있지 않다. CBRD-27089 작업 브랜치(commit `479cd960e`)에 `DISABLED_` 상태로 보존되어 있다.

## Expected Result

- abort 경로(명시적 ROLLBACK, deadlock 희생, 연결 끊김, 서버 장애 후 복구 undo)와 무관하게, 복원된 행의 OOS 값이 vacuum 이후에도 그대로 읽힌다. 리뷰어 SQL 에서 두 번째 `select length(big) from t` 도 `30000` 을 반환한다.
- UPDATE 가 OOS 컬럼을 바꾸든, 작은 컬럼만 바꾸든, OOS 컬럼을 NULL 로 바꾸든 같다. relocated 행의 UPDATE(`RVHF_DELETE_NEWHOME_NOTIFY_VACUUM` 분기)도 같다.
- 부분 rollback 이 이 결함에 해당하는 것으로 확인되면, savepoint 이후를 되돌린 UPDATE 의 옛 체인도 보존된다.
- commit 된 UPDATE 가 버린 옛 체인은 계속 vacuum 이 회수한다. 수정이 OOS 공간 누수를 만들지 않는다.
- DELETE 와 INSERT 의 rollback, commit 된 UPDATE 는 지금처럼 정상이다.

## Actual Result

### 리뷰어 런타임 보고(2026-10-27)

PR #7990 리뷰어가 debug 빌드에서 재현한 결과다. 우리는 다시 실행하지 않았다.

| 시나리오 | rollback 직후 | vacuum 후 |
|---|---|---|
| UPDATE big 후 rollback | 정상 | -1389 |
| UPDATE k(작은 컬럼) 후 rollback | 정상 | -1389 |
| UPDATE big=NULL 후 rollback | 정상 | -1389 |
| DELETE 후 rollback, INSERT 후 rollback, UPDATE 후 commit | 정상 | 정상 |

- 미커밋 UPDATE 중 서버를 kill -9 하고 재기동하면, 복구 undo 뒤 vacuum 이 돌 때 같은 오류가 난다(리뷰어 보고).
- 리뷰어는 이로부터 deadlock 희생자, 연결 끊김, 서버 장애에서도 값이 영구히 사라진다고 판단했다. 연결 끊김과 deadlock 희생은 소스로 같은 abort 경로임을 확인했지만, 런타임으로는 확인하지 않았다.
- `-1389` 는 `ER_HEAP_OOS_CORRUPTED_RECORD`("Internal error: out-of-row storage record metadata is inconsistent or corrupted.")다. stale 참조를 받은 `oos_read` 는 head 슬롯이 비었거나 stamp 가 다르면 이 오류로 거부한다(`oos_file.hpp` 의 `oos_read` 설명). 2026-08 판은 slot not allocated 계열 오류를 예상했으나, 현재 소스에서는 이 오류로 보고된다.

### 이전 SERVER_MODE gtest 결과(2026-09-08)

- abort 직후에는 A 가 정상으로 읽혔다. witness 회수를 확인한 뒤에는 A 의 읽기가 실패했다(반환값 `-2`).
- 기준 엔진 `b871ea386` 에서 3/3 실패했다. 이 중 1 회는 테스트를 기준 worktree 에서 따로 빌드해 실행한 결과다. routing 변경 엔진에서도 2/2 실패했다.
- 하위 heap/OOS 테스트이며 SQL 경로, 파티션 이동, 서버 장애 복구는 다루지 않는다.

### 런타임으로 확인하지 않은 경로

- `RVHF_DELETE_NEWHOME_NOTIFY_VACUUM` 분기(relocated 행): 소스 구조가 UPDATE 분기와 같다. 리뷰어도 코드로 지적했다.
- 연결 끊김, deadlock 희생: 같은 `log_abort` 경로로 abort 된다(Description 의 표).
- 부분 rollback: 소스 추론만 있다.

## Additional Information

- **상위 이슈와 범위**: 상위는 CBRD-26583(OOS M2)이다. 이 하위 작업의 범위는 abort 로 복원된 행이 참조하는 OOS 체인을 vacuum forward-walk 가 지우는 결함이다. `RVHF_UPDATE_NOTIFY_VACUUM` 과 `RVHF_DELETE_NEWHOME_NOTIFY_VACUUM` 두 분기, 모든 abort 경로, 이를 잡는 SERVER_MODE 회귀 테스트를 포함한다. 아래 관련 이슈의 결함은 범위 밖이다.
- **경위**: 2026-08-13 소스 분석으로 등록했다(`725a32c6e`, 런타임 미재현). 2026-09-08 CBRD-27089 검증 중 SERVER_MODE gtest 로 재현했다(2026-09-09 코멘트). 2026-10-27 PR #7990 리뷰어가 SQL 수준에서 재현하고 작은 컬럼 UPDATE, NULL UPDATE, 서버 장애 복구, `RVHF_DELETE_NEWHOME_NOTIFY_VACUUM` 분기를 추가로 지적했다. 리뷰: https://github.com/CUBRID/cubrid/pull/7990#pullrequestreview-5662427700
- **CBRD-26950**(Closed): 같은 "forward-walk 가 로그 내용만 믿는다" 구조에서 생긴 결함이었지만, vacuum 블록 재시도 중 슬롯 재사용이 조건이었다. 그 수정인 identity stamp 는 반영되었으나 이 결함은 막지 못한다. rollback 으로 복원된 stub 이 undo image 와 같은 (head OID, stamp) 를 갖기 때문이다.
- **CBRD-27230**: 변경 없는 OOS 값 중복 적재 방지. 미지정 컬럼의 체인 재사용은 아직 구현되지 않았으며, 그래서 작은 컬럼 UPDATE 도 이 결함에 해당한다. 그쪽에서 검토하는 commit 조건부 알림 로그가 채택되면 forward-walk 가 제거될 수 있으나, 2026-09-09 기준으로 이 결함의 해결을 그쪽에 의존하지 않는다.
- **CBRD-26668**: vacuum-OOS 통합 원 이슈. rollback 검토가 abort 진행 중 창만 다룬 경위는 Description 참조.
- **CBRD-27089**: 최종 검증이 이 결함의 수정에 의존한다(2026-09-09 코멘트).
- **CBRD-27781**: 정당한 OOS 삭제의 undo 가 다른 트랜잭션이 재사용한 슬롯과 충돌하는 다른 결함이다. 이 이슈는 삭제 근거가 잘못된 문제다.

## Options for Analysis

아래는 ANALYSIS 에서 비교할 후보이며, 선택된 설계가 아니다. 첫째와 둘째는 2026-08 판의 후보이고, 셋째는 리뷰어의 지적("현재 행의 stub이 그 값을 아직 가리키는지도 확인하지 않습니다")에서 도출했다.

| 후보 방안 | 기대 효과와 장점 | 한계·단점과 실패 조건 | 비용·위험·호환성 | 근거와 ANALYSIS 확인 사항 |
|---|---|---|---|---|
| commit 조건부 알림 로그로 버린 체인을 명시하고 forward-walk 제거(CBRD-27230 에서 검토하던 구조, 예약만 된 `RVOOS_NOTIFY_VACUUM`, `src/transaction/recovery.h:206-209`) | 삭제 근거가 commit 된 연산에서만 생긴다. 전체 rollback, 모든 abort 경로, 두 분기를 함께 해소한다. CBRD-27230 의 체인 재사용과도 양립한다 | 부분 rollback 이 있으면 commit 시점에 실제로 버려진 체인만 골라야 한다. commit 과 알림 사이 장애에서 알림이 빠지면 누수가 생긴다(손실은 아님) | 새 로그 기록과 발행 지점, recovery 와 vacuum 의미 변경. 설계가 확정되지 않았다 | commit 시점 실행에 기존 postpone 계열 메커니즘을 쓸 수 있는지, 부분 rollback 처리 방법 |
| forward-walk 진입 전 트랜잭션 commit 여부 확인 | forward-walk 를 유지한 최소 수정이다. 전체 rollback 과 모든 abort 경로를 막는다 | vacuum 은 은퇴한 MVCCID 의 commit/abort 결과를 보관하지 않으므로, 로그에서 트랜잭션 종료 레코드를 찾거나 abort 된 MVCCID 집합을 유지해야 한다. 부분 rollback 뒤 commit 한 트랜잭션은 막지 못한다(소스 추론) | 판정을 위한 로그 읽기나 상태 보관 비용. 재기동 복구로 abort 된 트랜잭션도 판정해야 한다 | 판정 정보의 출처와 비용, 부분 rollback 이 실제로 이 결함을 일으키는지 |
| 삭제 전에 현재 행이 그 체인을 아직 참조하는지 확인 | heap vacuum 의 "rollbacked and reused" 재확인과 같은 방식이다. 전체 rollback 과 부분 rollback 을 같은 방법으로 다룬다 | 현재 행만 보면, 더 새로운 미커밋 UPDATE 가 행을 바꾼 상태에서는 옛 체인을 지울 수 있다. 그 체인은 그 UPDATE 의 이전 버전(undo log)을 통해 다른 snapshot 이 아직 읽을 수 있다(소스 추론). `DELETE_NEWHOME` 분기는 지워진 forward 슬롯이 아니라 home 을 거쳐 현재 레코드를 찾아야 한다 | forward-walk 에서 heap 페이지를 fix 해야 하므로 latch 순서와 성능을 검토해야 한다 | 확인해야 할 버전 범위, latch 순서, relocated 행에서 현재 레코드를 찾는 방법 |

첫째 후보는 삭제 근거 자체를 commit 된 연산으로 한정해 가장 근본적이고 CBRD-27230 과도 맞지만, 설계가 정해지지 않았고 변경 범위가 가장 크다. 둘째는 변경이 작지만, 부분 rollback 이 이 결함을 일으킨다면 그 경우를 막지 못한다. 셋째는 rollback 종류와 무관하게 동작하지만, 동시 UPDATE 와 MVCC 이전 버전을 함께 고려하지 않으면 같은 손실을 다른 조건에서 남길 수 있다. 부분 rollback 의 실제 영향, commit 판정 비용, 동시 UPDATE 시나리오의 결과를 근거로 ANALYSIS 에서 선택한다. 어느 후보든 아래 회귀 테스트를 통과해야 한다.

## Triage Request

이 결함을 확인하고 OOS 담당(이 이슈의 작성자 측)에 ANALYSIS 를 배정해 주기를 요청한다. ANALYSIS 에서 확인할 사항은 다음과 같다.

- Options for Analysis 의 후보 비교와 선택.
- 적용 범위: 두 forward-walk 분기와 모든 abort 경로. 런타임으로 확인하지 않은 연결 끊김, deadlock 희생, relocated 행 경로의 재현과, 부분 rollback 이 이 결함을 일으키는지의 확인.
- 회귀 테스트: SERVER_MODE 에서 abort 뒤 vacuum 진행을 확인한 다음 값을 읽는 테스트. 리뷰어 SQL 시나리오 세 가지, relocated 행, 서버 kill -9 후 재기동 시나리오를 포함하고, 보존된 `RolledBackUpdateKeepsCommittedOosAfterVacuum` 을 활성화한다. commit 된 UPDATE 의 옛 체인이 계속 회수되는지도 함께 확인한다. rollback 직후만 보는 SA_MODE TC-02 로는 부족하다.
- CBRD-27230 의 체인 재사용과의 순서와 설계 정합성.
- release 빌드에서의 증상. 리뷰어 보고는 debug 빌드 기준이다.
