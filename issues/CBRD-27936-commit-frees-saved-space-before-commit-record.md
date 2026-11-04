# [Recovery] commit이 commit 로그보다 먼저 saved space를 풀어, 재시작 복구의 DELETE undo가 공간 부족으로 실패할 수 있다

**한 줄 요약**: Sidecar 설계 중 TLA+ 모델 검사와 코드 읽기로 찾은 develop 결함으로, `log_commit_local`이 commit 로그를 쓰기 전에 삭제 트랜잭션의 saved space를 풀어 다른 트랜잭션이 그 바이트를 쓸 수 있고, 그 직후 서버가 중단되면 재시작 복구가 삭제를 되돌리지 못하고 멈출 수 있음을 다룬다.

## Issue Triage

**이슈 수행 목적**: 삭제한 트랜잭션이 commit 도중 서버가 중단되어도, 재시작 복구가 그 삭제를 되돌릴 공간을 항상 찾아 DB를 정상으로 연다.

**이슈 수행 이유**: heap 페이지는 트랜잭션이 지운 레코드의 바이트를 그 트랜잭션의 undo를 위해 예약한다(saved space). develop `e64a04a79`의 `log_commit_local`은 이 예약을 commit 로그를 추가하기 전에 푼다. postpone 로그가 없는 트랜잭션이면 그 사이에 다른 트랜잭션이 같은 페이지의 바이트를 쓰고 먼저 commit할 수 있다. 그 뒤 서버가 중단되면 삭제한 트랜잭션은 commit 로그가 없으므로 재시작 복구가 그 삭제를 되돌려야 하는데, 페이지에 레코드를 다시 넣을 바이트가 모자라다. 모델 검사가 이 실행 순서를 찾았고, 코드 읽기로 각 단계를 확인했다. 실행 중인 서버에서 재현하지는 않았다.

**영향**: 재시작 복구가 `logpb_fatal_error`로 멈추어 운영자가 DB를 열지 못할 수 있다. 같은 로그를 다시 적용하므로 재시작을 반복해도 같은 곳에서 멈출 것으로 추정한다(실행으로 확인하지 않음). 서버 중단이 짧은 구간 안에 일어나야 하고, REUSE_OID가 아닌 heap, 거의 찬 페이지, postpone이 없는 트랜잭션이 겹쳐야 하므로 드물 것으로 보지만 빈도는 측정하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

> 아래는 TLA+ 모델 검사 결과와 develop `e64a04a79a5842827a124b3f8313516d0da2594c`의 코드 읽기를 바탕으로 작성했다. 실행 중인 서버에서 재현하지 않았으며, 그 차이를 각 주장 옆에 적는다.

## Description

### saved space와 commit 순서

