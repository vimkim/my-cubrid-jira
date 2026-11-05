# [OOS] vacuum forward walk가 OOS 파일 조회 실패를 삼켜 UPDATE 이전 OOS 값을 남긴다

**한 줄 요약**: CBRD-27933 수정을 프로토타이핑하며 소스에서 찾은 같은 유형의 결함으로, vacuum forward walk가 OOS 파일(VFID) 조회 실패를 지우고 로그 블록을 완료 처리해 UPDATE로 대체된 이전 OOS 값이 영구히 남을 수 있는 문제를 별도로 추적한다.

## Issue Triage

**이슈 수행 목적**: forward walk에서 OOS 파일 조회가 일시적으로 실패해도, 그 로그 레코드가 가리키는 이전 OOS 값을 이후 vacuum 실행에서 회수할 수 있게 한다.

**이슈 수행 이유**: `vacuum_forward_walk_reclaim_oos` 는 `vacuum_oos_vfid_lookup` 이 오류를 반환하면 로그를 남기고 `er_clear()` 로 오류를 지운 뒤 다음 로그 레코드로 넘어간다. 블록은 완료로 기록되어 다시 처리되지 않는다. 고정 소스의 호출 관계에서, MVCC UPDATE가 남긴 이전 OOS 값을 회수하는 경로는 이 forward walk뿐이다.

**영향**: 조회가 실패한 로그 레코드마다 그 이전 이미지가 참조하던 OOS chain이 OOS 파일에 남는다. 테이블 삭제로 OOS 파일 자체가 제거되기 전까지 그 공간은 회수되지 않는다(소스 추론). 런타임 재현은 하지 않았다. 발생 빈도와 누수량도 측정하지 않았다.

