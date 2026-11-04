# [Vacuum] relocation 행 vacuum이 sysop을 끝내기 전에 forward 페이지를 놓아, 서버 중단 뒤 재시작 복구가 commit된 행을 덮어쓸 수 있다

**한 줄 요약**: [CBRD-27858](https://jira.cubrid.org/browse/CBRD-27858)의 수정 [PR #8348](https://github.com/CUBRID/cubrid/pull/8348)이 `feature/oos-merge` 만 대상으로 하므로 vacuum의 forward 페이지 조기 해제 구간이 `develop` 에 남아 있어, 그 구간에서 서버가 중단되면 재시작 복구가 다른 트랜잭션이 commit한 행을 덮어쓰거나 FATAL로 멈출 수 있음을 추적한다.

## Issue Triage

**이슈 수행 목적**: relocation 행을 지우는 vacuum 작업 도중 서버가 중단되더라도, 재시작 복구가 다른 트랜잭션이 commit한 행을 보존하고 DB를 정상적으로 연다.

**이슈 수행 이유**: `develop` 의 `vacuum_heap_record` 는 `REC_RELOCATION` 행을 지울 때 forward 슬롯을 재사용 가능한 빈 슬롯으로 만들고, 그 페이지의 래치를 놓은 다음에 내부 작업(sysop)을 commit한다. 그 사이에 다른 트랜잭션이 이 슬롯이나 빈 공간을 쓰고 commit한 뒤 서버가 중단되면, 재시작 복구는 끝나지 않은 vacuum sysop을 되돌리면서 옛 레코드를 같은 슬롯에 다시 넣는다. 같은 구간은 CBRD-27858에서 OOS 삭제 실패 경로로 재현됐지만, 그 수정 PR #8348(2026-11-04 기준 open)은 `feature/oos-merge` 만 대상으로 한다. 이 이슈의 근거는 TLA+ 모델 검사와 소스 읽기이며, 실행 중인 서버에서 재현하지 않았다.

**영향**: 발생하면 vacuum과 무관한 트랜잭션이 commit한 행이 손상되거나, 재시작 복구가 FATAL로 멈춰 DB를 열지 못할 수 있다(소스에서 추론, 실행 미확인). 서버 중단이 매우 짧은 구간과 겹쳐야 하므로 드물 것으로 보지만, 실제 빈도는 측정하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

### 무엇이 문제인가

행이 커져 원래 페이지에 들어가지 않으면 CUBRID는 행을 다른 페이지로 옮긴다. 원래 자리(home)에는 새 위치를 가리키는 `REC_RELOCATION` 레코드가, 옮겨간 자리(forward)에는 실제 데이터인 `REC_NEWHOME` 레코드가 있다. 이 행이 DELETE된 뒤 vacuum은 두 슬롯을 하나의 sysop 안에서 지운다. sysop이 끝나기 전에 서버가 중단되면, 재시작 복구는 끝나지 않은 sysop을 되돌린다. 이 undo는 지운 레코드를 **원래 슬롯 번호에 다시 넣는다**. 따라서 sysop이 끝날 때까지 다른 트랜잭션이 그 슬롯과 그 레코드가 차지하던 바이트를 쓰면 안 된다.

소스 기준은 `develop` 의 `e64a04a79a5842827a124b3f8313516d0da2594c` 이다. 2026-11-04 `develop` 끝(`2ca10ed0373e5544c7becc3d7d1fc7130c15c97b`)의 `src/query/vacuum.c` 에도 같은 줄에 같은 코드가 있다. [`vacuum_heap_record` 의 `REC_RELOCATION` 처리](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/query/vacuum.c#L2382-L2447)는 다음 순서로 실행된다.

1. `log_sysop_start` 로 sysop을 시작하고, home 슬롯을 비운 뒤 `RVVAC_HEAP_RECORD_VACUUM` 을 기록한다. home 페이지는 sysop이 끝난 뒤까지 고정된다.
2. `spage_vacuum_slot (thread_p, helper->forward_page, helper->forward_oid.slotid, true)` 가 forward 슬롯을 `REC_DELETED_WILL_REUSE` 로 만들고 그 바이트를 page의 `total_free` 에 돌려준다. 이 바이트는 saved space로 예약되지 않는다. 이어 `heap_add_bestpage` 가 이 페이지를 INSERT 후보로 등록하고, forward 페이지의 `RVVAC_HEAP_RECORD_VACUUM` 을 기록한다.
3. `pgbuf_set_dirty (thread_p, helper->forward_page, FREE)` 가 forward 페이지의 래치를 놓는다.
4. `log_sysop_commit` 이 `LOG_SYSOP_END` 를 로그 버퍼에 추가한다. 이 호출은 로그를 flush하지 않는다.

3과 4 사이에 다른 트랜잭션이 forward 페이지를 잡을 수 있다. 그 트랜잭션은 비워진 슬롯을 받거나, 다른 슬롯을 받더라도 vacuum이 돌려준 바이트를 쓸 수 있다. 그 트랜잭션의 commit은 자기 commit 레코드까지 로그를 flush하므로, vacuum의 앞선 `RVVAC_HEAP_RECORD_VACUUM` 레코드는 디스크에 남지만 그 뒤에 추가될 `LOG_SYSOP_END` 는 남지 않는다. 이 상태에서 서버가 중단되면 재시작 복구가 vacuum sysop을 되돌린다. undo 경로는 [`vacuum_rv_undo_vacuum_heap_record`](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/query/vacuum.c#L7563-L7568) → [`heap_rv_redo_insert`](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/storage/heap_file.c#L17286-L17325) → `spage_insert_for_recovery` 이다. 결과는 다른 트랜잭션이 무엇을 가져갔는지에 따라 갈린다(소스에서 추론).

- **슬롯을 가져간 경우**: `spage_insert_for_recovery` 는 [슬롯이 비어 있다고 가정](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/storage/slotted_page.c#L1964-L1972)한다. debug 빌드는 이 assertion에서 멈춘다. release 빌드는 슬롯을 다시 할당해 옛 `REC_NEWHOME` 을 쓰므로, commit된 행의 레코드가 슬롯에서 떨어진다.
- **바이트만 가져간 경우**: 슬롯은 비어 있지만 옛 레코드가 들어갈 공간이 없어 `SP_DOESNT_FIT` 가 된다. `heap_rv_redo_insert` 가 오류를 돌려주고, [`log_rv_undo_record`](https://github.com/CUBRID/cubrid/blob/e64a04a79a5842827a124b3f8313516d0da2594c/src/transaction/log_recovery.c#L318-L344)가 `logpb_fatal_error` 를 호출한다. 다음 재시작도 같은 undo를 다시 실행하므로 DB를 열지 못할 것으로 본다(추론).

같은 함수의 다른 경로는 이 구간이 없다. home 페이지는 `DONT_FREE` 로 sysop이 끝난 뒤까지 고정되고, `REC_BIGONE` 도 home 페이지를 고정한 채 sysop을 끝낸다. `develop` 에는 3과 4 사이에 실패할 수 있는 처리가 없으므로, 이 결함은 서버 중단 경로로만 나타난다. CBRD-27858은 `feature/oos-merge` 가 이 사이에 OOS 삭제를 넣어 abort 경로가 생기고 구간이 길어진 경우를 다루며, 그 이슈 본문도 `develop` 의 짧은 구간은 실행으로 확인하지 않았다고 기록한다.

### 모델이 찾은 반례

TLA+로 위의 각 단계를 하나의 원자적 동작으로 모델링하고, 모델 검사기 TLC로 vacuum, INSERT 트랜잭션 두 개, 사용자 DELETE 트랜잭션 하나, 임의 시점의 서버 중단이 만드는 모든 실행 순서를 탐색했다. 검사한 성질은 "abort나 재시작 복구가 `spage_insert_for_recovery` 로 레코드를 되돌릴 때 그 슬롯이 비어 있고 페이지에 충분한 빈 바이트가 있다"이다. 모델의 단계와 반례는 `e64a04a79` 의 소스로 다시 따라가 확인했다. 아래는 가장 짧은 반례이다.

1. vacuum: `vacuum_heap_page` 가 home 페이지를, `vacuum_heap_prepare_record` 가 forward 페이지를 고정한다(`REC_RELOCATION`).
2. vacuum: `vacuum_heap_page_log_and_reset` 다음 `log_sysop_start`.
3. vacuum: home 페이지에서 `spage_vacuum_slot`, `RVVAC_HEAP_RECORD_VACUUM` 기록.
4. vacuum: forward 페이지에서 `spage_vacuum_slot (..., true)`, `heap_add_bestpage`, `RVVAC_HEAP_RECORD_VACUUM` 기록, `pgbuf_set_dirty (forward_page, FREE)`.
5. INSERT t1: forward 페이지를 잡고, `spage_find_free_slot` 이 vacuum이 비운 forward 슬롯을 준다. 행이 그 페이지의 빈 바이트를 쓴다.
6. INSERT t1: commit한다. 로그가 t1의 commit 레코드까지 flush된다.
7. 서버가 중단된다. vacuum의 `LOG_SYSOP_END` 는 디스크에 없다.
8. 재시작 복구: forward 페이지의 `RVVAC_HEAP_RECORD_VACUUM` 을 되돌리며 `spage_insert_for_recovery` 가 t1의 행이 있는 슬롯을 만난다.

같은 구간에서 두 가지 변형도 나왔다.

- 5에서 t1이 다른 슬롯(더 낮은 빈 슬롯이나 새 슬롯)을 받고 vacuum이 돌려준 바이트를 쓰면, 8에서 슬롯은 비어 있지만 공간이 모자라 `SP_DOESNT_FIT` 이 된다. forward 슬롯을 `REC_MARKDELETED` 로 남겨 슬롯만 막는 방식은 이 변형을 막지 못했다.
- 1 이전에 commit하지 않은 사용자 트랜잭션 U가 같은 forward 페이지의 다른 `REC_NEWHOME` 을 지웠다면, `spage_delete` 가 그 바이트를 saved space로 예약한다. 재시작 복구는 saved space를 무시하므로, LSA가 더 큰 vacuum의 undo가 U의 바이트를 써서 들어간다. 이어 U의 `RVHF_DELETE` undo가 공간이 모자라 실패한다.

모델에서 forward 페이지를 `log_sysop_commit` 뒤까지 고정하도록 바꾸면 세 반례가 모두 사라졌다. 이는 PR #8348이 `feature/oos-merge` 에서 택한 순서와 같다. 다만 이것은 ANALYSIS의 참고 자료이며, `develop` 의 해결 방안으로 정한 것이 아니다.

### 왜 문제인가

사용자는 commit한 행이 다른 작업이나 서버 재시작 때문에 손상되지 않기를 기대하고, 운영자는 서버가 중단되어도 재시작 복구로 DB를 다시 열 수 있기를 기대한다. 이 결함에서는 사용자가 지운 행을 vacuum이 정리하는 과정이, 그와 무관한 트랜잭션이 commit한 행을 덮어쓰거나 복구 자체를 멈춘다. 피해 트랜잭션은 vacuum과 관계가 없고, vacuum 실행 시점과 INSERT 위치, 서버 중단 시점은 사용자가 제어할 수 없으므로 우회책이 없다.

발생 조건은 좁다. 지운 행이 relocation 상태여야 하고, vacuum 스레드가 `pgbuf_set_dirty (..., FREE)` 와 `log_sysop_commit` 사이에서 멈춘 동안 다른 트랜잭션이 그 페이지에 INSERT하고 commit해야 한다. 그리고 vacuum의 `LOG_SYSOP_END` 가 디스크에 쓰이기 전에 서버가 중단되어야 한다. `heap_add_bestpage` 가 이 페이지를 INSERT 후보로 알리므로 INSERT가 이 페이지로 올 가능성은 있다. 실제 빈도는 측정하지 않았다.

## Test Build

- 소스 읽기와 모델 검사의 기준은 `develop` `e64a04a79a5842827a124b3f8313516d0da2594c` 이다. 모델 검사 결과는 TLC 1.7.4로 얻었다.
- 실행 중인 서버에서 재현하지 않았다. 따라서 debug assertion, release의 행 손상, `logpb_fatal_error` 는 소스와 모델에서 추론한 결과이며 관측한 결과가 아니다.
- `release/11.4` 의 `src/query/vacuum.c` 에도 forward 페이지를 놓은 뒤 `log_sysop_commit` 하는 순서가 있다. 실행으로 확인하지 않았으므로 출시 버전이 영향을 받는다고 주장하지 않는다.

## Expected Result

- 끝나지 않은 vacuum sysop을 재시작 복구가 되돌릴 때, forward 슬롯이 비어 있고 옛 레코드가 들어갈 공간이 있다.
- vacuum 작업 도중 서버가 중단되어도, 다른 트랜잭션이 commit한 행은 보존되고 재시작 복구가 끝나 DB가 열린다.

## Actual Result

소스와 모델 검사에 따르면, 위 구간에서 서버가 중단되면 재시작 복구의 undo가 다른 트랜잭션이 commit한 행이 있는 슬롯에 옛 레코드를 쓰거나(debug는 assertion, release는 행 손상), 공간이 모자라 `logpb_fatal_error` 로 멈춘다.

## ANALYSIS 확인 사항

- **서버 재현**: `pgbuf_set_dirty (thread_p, helper->forward_page, FREE)` 와 `log_sysop_commit` 사이에 재현 전용 fault-injection 지점을 넣어 vacuum을 멈추고, 그동안 같은 forward 페이지에 INSERT를 commit한 뒤 서버를 `kill -9` 로 중단하여 재시작 결과를 debug·release에서 확인할 수 있는가. CBRD-27858의 재현 계측과 드라이버는 `feature/oos-merge` 코드 기준이므로, `develop` 에 맞게 옮길 수 있는지도 확인한다. 슬롯 경로와 바이트 경로를 따로 확인한다.
- **수정 경로**: `develop` 에 따로 수정을 넣을지, 아니면 PR #8348이 반영된 `feature/oos-merge` 가 `develop` 에 병합되는 것으로 충분한지 결정한다. 후자라면 병합 전까지 `develop` 에 남는 기간을 받아들일 수 있는지도 판단한다.
- **영향 버전**: `release/11.4` 등 출시 브랜치가 같은 순서를 가지는지, backport가 필요한지 확인한다.
- **모델 범위 밖**: 모델은 heap 페이지 두 개, 제거할 레코드 하나, 작은 INSERT 크기로 제한했다. 여러 vacuum worker, HA 복제, 반복 중단, 레코드 UPDATE의 undo는 포함하지 않았다. 필요하면 수정 검증에서 다룬다.
