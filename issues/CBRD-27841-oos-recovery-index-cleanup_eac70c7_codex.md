# [OOS] 미사용 복구 인덱스 제거와 로그 번호 정리

**한 줄 요약**: PR #7990 리뷰에서 팀장이 요청한 "로그를 기록하는 코드가 없는 복구 인덱스는 develop 병합 전에 제거한다"는 원칙에 따라, 지금 남은 미사용 인덱스 `RVREPL_OOS_DELETE`(140)를 지우고 뒤 번호를 하나씩 당기는 하위 작업이다. 처음 대상이던 `RVOOS_NOTIFY_VACUUM`은 #8434 이후 실제로 쓰이므로 유지한다.

## Issue Triage

**이슈 수행 목적**: PR #7990(`feature/oos-merge` → `develop`)이 병합되기 전에 `RVREPL_OOS_DELETE`를 제거해, develop의 로그 형식에 쓰이지 않는 복구 인덱스 번호가 남지 않게 한다.

**이슈 수행 이유**: 복구 로그는 처리 함수를 숫자 인덱스(recovery index)로 저장한다. develop에 병합되면 이 번호가 로그 형식으로 굳는다. `RVREPL_OOS_DELETE = 140`은 enum 선언, `RV_fun[]`의 덤프 전용 항목, TDE 분류 조건 한 줄에만 있다. 이 인덱스로 로그를 기록하는 코드도, log applier가 처리하는 코드도 없다. 팀장 리뷰 [r4409612618](https://github.com/CUBRID/cubrid/pull/7990#discussion_r4409612618)은 이런 인덱스를 병합 전에 모두 지워 달라고 요청했다.

**영향**: 이 항목 때문에 생긴 사용자 오류는 없다. 남겨 두면 develop은 쓰이지 않는 번호를 영구히 비워 두어야 한다. 병합 뒤에 지우려면 storage-format revision을 올리고 develop 개발 DB를 모두 다시 만들어야 한다. 병합 전에 지우면 PR #7990이 이미 요구하는 개발 DB 재생성 외에 추가 비용이 없다. 번호를 당기므로 이 변경 전에 만든 `feature/oos-merge` 개발 DB는 새 빌드에서 재사용하지 않고 다시 만든다.

**이슈 수행 방안**: 팀장 원칙(r4409612618)과 2026-11-05 댓글의 결정("필요한 복구 인덱스는 실제 생산자·소비자와 함께 정의한다")에 따른다. enum 항목, `RV_fun[]` 항목, TDE 분류 한 줄을 지우고 141~144를 140~143으로 당긴다. `RVOOS_NOTIFY_VACUUM`은 유지한다.

---

## AI-Generated Context

## Description

### 범위가 바뀐 경위

- 2026-10-29: 팀장 리뷰 [r4409612618](https://github.com/CUBRID/cubrid/pull/7990#discussion_r4409612618)이 당시 생산자가 없던 `RVOOS_NOTIFY_VACUUM`(그때 140)의 제거를 요청했다. 이 이슈는 그 요청으로 시작했다.
- 2026-11-05: 첫 정리 PR [#8347](https://github.com/CUBRID/cubrid/pull/8347)은 병합 없이 닫혔다. 같은 날 미팅에서 UPDATE 알림을 commit 후 postpone 방식(A')으로 구현하기로 정했다.
- 2026-11-18: [#8434](https://github.com/CUBRID/cubrid/pull/8434)(CBRD-27781)가 `feature/oos-merge`에 병합되었다. `oos_rv_update_drop_on_postpone ()`(`src/storage/oos_file.cpp`)이 커밋된 UPDATE의 MVCCID로 `RVOOS_NOTIFY_VACUUM`을 기록하고, vacuum의 `vacuum_oos_reclaim_notified_chains ()`(`src/query/vacuum.c`)가 이를 소비한다. 그래서 이 인덱스는 유지한다(회신 [r4613840763](https://github.com/CUBRID/cubrid/pull/7990#discussion_r4613840763)).
- 그 회신은 유지할 번호를 "140번"이라고 썼다. 실제로는 `RVOOS_NOTIFY_VACUUM`이 141이었고 140은 `RVREPL_OOS_DELETE`였다. 같은 원칙에 걸리는 남은 항목이 `RVREPL_OOS_DELETE`이므로 이 이슈의 범위를 그것으로 바꾼다. #8347의 변경 내용(`RVOOS_NOTIFY_VACUUM` 제거)은 지금 기준에서 틀리므로 재사용하지 않는다.

### 현재 상태 (`feature/oos-merge` `71993ddb63`과 `d25c9e8d20`에서 확인)

`git grep RVREPL_OOS_DELETE`는 정의 세 곳만 찾는다.

- `src/transaction/recovery.h`: `RVREPL_OOS_DELETE = 140`
- `src/transaction/recovery.c`: `RV_fun[]` 항목. undo·redo 함수 없이 replication 덤프 함수만 있다.
- `src/storage/tde.h`: `LOG_MAY_CONTAIN_USER_DATA` 조건 한 줄

복제 로그에서 OOS 값이 있는 행의 INSERT·UPDATE는 `RVREPL_OOS_INSERT`와 `RVREPL_DUMMY_OOS_RECORD`를 쓴다(`src/transaction/locator_sr.c`). DELETE는 OOS 전용 복제 항목 없이 일반 행 삭제 항목만 쓴다. log applier(`src/transaction/log_applier.c`)와 `src/transaction/replication.c`도 OOS 항목으로는 이 두 인덱스만 처리한다.

### 번호 변경

`RV_fun[]`은 recovery index를 배열 위치로 바로 찾으므로, enum 번호와 배열 순서를 함께 당긴다.

| 이름 | 현재 | 변경 후 |
|---|---|---|
| `RVOOS_INSERT` | 137 | 137 |
| `RVOOS_DELETE` | 138 | 138 |
| `RVREPL_OOS_INSERT` | 139 | 139 |
| `RVREPL_OOS_DELETE` | 140 | 삭제 |
| `RVOOS_NOTIFY_VACUUM` | 141 | 140 |
| `RVREPL_DUMMY_OOS_RECORD` | 142 | 141 |
| `RVOOS_RECLAIM_POSTPONE` | 143 | 142 |
| `RVOOS_UPDATE_DROP_POSTPONE` (`RV_LAST_LOGID`) | 144 | 143 |

develop의 마지막 인덱스는 `RVPGBUF_INIT_NEW_PAGE = 136`이므로 develop 쪽 번호는 바뀌지 않는다. 다른 분류 매크로(`LOG_IS_MVCC_OPERATION`, `RCV_IS_NOTHING_TO_UNDO`, `RCV_IS_LOGICAL_LOG`), 로그 덤프, log applier는 이름으로 인덱스를 비교하므로 번호 변경에 따른 추가 수정이 없다. 두 testcase 저장소의 `feature/oos-merge`에도 이 번호를 숫자로 쓰는 기대값은 없다. 이름으로 쓰는 곳은 TDE shell 테스트의 `RVOOS_INSERT`, `RVOOS_DELETE`뿐이고 둘 다 번호가 그대로다.

### 형식 정책

ADR-0008의 병합 전 결정대로 `DISK_STORAGE_FORMAT_REVISION`은 1로 유지하고, 이 변경 전에 만든 개발 DB는 다시 만든다. revision이 같으므로 번호만 보고 이전 개발 DB를 거부하지는 못한다.

### 관련 작업

- 상위 작업: [CBRD-26583](https://jira.cubrid.org/browse/CBRD-26583)(OOS M2).
- [CBRD-27230](https://jira.cubrid.org/browse/CBRD-27230)의 [#8559](https://github.com/CUBRID/cubrid/pull/8559)는 `RVREPL_OOS_REUSE = 145`를 끝에 더한다. 이 변경이 들어가면 #8559는 144로 다시 매겨야 하고, `RV_LAST_LOGID` 줄과 `tde.h` 마지막 줄에서 rebase 충돌을 해결해야 한다.

## Implementation and Validation

구현은 [PR #8646](https://github.com/CUBRID/cubrid/pull/8646)(draft, `feature/oos-merge` 대상, head `1d86f1d31b`)이다. 세 파일에서 8줄을 지우고 4줄의 번호를 바꾼다. 테스트케이스 변경은 없다.

debug 빌드에서 확인한 결과는 다음과 같다. 절차와 다시 실행할 수 있는 스크립트는 [verification.md](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27841/verification.md)에 있다.

- 설치한 서버·SA 라이브러리에서 `RV_fun[]` 144개 항목이 모두 `recv_index == i`이고, 항목 수가 `RV_LAST_LOGID + 1`(143 + 1)이다.
- 설정한 CTest 66개가 모두 통과했다.
- OOS UPDATE·DELETE를 커밋하고 다른 UPDATE·INSERT를 커밋하지 않은 채 서버를 `kill -9`로 종료했다. 재시작 뒤 데이터는 커밋 상태와 같았다. vacuum은 `RVOOS_NOTIFY_VACUUM` 200개를 소비해 UPDATE의 옛 OOS chain 400개를 회수했고, DELETE의 chain도 모두 회수했다. `checkdb`도 통과했다. 로그 덤프에서 이 레코드들은 새 번호에 맞는 이름으로 읽혔다.
- HA 복제 smoke test는 하지 않았다. `RVREPL_OOS_INSERT`(139)는 번호가 그대로이고, `RVREPL_DUMMY_OOS_RECORD`는 복제 코드가 이름으로만 처리한다.

PR CI는 2026-11-19에 `/run all`로 시작했다([run 44501180486](https://github.com/CUBRID/cubrid/actions/runs/44501180486)).

## Acceptance Criteria

- `RVREPL_OOS_DELETE`가 source에 남지 않는다.
- 모든 인덱스 `i`에 대해 `RV_fun[i].recv_index == i`이고, `RV_fun[]`의 항목 수가 `RV_LAST_LOGID + 1`이다.
- `RVOOS_NOTIFY_VACUUM`의 처리 함수와 MVCC·TDE·logical-log 분류가 그대로다.
- OOS 값의 INSERT·UPDATE·DELETE 중 서버를 강제 종료한 뒤 재시작하면 데이터가 맞고, vacuum이 `RVOOS_NOTIFY_VACUUM`을 소비해 OOS chain을 회수한다.
- 설정된 CTest와 PR CI가 통과한다.