heap 페이지는 `SAFEGUARD_RVSPACE`로 초기화되어 saved space를 쓴다. 트랜잭션이 레코드를 지우면 [`spage_delete`](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/storage/slotted_page.c#L2117)가 [`spage_save_space`](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/storage/slotted_page.c#L488)로 그 바이트를 메모리 해시에 기록한다. 활성 트랜잭션의 INSERT는 [`spage_has_enough_total_space`](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/storage/slotted_page.c#L4610-L4638)에서 `total_free`에서 saved 바이트를 뺀 값만 쓸 수 있다. 따라서 삭제가 되돌려질 수 있는 동안에는 다른 트랜잭션이 그 바이트를 가져가지 못한다.

되돌리는 쪽은 이 예약을 보지 않는다. abort 중인 트랜잭션(`TRAN_UNACTIVE_ABORTED`)은 활성 상태가 아니므로 `total_free`만 본다. 재시작 복구에서는 [`spage_save_space`](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/storage/slotted_page.c#L500)가 아무것도 기록하지 않고 [`spage_get_saved_spaces`](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/storage/slotted_page.c#L718-L725)가 0을 돌려준다. 해시는 메모리에만 있으므로 서버가 중단되면 사라진다. 즉 undo가 들어갈 자리는 중단 전까지 예약이 지켜졌는지에만 달려 있다.

abort 경로는 순서가 맞다. [`log_abort_local`](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/transaction/log_manager.c#L5371-L5379)은 `log_rollback`을 마친 뒤 `spage_free_saved_spaces`를 부른다. commit 경로는 반대다. [`log_commit_local`](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/transaction/log_manager.c#L5265-L5309)은 `log_tran_do_postpone`, `spage_free_saved_spaces`(5278행), `log_append_repl_info_and_commit_log` 또는 `log_append_commit_log`(5296행, 5300행), `log_change_tran_as_completed`(flush) 순서로 실행한다.

postpone이 하나라도 있는 트랜잭션은 안전하다. [`log_tran_do_postpone`](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/transaction/log_manager.c#L8244-L8265)이 `log_append_commit_postpone`으로 `LOG_COMMIT_WITH_POSTPONE`을 기록하고 flush한 뒤에 saved space가 풀리기 때문이다. 재시작 복구는 그 트랜잭션을 commit된 것으로 끝낸다. postpone이 없으면 `log_tran_do_postpone`은 바로 반환하고, saved space가 풀린 시점에 디스크의 로그에는 그 트랜잭션의 commit 기록이 없다.

### 모델 검사가 찾은 실행 순서

TLA+ 모델(TLC 1.7.4)은 vacuum 작업 하나, 삭제 트랜잭션 U 하나, INSERT 트랜잭션 둘, 서버 중단 한 번과 재시작 복구의 모든 실행 순서를 탐색하고, U의 `RVHF_DELETE` undo가 페이지에 충분한 `total_free`를 찾는지 검사했다(`UserUndoFindsRoom`). develop `e64a04a79`에서 읽은 코드 모양으로 1861개 상태 안에서 다음 반례를 찾았다. 모델에서 saved space를 commit 로그 뒤에 풀도록 바꾸면 이 반례는 사라진다. 아래 단계의 이름과 행 번호는 코드에 맞춰 옮겼다.

1. U가 REUSE_OID가 아닌 heap(`FILE_HEAP`)에서 relocation된 행을 MVCC DELETE한다. delete MVCCID를 더한 레코드가 home 페이지에 들어가거나, home과 기존 forward 페이지 P 어디에도 들어가지 않거나, overflow 크기가 되면 [`heap_delete_relocation`](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/storage/heap_file.c#L23139-L23162)이 레코드를 새 자리로 옮기고 P의 옛 `REC_NEWHOME`을 지운다([heap_file.c:22851-22854](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/storage/heap_file.c#L22851-L22854), [22957-23018](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/storage/heap_file.c#L22957-L23018)). `log_append_undoredo_recdes (RVHF_DELETE)`를 기록하고, `heap_is_reusable_oid`가 false이므로 `RVHF_MARK_REUSABLE_SLOT` postpone은 기록하지 않는다. `heap_delete_physical`, `spage_delete`가 슬롯을 `REC_MARKDELETED`로 만들고 바이트를 U의 saved space로 기록한다.
2. U가 commit한다. `log_commit_local`에서 `log_tran_do_postpone`이 바로 반환하고, `spage_free_saved_spaces`가 P의 saved 바이트를 푼다. U의 commit 로그는 아직 없다.
3. INSERT 트랜잭션 T가 P를 고정한다. `spage_has_enough_total_space`가 더는 U의 바이트를 빼지 않으므로, T의 행이 다른 슬롯(더 낮은 빈 슬롯 또는 새 슬롯)과 그 바이트를 쓴다.
4. T가 commit하고, 로그가 T의 commit 기록까지 flush된다. U의 commit 기록은 그보다 뒤에 있다.
5. U의 commit 기록이 디스크에 닿기 전에 서버가 중단된다.
6. 재시작 복구의 redo가 T의 INSERT를 다시 적용한다. U는 commit 기록이 없으므로 loser이고, [`log_recovery_undo`](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/transaction/log_recovery.c#L4585)가 U의 `RVHF_DELETE`를 되돌린다. [`heap_rv_undo_delete`](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/storage/heap_file.c#L17908), [`heap_rv_redo_insert`](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/storage/heap_file.c#L17310-L17321)를 거쳐 `spage_insert_for_recovery`가 슬롯은 비어 있지만 `total_free`가 모자라 `SP_DOESNT_FIT`을 돌려준다. [`log_rv_undo_record`](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/transaction/log_recovery.c#L333-L343)가 `logpb_fatal_error`를 부른다.

모델의 범위는 페이지 두 개, 지운 레코드 2단위, INSERT 행 1 또는 2단위, 빈 공간 0에서 시작하는 페이지이다. 바이트는 추상 단위이고 `total_free`만 모델링한다. 그 밖의 경로와 다중 vacuum, HA 복제, 반복 중단은 모델에 없다.

### 코드에서 확인한 삭제 경로

| 경로 | 이번 결함에 노출되는가 | 근거 |
|---|---|---|
| MVCC `heap_delete_relocation`의 옛 forward 삭제, `FILE_HEAP` | 노출된다. 모델 반례의 경로이다 | [heap_file.c:23144-23154](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/storage/heap_file.c#L23144-L23154): postpone은 `heap_is_reusable_oid`일 때만 기록 |
| non-MVCC `heap_delete_home`, `FILE_HEAP` | 코드 모양은 같다. 모델링하지 않았다 | [heap_file.c:23549](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/storage/heap_file.c#L23549-L23551): `heap_log_delete_physical (..., is_reusable, ...)` |
| non-MVCC `heap_delete_bigone` | 노출되지 않는다. home 슬롯 삭제에는 postpone이 없지만, 이어지는 `heap_ovf_delete`가 overflow 페이지마다 `file_dealloc`의 `RVFL_DEALLOC` postpone을 기록한다 | [heap_file.c:22725-22738](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/storage/heap_file.c#L22725-L22738), [file_manager.c:6167](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/storage/file_manager.c#L6167) |
| non-MVCC `heap_delete_relocation`, `heap_update_relocation`의 forward 삭제 | 노출되지 않는다. `mark_reusable`이 항상 true여서 postpone이 있다 | [heap_file.c:23228](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/storage/heap_file.c#L23228-L23229), [heap_file.c:24107](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/storage/heap_file.c#L24107-L24108) |
| REUSE_OID heap(`FILE_HEAP_REUSE_SLOTS`)의 삭제 | 노출되지 않는다. `RVHF_MARK_REUSABLE_SLOT` postpone이 있다 | 위의 `heap_is_reusable_oid` 분기 |

`create_table_reuseoid`의 기본값은 yes이므로 기본 설정으로 만든 사용자 테이블은 `FILE_HEAP_REUSE_SLOTS`를 쓴다. 노출되는 것은 `DONT_REUSE_OID`로 만들었거나 이 파라미터를 끈 상태로 만든 테이블이다. SERVER_MODE의 non-MVCC 삭제는 [`mvcc_is_mvcc_disabled_class`](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/transaction/mvcc.c#L686-L711)인 root class, serial, collation, HA apply info 클래스에만 쓰인다. 어느 경로든 트랜잭션 전체에 다른 postpone이 하나라도 있으면 노출되지 않는다.

### 발생 조건과 미확인 사항

T의 INSERT와 commit 기록은 U의 `spage_free_saved_spaces`와 U의 commit 기록 사이에 들어가야 하고, 서버 중단은 T의 commit 기록이 디스크에 닿은 뒤 U의 commit 기록이 닿기 전이어야 한다. local 트랜잭션에서 이 사이의 코드는 `log_cleanup_modified_class_list`뿐이라 구간이 짧다. 그 구간에 checkpoint가 U를 `TRAN_UNACTIVE_WILL_COMMIT`으로 기록했다면, 재시작 분석이 그 상태와 비어 있는 `undo_nxlsa`를 이어받으므로([log_recovery.c:1957-1967](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/transaction/log_recovery.c#L1957-L1967)) 이 undo는 일어나지 않을 것으로 본다(코드 읽기, 미확인). 또한 P에 남은 빈 공간이 T의 행을 넣은 뒤 U의 레코드보다 작아야 한다.

ANALYSIS에서 확인할 사항은 다음과 같다.

1. **서버 재현**: `spage_free_saved_spaces`와 commit 기록 사이에 fault injection 지점(예: `FI_TEST`)이나 debug 전용 대기를 넣고, 위 1-6단계를 실제 서버에서 재현할 수 있는가. 아래 순서는 실행하지 않은 제안이다.
   1. `DONT_REUSE_OID` 테이블에서 행을 UPDATE로 키워 relocation시킨다. DELETE 때 레코드가 P를 떠나도록 home 페이지에 공간을 두거나 P를 delete MVCCID가 들어갈 자리가 없을 만큼 채운다. P에는 T의 행이 U의 바이트를 써야만 들어갈 정도의 빈 공간만 남긴다.
   2. 세션 U가 그 행을 DELETE하고 COMMIT하며, 계측 지점에서 멈춘다.
   3. 세션 T가 P에 들어갈 크기의 행을 INSERT하고 COMMIT한다.
   4. U가 멈춰 있는 동안 `cub_server`를 강제 종료(`kill -9`)하고 다시 시작한다. 재시작 복구가 `log_rv_undo_record`의 `logpb_fatal_error`로 멈추는지, 다시 시작해도 같은 곳에서 멈추는지 확인한다.
2. **2PC/XA**: `is_local_tran`이 false인 경로(`log_2pc.c`)는 commit 기록을 `log_complete_for_2pc`로 미룬다. 이 경우 구간이 얼마나 길어지는가.
3. **non-MVCC `heap_delete_home`**: serial 등 MVCC가 꺼진 클래스의 heap이 `FILE_HEAP`인지, 그 삭제를 포함한 트랜잭션이 실제로 postpone 없이 commit할 수 있는지.
4. **영향받는 버전**: 이 코드 순서가 언제부터 있었는지, 출시 버전의 어느 범위가 같은 순서인지. 이 이슈는 develop `e64a04a79`의 소스만 확인했다.

같은 모델에서 이 원인을 없애도 `UserUndoFindsRoom`에는 다른 반례가 하나 남는다. vacuum이 `REC_RELOCATION`을 정리할 때 sysop이 끝나기 전에 forward 페이지를 놓는 문제로, 원인과 수정 위치가 달라 별도 이슈로 다룬다. 두 원인을 모두 없앤 모델은 같은 범위에서 통과했다.