**이슈 수행 방안**: 미팅에서 승인된 commit 후 postpone 알림(A')과 forward-walk 제거에 연계해 처리한다. 원인이 되는 경로의 실제 제거 범위를 확인하고, 대체 알림 소비·회수 경로에서도 조회 실패를 정상 완료로 삼켜 영구 누수를 남기지 않는지 검증한다. 구현·검증 전에는 해결 완료로 처리하지 않는다.

---

## Meeting Decision (2026-11-05)

2026-11-05 공유된 미팅 결과로 [CBRD-27237](https://jira.cubrid.org/browse/CBRD-27237)의 UPDATE 알림은 commit 후 postpone(A')으로 진행하며, undo image 기반 `vacuum_forward_walk_reclaim_oos`는 제거한다. 실제 chain 회수는 [CBRD-27781](https://jira.cubrid.org/browse/CBRD-27781)의 확정 뒤 redo-only 회수와 연결한다.

본 이슈의 오류 무시 분기도 제거 대상 경로에 있으므로, 우선 같은 구현에서 남은 호출자와 대체 소비·회수 경로를 대조한다. 새 경로는 조회·회수 실패 후 지속 재시도와 진단을 갖춰야 한다. 아래 현행 소스의 조사와 별개로, 경로 제거·오류 후 회수·재실행 안전성을 실제 검증한 뒤 처리 범위를 정리한다. 설계 결정만으로 이슈를 해결 완료나 중복으로 종료하지 않는다.

## AI-Generated Context

## Description

OOS는 큰 컬럼 값을 heap 행 밖의 전용 파일에 저장하는 방식이다. heap 행에는 그 값의 참조(OOS OID와 identity stamp)가 남는다. MVCC UPDATE는 새 OOS 값을 새 OID에 쓰고, 현재 슬롯은 새 참조만 가진다. 이전 OOS 값의 참조는 로그 레코드의 undo 이미지에만 남는다. 해당 로그 레코드는 `RVHF_UPDATE_NOTIFY_VACUUM` 이다. relocation된 행의 이전 forward 레코드를 지우는 경우에는 `RVHF_DELETE_NEWHOME_NOTIFY_VACUUM` 이다.

vacuum은 로그 블록을 처리하면서 이 두 로그 레코드의 undo 이미지를 읽는다. 이 처리를 forward walk라고 부른다. forward walk는 이미지가 참조하는 OOS chain을 지운다. 이를 위해 먼저 heap 파일에 연결된 OOS 파일의 VFID를 `vacuum_oos_vfid_lookup` 으로 조회한다. [두 호출 지점: UPDATE](https://github.com/CUBRID/cubrid/blob/d52b1889e907abcf84190ec504dde3bc93de260d/src/query/vacuum.c#L3677-L3694), [relocation 이전 forward 삭제](https://github.com/CUBRID/cubrid/blob/d52b1889e907abcf84190ec504dde3bc93de260d/src/query/vacuum.c#L3827-L3838)

조회 결과가 `VACUUM_OOS_VFID_ERROR` 이면 `vacuum_forward_walk_reclaim_oos` 는 `transient OOS vfid lookup failure; leaving OOS unreclaimed (bounded leak)` 로그를 남긴다. 이어 `er_clear()` 를 호출하고 `NO_ERROR` 를 반환한다. 코드 주석은 `DO NOT propagate; the block must complete.` 이다. [오류 분기](https://github.com/CUBRID/cubrid/blob/d52b1889e907abcf84190ec504dde3bc93de260d/src/query/vacuum_oos.cpp#L320-L330)

호출자 `vacuum_process_log_block` 은 다음 로그 레코드를 계속 처리한다. 블록 끝에 도달하면 `vacuum_complete = true` 로 블록을 완료 처리한다. 완료된 블록은 vacuum master가 목록에서 제거하므로, 같은 로그 레코드를 다시 처리할 기회가 없다. [블록 완료](https://github.com/CUBRID/cubrid/blob/d52b1889e907abcf84190ec504dde3bc93de260d/src/query/vacuum.c#L3869-L3880), [완료와 중단의 기록](https://github.com/CUBRID/cubrid/blob/d52b1889e907abcf84190ec504dde3bc93de260d/src/query/vacuum.c#L4009-L4061)

로그 메시지는 이 누수를 "bounded leak"이라고 부른다. 누수 단위가 실패한 로그 레코드 하나라는 점에서는 맞다. 그러나 다시 회수할 경로가 없으므로, 남은 OOS 값은 일시적인 지연이 아니라 영구 누수다.

### 조회가 실패하는 경우

`vacuum_oos_vfid_lookup` 은 다음 경우에 `VACUUM_OOS_VFID_ERROR` 를 반환한다. [조회 함수](https://github.com/CUBRID/cubrid/blob/d52b1889e907abcf84190ec504dde3bc93de260d/src/query/vacuum_oos.cpp#L62-L133)

- `file_descriptor_get` 이 heap 파일의 파일 헤더를 읽지 못한 경우.
- 파일 헤더의 HFID가 NULL인 경우.
- `heap_oos_find_vfid` 가 heap 헤더 페이지를 읽지 못하고 오류를 남긴 경우. 이 조회는 무조건 latch(`PGBUF_UNCONDITIONAL_LATCH`)로 헤더 페이지를 fix한다. 따라서 latch 대기 시간 초과, 인터럽트, I/O 오류, 헤더 레코드 읽기 실패가 이 경우에 해당한다. [헤더 페이지 fix](https://github.com/CUBRID/cubrid/blob/d52b1889e907abcf84190ec504dde3bc93de260d/src/storage/heap_file.c#L13258-L13272), [무조건 latch](https://github.com/CUBRID/cubrid/blob/d52b1889e907abcf84190ec504dde3bc93de260d/src/storage/heap_file.c#L13350-L13353)

블록 단위 memo(`VACUUM_OOS_VFID_MEMO`)는 성공한 조회 결과만 저장하고 실패는 저장하지 않는다. 그래서 다음 로그 레코드는 조회를 처음부터 다시 시도하고, 누수는 실패한 레코드에만 생긴다. [memo 정의](https://github.com/CUBRID/cubrid/blob/d52b1889e907abcf84190ec504dde3bc93de260d/src/query/vacuum_oos.hpp#L41-L55)

오류 분기는 오류 코드를 구분하지 않는다. 조회 중 `ER_INTERRUPTED` 가 생겨도 지우고 계속 진행한다. 반면 같은 함수의 OOS 삭제 실패 분기는 `ER_INTERRUPTED` 를 호출자에게 전달한다.

### forward walk가 유일한 회수 경로인지

고정 소스에서 `oos_delete` 를 호출하는 곳은 세 곳이다. 이 결론은 정적 호출 관계에 근거하며, 런타임으로 확인하지 않았다.

| 호출 경로 | 지우는 대상 | MVCC UPDATE의 이전 OOS 값 |
|---|---|---|
| `vacuum_forward_walk_oos_delete_atomic` (forward walk) | 로그 undo 이미지가 참조하는 chain | 회수한다 |
| `vacuum_heap_oos_delete_within_sysop` (heap 레코드 vacuum) | 제거하는 슬롯의 현재 레코드가 참조하는 chain | 슬롯이 이전 참조를 갖지 않으므로 보지 못한다 |
| `heap_oos_delete_unreferenced` (DML의 즉시 삭제) | 이전 레코드에만 있던 chain | `!is_mvcc_op` 일 때만 실행되므로 해당 없다 |

근거: [forward walk 삭제와 재실행 주석](https://github.com/CUBRID/cubrid/blob/d52b1889e907abcf84190ec504dde3bc93de260d/src/query/vacuum_oos.cpp#L135-L212), [heap 레코드 vacuum의 삭제](https://github.com/CUBRID/cubrid/blob/d52b1889e907abcf84190ec504dde3bc93de260d/src/query/vacuum_oos.cpp#L429-L486), [즉시 삭제의 범위](https://github.com/CUBRID/cubrid/blob/d52b1889e907abcf84190ec504dde3bc93de260d/src/storage/heap_oos.cpp#L908-L925), [UPDATE home의 !is_mvcc_op 조건](https://github.com/CUBRID/cubrid/blob/d52b1889e907abcf84190ec504dde3bc93de260d/src/storage/heap_file.c#L25241-L25250), [UPDATE relocation의 !is_mvcc_op 조건](https://github.com/CUBRID/cubrid/blob/d52b1889e907abcf84190ec504dde3bc93de260d/src/storage/heap_file.c#L24752-L24765)

`vacuum.c` 의 UPDATE 호출 지점 주석도 "Reading the undo image is the only way left to free them."라고 적는다. 따라서 forward walk가 조회 실패를 삼키면 해당 OOS 값은 영구 누수가 된다. 이 결론은 소스로 확인했다. 실제 잔존 chain은 측정하지 않았다.

### 같은 함수의 다른 누수 분기

`vacuum_forward_walk_reclaim_oos` 에는 OOS 값을 회수하지 않고 블록을 계속 진행하는 분기가 두 개 더 있다. ANALYSIS에서 이 이슈의 범위에 포함할지 정한다.

| 분기 | 처리 | 참고 |
|---|---|---|
| undo 이미지 복사용 `db_private_alloc` 실패 | 로그, `er_clear()`, `NO_ERROR` 반환 | `ER_OUT_OF_VIRTUAL_MEMORY` 는 `vacuum_finished_block_vacuum` 이 이미 블록 중단 사유로 받아들인다. [분기](https://github.com/CUBRID/cubrid/blob/d52b1889e907abcf84190ec504dde3bc93de260d/src/query/vacuum_oos.cpp#L306-L316) |
| 참조 목록 추출 또는 OOS 삭제 실패(`ER_INTERRUPTED` 제외) | sysop을 abort하고 로그, `er_clear()`. 두 번째 `DO NOT propagate` 주석 | 그 레코드의 모든 이전 OOS 값이 남는다. 손상 오류와 일시적 I/O 오류를 구분하지 않는다. [분기](https://github.com/CUBRID/cubrid/blob/d52b1889e907abcf84190ec504dde3bc93de260d/src/query/vacuum_oos.cpp#L331-L359) |

조회가 `VACUUM_OOS_VFID_NONE` 을 반환하는 경우는 다르다. undo 이미지에는 OOS 플래그가 있는데 heap에 OOS 파일이 없는 상태로, 일시적 실패가 아니라 손상 신호다. 이 분기는 `assert_release (false)` 로 보고한다. [분기](https://github.com/CUBRID/cubrid/blob/d52b1889e907abcf84190ec504dde3bc93de260d/src/query/vacuum_oos.cpp#L360-L367)

## Relation to CBRD-27933

CBRD-27933은 같은 유형의 결함을 heap 레코드 삭제 경로에서 다룬다. 대상 함수는 `vacuum_oos_find_vfid_for_heap_record` 다. 요구 출처는 [PR #8350 리뷰 댓글](https://github.com/CUBRID/cubrid/pull/8350#discussion_r4452180248)이다. 분석은 [CBRD-27933 재현 분석](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27933/repro-analysis.md)에 있다. 그 이슈에서 고른 방향은 오류를 반환하고 로그 블록을 중단(interrupted) 상태로 남겨 나중에 다시 처리하는 것이다. 이 방향은 로컬 POC로만 구현했고 아직 병합하지 않았다.

이 이슈의 결함은 그 POC를 작성하며 소스를 읽다가 발견했다. 같은 방향을 forward walk에 적용할 수 있는지는 따로 판단해야 한다. heap 레코드 vacuum은 블록 끝의 `vacuum_heap` 에서 일어나지만, forward walk는 로그 레코드를 하나씩 처리하는 도중에 일어난다. 따라서 블록을 다시 실행하면 같은 블록의 앞선 레코드에 대한 처리가 반복된다.

## Expected Result

- 일시적인 OOS 파일 조회 실패 뒤에도, 해당 로그 레코드가 참조하던 이전 OOS chain이 이후 vacuum 실행에서 회수된다.
- 재처리는 이미 회수된 chain이나, 회수된 슬롯을 재사용한 다른 chain을 지우지 않는다.
- 계속 실패하는 오류가 vacuum 진행을 무한히 막지 않는다. 회수를 포기하는 경우에는 그 사실이 운영자가 볼 수 있는 형태로 남는다.

## Analysis Questions

다음은 기존 forward-walk를 유지할 때의 조사 질문이다. 승인된 제거 구현에서는 해당 분기가 실제로 없어지는지 확인하고, 대체 알림 소비·회수 경로에 필요한 재시도 안전성·진행성·오류 분류 검증으로 이어간다.

1. **재실행 안전성.** 오류를 전달해 블록을 중단 상태로 남기면, vacuum은 블록을 처음부터 다시 실행한다. 앞선 레코드의 forward walk 삭제는 레코드별 sysop으로 이미 commit되어 있다. 같은 chain에 대한 반복 삭제는 소스상 감지되고 무해하다. `oos_delete` 는 head chunk를 write latch로 잡은 상태에서 identity stamp를 비교한다. 페이지가 해제되었거나, 슬롯이 비었거나, stamp가 다르면 아무것도 바꾸지 않고 `NO_ERROR` 를 반환한다(CBRD-26950). forward walk 삭제 함수의 주석도 블록 재실행을 전제한다. [oos_delete 계약](https://github.com/CUBRID/cubrid/blob/d52b1889e907abcf84190ec504dde3bc93de260d/src/storage/oos_file.cpp#L3456-L3519) 남은 확인 사항은 두 가지다.
   - `oos_delete` 주석은 stamp 구분이 로깅을 켠 상태로 쓴 chain에서만 성립한다고 적는다. forward walk가 만나는 chain 중 로깅 없이 쓴 chain이 있을 수 있는가?
   - 같은 블록의 B-tree vacuum과 LOB 파일 삭제의 반복이 안전한가? 기존 종료 인터럽트도 블록을 다시 실행하므로 안전하다고 추론하지만, 확인하지 않았다.
2. **재시도 비용과 진행성.** 중단된 블록은 vacuum master가 다시 배정한다. `vacuum_master_interval_in_msecs` 의 기본값은 10ms다. [파라미터 기본값](https://github.com/CUBRID/cubrid/blob/d52b1889e907abcf84190ec504dde3bc93de260d/src/base/system_parameter.c#L3824-L3830) CBRD-27933 POC에서는 바로 실패하는 조회 때문에 debug 빌드에서 master가 같은 블록을 초당 약 51번 다시 실행했다. 이 값은 POC 관찰값이며, 이 이슈 작성 중 다시 측정하지 않았다. 계속 실패하는 오류라면 재시도가 끝나지 않는다.
3. **중단 사유 허용.** `vacuum_finished_block_vacuum` 은 debug 빌드에서 종료와 메모리 부족만 블록 중단 사유로 허용한다. 오류를 전달하는 수정은 이 검사를 넓혀야 한다. CBRD-27933 POC도 그렇게 했다.
4. **오류 분류.** 다시 시도할 가치가 있는 일시적 오류(latch 대기 시간 초과, I/O 오류)와 다시 시도해도 해결되지 않는 오류(헤더 손상)를 어떻게 나눌 것인가? 조회 중 `ER_INTERRUPTED` 는 지우지 않고 전달해야 하는가?
5. **범위.** 위의 다른 누수 분기를 이 이슈에서 함께 다룰 것인가?

## Evidence

- 소스 기준은 `feature/oos-merge` 의 `d52b1889e907abcf84190ec504dde3bc93de260d` 다. 위 링크는 모두 이 커밋을 가리킨다.
- 소스 읽기로 발견했다. 장애 주입이나 런타임 재현은 실행하지 않았다.
- 재현 후보(미실행): OOS 컬럼이 있는 테이블에 MVCC UPDATE를 실행한다. 그 블록의 forward walk에서 `vacuum_oos_vfid_lookup` 이 실패하도록 장애를 주입한다. 블록 완료 뒤 이전 OOS chain이 OOS 파일에 남는지 확인한다. CBRD-27933 POC의 장애 주입 지점은 heap 레코드 경로의 대기 조회에 있으므로, forward walk용 주입 지점이 따로 필요하다.
