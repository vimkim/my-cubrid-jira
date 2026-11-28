# [OOS] CBRD-26793 group locking이 develop에 들어간 뒤 OOS 단위 테스트 6개가 실패한다

**한 줄 요약**: CBRD-26793(#8653, `e638a2f224`)이 develop에 merge된 뒤로 OOS 단위 테스트 6개가 매번 실패한다. 테스트가 끝날 때 비어 있어야 할 스레드의 OOS 게시 목록(`oos_oids`)에 값이 남는다. 원인을 찾아 테스트를 다시 통과시켜야 한다.

## Issue Triage

**이슈 수행 목적**: develop에서 OOS 단위 테스트 6개가 다시 통과하고, 실패가 제품 결함인지 테스트 환경 문제인지 판별되어야 한다.

**이슈 수행 이유**: `git bisect` 결과 `e638a2f224` [CBRD-26793]이 첫 실패 commit이고, 바로 앞 commit `435b0b7005`에서는 같은 테스트가 통과한다. 6개 모두 테스트 한 개만 따로 실행해도 매번 실패한다. 공식 CI(gha-ci)는 ctest 단위 테스트를 돌리지 않으므로 이 회귀는 CI에서 드러나지 않는다.

**영향**: OOS 관련 PR을 develop 위로 rebase하는 개발자는 push 전 확인용 ctest가 실패해서, 자기 변경과 상관없는 실패를 따로 구분해야 한다. 실제로 CBRD-28378(PR #8754) 작업이 이 때문에 push 전 확인에서 멈췄다. 게시 목록에 값이 남는 현상이 실제 서버의 OOS insert/update 경로에서도 일어나는지는 아직 확인하지 않았다. 일어난다면 다음 요청이 이전 요청의 OOS OID를 이어받을 수 있다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

OOS 단위 테스트는 OOS 값을 insert, update, finalize하고 나서 스레드 항목의 `thread_p->oos_oids`와 트랜잭션의 `tdes->oos_insert_lsa_queue`가 기대한 상태인지 확인한다. `oos_oids`는 한 요청 안에서 새로 게시한 OOS OID를 모아 두는 목록이고, 요청을 마치거나 finalize할 때 비워야 한다. `e638a2f224` 이후에는 이 목록이 비워지지 않았거나, 테스트가 확인하는 스레드 항목이 값을 넣은 스레드 항목과 다르다.

`e638a2f224`는 트랜잭션 실행 토큰(`tx_exec_token`, `logtb_exec_begin ()`)과 `thread_entry`의 새 필드 `exec_token`, 그리고 parallel section 동안의 lock group 진입을 추가했다. 이 변경이 단위 테스트가 쓰는 스레드 항목이나 요청 경계에 어떤 영향을 주는지는 아직 분석하지 않았다.

### Test Build

- 실패: CUBRID develop `08f8185500` 및 `e638a2f224`, debug 빌드
- 통과: `435b0b7005`, `6f5ac7a9f9`
- 환경: Linux x86_64

### Repro

```bash
git checkout e638a2f224
cmake --preset <debug preset with unit tests>
cmake --build --preset <same preset>
cd "$BUILD_DIR"
ctest -R '^(test_oos_server|test_oos_update_reuse_write|test_oos_sql_deferred_write_(preparation|routing|duplicates|updates))$' -j1 --output-on-failure
```

`test_oos_server`가 실패하는지만 판정 기준으로 써서 `git bisect run`으로 `6f5ac7a9f9`(good)부터 `08f8185500`(bad)까지 25개 commit을 이분 탐색했다.

### Expected Result

6개 테스트가 모두 통과한다(`e638a2f224` 바로 앞 commit `435b0b7005`의 결과).

### Actual Result

| 테스트 | 결과 | 대표 실패 |
|---|---|---|
| `test_oos_server` | SIGTRAP | `test_oos_server.cpp:102` `thread_p->oos_oids.empty ()`가 false |
| `test_oos_update_reuse_write` | Failed | `OosUpdateReuse.ReplicatesAReusedColumnAsAMarkerInAttributeOrder`: `thread_p->oos_oids.size ()`가 2가 아니라 1 |
| `test_oos_sql_deferred_write_preparation` | SegFault | `OwnerlessCopyAreaBypassClearsBothPublicationsAndKeepsReceivedBytes`: `test_oos_sql_deferred_write.cpp:293` `oos_oids.empty ()`가 false |
| `test_oos_sql_deferred_write_routing` | Failed | 4건, 예: `PendingReferencesResolveAndFinalizeInPlace` (`:1041` `oos_oids.empty ()`가 false) |
| `test_oos_sql_deferred_write_duplicates` | Failed | `AllocationAndStorageFailureLeaveNextInsertUsable` (`:1521`), `DuplicateProbeFailuresLeaveNextWriteUsable` (`:1742`) |
| `test_oos_sql_deferred_write_updates` | Failed | 4건, 예: `UpdateFailureClearsPublicationAndRollsBackBothDestinations` |

같은 빌드에서 `test_oos_real_vacuum_latch_timeout_retry`는 `-j8` 병렬 실행일 때만 timeout이 났고 단독 실행에서는 통과했다. 이번 회귀와는 별개이며, 이 테스트의 대기 문제는 CBRD-28436에서 다룬다.

### ANALYSIS 확인 사항

- 실행 토큰이나 lock group 변경 뒤에 `oos_oids`에 남는 값은 어느 경로에서 들어오고, 어느 경로에서 비우지 못하는가.
- 테스트 하네스만의 문제(테스트가 직접 만든 스레드 항목, 요청 경계 흉내)인가, 아니면 서버 요청 처리(`net_server_request ()` 경계)에서도 `oos_oids`가 남는가.
- 서버에서도 남는다면 다음 요청의 OOS 게시나 replication 로그에 영향이 있는가.
