# [OOS] [TODO] OOS 읽기의 head page sector 할당 확인을 없애거나 더 싼 감지로 바꿀 수 있는지 판단한다

**한 줄 요약**: [PR #8491 리뷰](https://github.com/CUBRID/cubrid/pull/8491#pullrequestreview-5914646248)에서 OOS 값을 읽을 때 head page의 sector 할당 확인이 OOS fetch의 절반을 차지한다는 측정 지적이 나왔다. [답변](https://github.com/CUBRID/cubrid/pull/8491#issuecomment-6969231100)에서 약속한 대로, CBRD-27237(PR #8434)과 CBRD-27579(PR #8182)가 반영된 뒤 이 확인을 없앨 수 있는지, 또는 더 싼 file 파괴 감지로 바꿀 수 있는지 판단하는 후속 이슈다.

## Issue Triage

**이슈 수행 목적**: OOS 값 읽기마다 실행되는 head page의 sector 할당 확인을 유지할지, 없앨지, file 파괴를 더 싸게 감지하는 방법으로 바꿀지 근거와 함께 결정한다. 없애거나 바꾸면 OOS 읽기의 page fix 수가 줄어든다.

**이슈 수행 이유**: OOS 값을 읽을 때 head page를 fix하면서 그 page의 sector가 아직 예약되어 있는지 확인한다. 이 확인은 volume header page와 sector table page를 한 번씩 더 fix한다. 리뷰어가 release 빌드에서 20,000바이트 값 200행을 읽었을 때 OOS fetch 800 중 400이 이 확인이었고, 같은 수치를 재현했다. 그러나 지금은 scan이 visible로 판정한 행의 OOS 참조가 해제된 page를 가리키는 정상 SQL 경로가 있다. 그중 하나는 이 확인만 막는다. 그 경로를 막는 수정이 아직 반영되지 않았으므로 지금은 확인을 뺄 수 없다.

**영향**: OOS 값을 읽는 모든 조회가 head page마다 page fix 2번을 더 쓴다. 측정한 경우 OOS fetch의 절반이 이 확인이었다. 실행 시간과 CPU 영향은 측정하지 않았다. 반대로 지금 확인을 빼면 release 빌드에서 다른 세션이 DROP한 table의 byte를 오류 없이 결과로 돌려줄 수 있다(실행 재현).

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다. CBRD-27237(PR #8434)과 CBRD-27579(PR #8182)가 반영된 뒤 착수한다.

---

## AI-Generated Context

> 아래는 PR #8491 head `a4fec6f8e2` 의 코드와, 같은 head에서 실행한 [독립 검증 보고서](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-28011/oos-read-validation.md)를 바탕으로 정리했다. 실행으로 확인한 것과 소스로만 본 것을 구분한다.

## Description

### 확인이 하는 일과 비용

[`oos_fix_page_if_oos`](https://github.com/CUBRID/cubrid/blob/a4fec6f8e26a36834c3dde4df0ed0af5ecc6d914/src/storage/oos_file.cpp#L2538-L2557)는 OOS head page를 `pgbuf_fix_if_not_deallocated` 로 fix한다. 이 함수는 fix 전에 [`disk_is_page_sector_reserved`](https://github.com/CUBRID/cubrid/blob/a4fec6f8e26a36834c3dde4df0ed0af5ecc6d914/src/storage/page_buffer.c#L16168-L16172)를 부른다. 이 함수는 volume header page를 fix하고, sector table page를 fix해 그 page의 sector가 예약되어 있는지 본다([disk_manager.c](https://github.com/CUBRID/cubrid/blob/a4fec6f8e26a36834c3dde4df0ed0af5ecc6d914/src/storage/disk_manager.c#L4271-L4291)). sector가 반환되었으면 OOS 읽기는 `ER_HEAP_OOS_CORRUPTED_RECORD` (-1397) 로 끝난다.

`oos_read` 는 값마다 이 확인을 한다. `oos_read_many` 는 head chunk가 같은 page에 있는 값들을 묶어 그 page당 한 번만 확인한다.

리뷰어가 release 빌드에서 20,000바이트 값 200행을 읽었을 때 OOS fetch는 800이었다. 같은 head에서 재현한 결과 다음과 같이 나뉘었다.

| fix 대상 | fetch |
| --- | --- |
| OOS head page | 200 |
| OOS continuation page | 200 |
| volume header page (sector 확인) | 200 |
| sector table page (sector 확인) | 200 |

실행 시간은 측정하지 않았다. [CBRD-28064](https://jira.cubrid.org/browse/CBRD-28064)의 프로파일에서도 sector 확인과 `pgbuf_fix_if_not_deallocated` 가 OOS 값 읽기의 CPU 비용 항목으로 나타났다.

### 지금 이 확인이 필요한 이유

scan이 visible로 판정한 행의 OOS 참조가 삭제되었거나 반환된 page를 가리키는 정상 SQL 경로를 두 개 실행으로 재현했다. 둘 다 PR #8491 head `a4fec6f8e2` 에서 실행했다.

| 경로 | 막는 확인 | 해결 이슈 |
| --- | --- | --- |
| UPDATE를 ROLLBACK(또는 ROLLBACK TO SAVEPOINT)한 뒤, vacuum의 forward walk가 rollback된 UPDATE의 log record를 처리해 원래 chain을 지운다. 같은 행을 읽으면 -1397이 난다. | OOS slot 부재 또는 stamp 불일치 확인. sector 확인이 아니다. | [CBRD-27237](https://jira.cubrid.org/browse/CBRD-27237), PR #8434 |
| SELECT가 호출한 PL/CSQL 함수가 COMMIT하면 lock과 snapshot이 풀리지만 query는 계속 진행된다. 그 사이 다른 세션의 DROP TABLE이 OOS file을 파괴하면, scan은 이미 복사한 참조로 sector가 반환된 head page를 읽는다. | sector 확인만 막는다. release 빌드에서 이 확인만 끄면 client가 오류 없이 파괴된 table의 byte를 받았다. debug 빌드에서는 page validation assert로 종료된다. | [CBRD-27579](https://jira.cubrid.org/browse/CBRD-27579), PR #8182 |

두 번째 경로에서 PR #8182는 SQL 문 안에서 불린 SP의 COMMIT을 `ER_SP_TCL_DDL_IN_QUERY` 로 거부한다. 이 거부가 위 재현을 막는다는 것은 코드로만 확인했고, PR #8182 빌드로 실행하지 않았다.

따라서 두 PR이 반영되기 전에는 확인을 빼거나 바꾼 결과를 검증할 기준이 없다.

### 소스로만 확인한 경로

다음 경로는 같은 질문(visible 행의 OOS 참조가 해제된 page를 가리킬 수 있는가)에 대해 소스로만 보았고 실행하지 않았다. 각 경로에서 sector 확인이 막는지, slot과 stamp 확인이 막는지도 정하지 않았다.

- **parallel scan 안의 SP COMMIT.** parallel heap scan의 출력 목록에 있는 SP가 COMMIT하면, worker가 scan하는 동안 leader의 transaction이 끝날 수 있다. PR #8182의 거부가 이 경로도 덮는지 확인해야 한다.
- **HA apply info.** MVCC를 쓰지 않는 catalog class `_db_ha_apply_info` 를 index scan이나 join의 바깥 scan으로 읽으면, page latch를 놓은 뒤 OOS 값을 읽는다. HA applier의 UPDATE는 vacuum을 기다리지 않고 이전 chain을 곧바로 지운다. 이 경로의 reader 경합은 [CBRD-27981](https://jira.cubrid.org/browse/CBRD-27981)이 조사한다.
- **SA 모드.** SA 모드에서 stored function이 바깥 scan과 같은 table을 DML하면, MVCC를 거치지 않는 즉시 삭제가 바깥 scan이 가진 참조의 chain을 지울 수 있다. 코드 주석은 SA 모드에 동시 reader가 없다고 가정한다. SA 모드에서 행이 지워진 chain을 가리키는 별도 결함은 [CBRD-28052](https://jira.cubrid.org/browse/CBRD-28052)에 있다.

### ANALYSIS에서 볼 단서

- `pgbuf_fix_if_not_deallocated` 의 주석은 이 확인이 성능 문제가 될 수 있고, transaction이 table lock을 가지면 건너뛸 수 있다고 적는다([page_buffer.c](https://github.com/CUBRID/cubrid/blob/a4fec6f8e26a36834c3dde4df0ed0af5ecc6d914/src/storage/page_buffer.c#L16168-L16172)). parallel index scan은 이미 table lock을 근거로 이 확인을 건너뛴다([px_scan_index_leaf_page_dispatcher.cpp](https://github.com/CUBRID/cubrid/blob/a4fec6f8e26a36834c3dde4df0ed0af5ecc6d914/src/query/parallel/px_scan/index/px_scan_index_leaf_page_dispatcher.cpp#L514-L520)). 위 두 번째 경로는 SP COMMIT이 그 lock을 푸는 경우이므로, lock을 근거로 한 생략은 CBRD-27579 반영 뒤에만 검토할 수 있다.
- CBRD-27981에서 정한 보강은 continuation chunk page도 해제 허용 방식으로 fix한다. 그 방식이 같은 sector 확인을 쓰면 continuation page마다 fix 2번이 더 붙는다. 이 이슈의 결정은 그 보강의 비용에도 적용된다.
- CBRD-28064의 후보 B(할당 해제 확인을 줄인다)는 이 이슈의 결정에 따른다.

## Acceptance criteria

- PR #8434와 PR #8182가 반영된 head에서 위 두 경로를 다시 실행하고, 각 경로를 어떤 확인이 막는지 기록한다.
- 소스로만 본 세 경로를 실행으로 확인하거나, 해제된 page를 가리킬 수 없는 근거를 남긴다.
- 확인을 유지, 제거, 대체 중 하나로 결정하고 근거를 남긴다.
- 제거하거나 대체하면, 해제된 page를 가리키는 참조가 release 빌드에서 다른 data의 byte를 돌려주지 않고 오류로 끝나는지 검증한다. 리뷰어와 같은 조건(release 빌드, 20,000바이트 값 200행)에서 OOS fetch 변화를 측정한다.

## Related

- 계기: [PR #8491 리뷰](https://github.com/CUBRID/cubrid/pull/8491#pullrequestreview-5914646248), [답변](https://github.com/CUBRID/cubrid/pull/8491#issuecomment-6969231100), [CBRD-28011](https://jira.cubrid.org/browse/CBRD-28011)
- 선행: [CBRD-27237](https://jira.cubrid.org/browse/CBRD-27237) (PR #8434), [CBRD-27579](https://jira.cubrid.org/browse/CBRD-27579) (PR #8182)
- 관련: [CBRD-28064](https://jira.cubrid.org/browse/CBRD-28064) OOS 값 읽기의 CPU 비용, [CBRD-27981](https://jira.cubrid.org/browse/CBRD-27981) snapshot 없는 OOS reader와 회수의 겹침
- SA 모드 사례: [CBRD-28052](https://jira.cubrid.org/browse/CBRD-28052) SA 모드 serial 롤백 뒤 행이 지워진 OOS chain을 가리킴
