# [OOS] [M2] [Regression] server-side loaddb 가 OOS 대상 행을 적재하면 MVCCID self-lock assert 로 cub_server 가 abort 되는 문제 수정

## Issue Triage

**이슈 수행 목적**: server-side loaddb (`loaddb -C`) 로 OOS 대상 행을 적재해도 debug 빌드 `cub_server` 가 abort 되지 않고 적재가 정상 완료되는 상태로 만든다.

**이슈 수행 이유**:

- **AS-IS (현재 동작 / 배경)**: `loaddb -C` 로 클래스의 첫 OOS demote 대상 행(큰 가변 컬럼 값을 별도 OOS 파일로 내려보내야 하는 행)을 적재하면 debug 빌드 `cub_server` 가 assert 실패로 즉시 종료된다. `feat/oos` 가 2026-07-30 develop 머지를 받은 뒤 생긴 회귀다.
- **TO-BE (목표 상태 / 기대 동작)**: 적재가 끝까지 완료된다 ("Total N object(s) inserted").
- **영향**: QA 실패 — CircleCI test_shell 실패 19건 중 3건 (`cbrd_25481`, `loaddb_CS/itrack_10006`, `loaddb_CS/bug_xdbms_sus880`) 이 이 크래시로 실패하며, 실패마다 `cub_server` core 가 남는다.

**이슈 수행 방안** (합의됨): loaddb 를 self-lock 에서 예외 처리(스킵)하는 대신, 락 매니저의 loaddb 워커 락 금지 assert 를 객체 락에 한정하여 loaddb 워커도 트랜잭션 MVCCID self-lock 을 다른 트랜잭션과 동일하게 획득한다. 객체 락에 대한 기존 금지 계약(CBRD-23375)은 그대로 유지하고 assert 가 계속 감시한다. 리뷰 의견 인용: "loaddb 예외를 늘리지 말고 uniform 하게".

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: `src/transaction/lock_manager.c` 1개 파일 (+5/-1) — assert 한 줄 완화와 근거 주석 4줄. 동작 변화는 assert 가 살아 있는 debug/optdebug (assert 활성 최적화 빌드) 에 한정된다. release 빌드는 assert 가 컴파일 아웃되어 코드 변화가 없고, 버그 자체도 release 에서는 크래시하지 않을 것으로 보이나 검증하지는 않았다. `feat/oos` 전용 회귀로, develop 단독에서는 트리거 경로가 없어 재현되지 않는다. 수정 PR: https://github.com/CUBRID/cubrid/pull/7588 (base `feat/oos`, 커밋 `e20543df8`; 커밋 메시지의 티켓 번호는 진행 중인 CI 완료 후 CBRD-27157 로 교체 예정).

---

## Description

서로 독립적으로는 올바른 세 가지 설계가 develop 머지(`0ad6afc0f`)에서 처음 한 무대에 올라 충돌했다.

| 규칙 | 도입 | 내용 |
|---|---|---|
| loaddb 워커 락 금지 | CBRD-23375 (2019) | server-side loaddb 워커 스레드(`TT_LOADDB`)는 세션 트랜잭션이 쥔 BU_LOCK (bulk-update 용 클래스 단위 락)에 의존하며 락 매니저에 진입하지 않는다. `lock_internal_perform_lock_object` 의 assert 로 강제 |
| MVCCID self-lock | CBRD-26942 (2026-07-25, develop) | 행마다 걸던 X 락을 트랜잭션당 1개로 줄이기 위해, 트랜잭션이 첫 MVCCID (트랜잭션의 MVCC 식별 번호)를 발급받는 시점에 그 MVCCID 에 스스로 X 락을 건다 (self-lock). unique/FK 검사자는 미완성 행의 INSID (레코드 헤더에 기록되는 삽입자 MVCCID 도장)를 보고 이 락 위에서 대기한다 |
| OOS 파일 lazy 생성 | feat/oos | OOS (Out-of-row Overflow Storage — 큰 가변 컬럼 값을 힙 레코드에서 분리해 별도 파일에 저장) 파일은 클래스의 첫 demote (컬럼 값을 OOS 파일로 내려보내는 동작) 시점에 생성된다. `file_create` 는 vacuum dropped-file 검사를 위해 `logtb_get_current_mvccid` 를 호출하는데 (`src/storage/file_manager.c`), feat/oos 가 이 대상 파일 타입 목록에 `FILE_OOS` 를 추가했다 |

loaddb 워커의 벌크 삽입은 INSID 스탬프를 생략하므로 (`is_bulk_op`, `src/storage/heap_file.c`) 비-OOS 적재에서는 워커가 MVCCID 를 요구하는 지점이 없다. 확인된 범위에서 OOS 파일 lazy 생성은 TT_LOADDB 스레드가 MVCCID 발급 지점에 도달하는 유일한 진입 경로이며, CBRD-26942 가 그 경로를 assert 위반으로 바꿨다. 크래시 호출 경로 (로컬 core 4건의 스택과 대조 일치):

```
lock_internal_perform_lock_object     ← assert (thread_p->type != TT_LOADDB)
lock_transaction_mvccid
logtb_acquire_mvccid_self_lock
logtb_self_lock_assigned_mvccid
logtb_get_current_mvccid              ← lazy 할당 분기
file_create                           ← vacuum dropped-file 검사용 MVCCID 요구
oos_create_file
heap_oos_find_vfid (create)
heap_oos_insert_serialized_values
heap_attrinfo_insert_to_oos
heap_attrinfo_transform_to_disk_internal
heap_attrinfo_transform_to_disk_except_lob
cubload::server_object_loader::finish_line
```

self-lock 의 발급 시점 진입점은 `logtb_get_current_mvccid` 의 lazy 할당 분기와 `logtb_get_new_subtransaction_mvccid` 두 곳이고, heap 삽입 지점의 `logtb_ensure_mvccid_self_lock` 도 같은 공유 헬퍼 `logtb_acquire_mvccid_self_lock` 을 거치므로 본 수정이 모두 커버한다.

### 수정 설계: loaddb 예외가 아니라 uniform self-lock

```c
/* lock_internal_perform_lock_object */
assert (thread_p->type != TT_LOADDB || is_transaction_lock);
```

`is_transaction_lock` 은 락 키가 `LOCK_RESOURCE_TRANSACTION` (MVCCID 키 트랜잭션 락) 타입인지 여부다. 코드로 확인한 안전 근거는 네 가지다.

1. **락 소유자가 올바름** — `lock_transaction_mvccid` 는 워커 스레드 자신의 tran_index 를 쓰고 (`LOG_FIND_THREAD_TRAN_INDEX`), `load_task::execute` 가 배치마다 fresh 트랜잭션을 발급하므로 (`src/loaddb/load_session.cpp`) 락은 그 배치 트랜잭션 소유가 된다.
2. **절대 대기하지 않음** — 방금 발급된 MVCCID 는 다른 트랜잭션이 알 수 없으므로 X 요청이 즉시 granted 된다. 데드락 불가.
3. **해제도 표준 경로** — 배치는 커밋(`xtran_server_commit`)이든 어보트(`xtran_server_abort`)든 트랜잭션 종료 시 `lock_unlock_all` 이 self-lock 을 함께 해제한다 (transaction self-lock 은 instance lock 과 같은 보유 목록 `inst_hold_list` 로 추적).
4. **debug 를 release 의 기존 동작에 맞추는 방향** — release 는 assert 가 없어 이 경로에서 이미 self-lock 을 획득해 왔으므로, 새 동작을 도입하는 것이 아니라 빌드 간 불일치를 없애는 것이다.

부수 효과로 CBRD-26942 의 불변식("관측 가능한 INSID 는 보유 중인 X self-lock 을 의미")이 loaddb 경로에서도 구조적으로 성립한다. 미래에 어떤 코드가 loaddb 행에 INSID 를 찍더라도 별도 방어 없이 정상 동작한다 — 배치 트랜잭션은 자기 self-lock 외의 락을 쥐지 않으므로, 그 MVCCID 를 기다리는 검사자가 세션의 BU_LOCK 과 대기 사이클을 만들 수 없기 때문이다.

잔여 리스크는 한 가지다: 완화된 assert 는 워커가 (본 경로 외의 이유로) 트랜잭션 락을 잡는 것을 더 이상 잡아내지 못하며, 정확성은 `is_transaction_lock` 플래그가 정직하게 전달된다는 데 의존한다.

검토 후 기각한 대안:

| 순위 | 대안 | 기각 이유 |
|------|------|-----------|
| 1 | self-lock 스킵 (이전 리비전 `c0a5e1ee8`) | "이 락을 기다릴 관측자가 없다"는 증명에 의존하고, 미래 INSID 생산자에 무방비. 리뷰 의견을 반영해 본 방식으로 교체 |
| 2 | assert 전체 삭제 + 락 금지 정책 폐지 | 락 금지 정책은 assert 한 곳이 아니라 락 매니저 전반에 퍼져 있다 — `lock_object` 는 워커의 객체 락 요청을 세션 BU_LOCK 으로 대답하고, `lock_get_object_lock` / `lock_has_lock_on_object` / `lock_get_class_lock` 은 워커의 락 조회를 세션 트랜잭션으로 리다이렉트한다. 워커가 객체 락을 실제로 잡으면 락 소유(배치 트랜잭션)와 조회(세션 트랜잭션)가 어긋나고 세션 BU_LOCK 과의 데드락에 노출된다. CBRD-23375 재설계 규모의 별도 과제 |
| 3 | 세션 스레드에서 MVCCID 선발급 | loaddb 가 쓰는 모든 트랜잭션 경계(스키마/오브젝트 단계가 따로 커밋)에 누락 없이 심어야 하고, MVCCID 가 필요 없는 적재에도 발급하게 된다 |
| 4 | `file_create` 의 lazy 할당 제거 (비할당 getter) | dropped-file 검사의 MVCCID 는 비교 기준값일 뿐이라 방향 자체는 국소적이나, 현재 비할당 getter API 가 없어 새 API 표면이 필요하고 heap/btree 파일 생성 경로의 의미에도 영향을 준다. 장기 개선으로 재검토 가치는 있음 |

## Test Build

- 크래시 재현: `11.5.0.2460-0ad6afc` 64-bit debug (Rocky Linux 9).
- 수정 검증: 동일 워크트리에서 `feat/oos` 헤드(`d4e2ebb79`) 리베이스 후 커밋 `e20543df8` debug 재빌드.
- CI: CircleCI optdebug — test_shell job 142161 (base, 실패) / job 142569 (1차 수정, 복구 확인).

## Repro

본 수정 미적용 debug 빌드 기준. 검증된 재현은 CTP (CUBRID Test Platform):

```bash
# shell_ci.conf 를 복사해 아래 세 가지를 수정 후 실행:
#   scenario=<testcases>/shell/_06_issues/_24_2h/cbrd_25481
#   testcase_update_yn=false
#   testcase_exclude_from_file 줄 주석 처리
# 테스트케이스 저장소: cubrid-testcases-private-ex (feature/oos-m2 브랜치)
ctp.sh shell -c shell_ci.conf
```

최소 재현 (동일 메커니즘, 미검증 — CTP 재현만 실측):

```bash
# 조건: 레코드가 OOS demote 게이트 DB_PAGESIZE/4 (기본 16K 페이지에서 4,096B,
#       페이지 크기에 비례) 를 넘고, 가변 값이 OOS inline stub 크기
#       OR_OOS_INLINE_SIZE (OID 8B + 길이 8B = 16B) 보다 커야 demote 된다.
# BIT VARYING 을 쓰는 이유: VARCHAR 는 255B 이상에서 LZ4 압축되어
#       반복 문자열이 게이트를 못 넘을 수 있다.
cubrid createdb --db-volume-size=64M srcdb en_US.utf8
cubrid server start srcdb
csql -C -u dba -c "CREATE TABLE t (id INT, big BIT VARYING);" srcdb
csql -C -u dba -c "INSERT INTO t VALUES (1, CAST(REPEAT('AA', 5000) AS BIT VARYING));" srcdb
cubrid unloaddb -u dba --CS-mode srcdb
cubrid server stop srcdb

cubrid createdb --db-volume-size=64M dstdb en_US.utf8
cubrid server start dstdb
cubrid loaddb -C -u dba -s srcdb_schema -d srcdb_objects dstdb
cubrid server stop dstdb
```

## Expected Result

```
Start object loading.
Total 1 object(s) inserted, 0 object(s) failed.
```

TC 기준: `cbrd_25481` 28/28 OK, `itrack_10006` 2/2 OK, `bug_xdbms_sus880` 1/1 OK.

## Actual Result

```
line 47: 57309 Aborted    cub_admin loaddb --no-user-specified-name -C -u dba ...
ERROR: Your transaction has been aborted by the system due to server failure or mode change.
```

`cub_server` 가 SIGABRT 로 종료되고 core 가 남는다 (`cbrd_25481` 은 DB 4개 각각에서 동일 스택 core). 이후 접속은 "Failed to connect to database server" 로 실패한다.

## Additional Information

- 수정 검증 (로컬 debug, CTP): 세 TC 모두 OK, 신규 core 0건. 리베이스 후 `itrack_10006` 1건 스모크 재실행 OK. uniform 방식(`e20543d`) CI 는 PR #7588 에서 진행 중.
- CI 교차 검증 (1차 수정 `c0a5e1e`, job 142569): test_shell 실패 19건 → 18건. 본 이슈의 3건이 모두 실패 목록에서 빠졌고, 남은 18건 중 16건은 base 와 동일한 상속 실패, 2건(`_01_cursor_functional` 신규, `log_enc_04` 재출현)은 loaddb 경로와 무관한 간헐 실패로 판단했다.
- 회귀 테스트: 신규 TC 는 추가하지 않는다 — 세 TC 모두 CI 상주 테스트라 그 자체가 회귀 방어선이며, TC 와 answer 파일은 올바른 상태다.
- 브랜치: PR 은 `feat/oos` 대상이다. 완화 대상 assert 와 CBRD-26942 는 develop 소유 코드지만, develop 단독에는 TT_LOADDB 스레드가 MVCCID 발급에 도달하는 경로가 없어 증상이 없다. feat/oos → develop 머지 시 본 수정이 함께 흘러간다.
- 관련 이슈: CBRD-26942, CBRD-23375, 상위 이슈 CBRD-26835.
- 상세 분석 문서: https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27157/CBRD-27157-loaddb-mvccid-selflock_c0a5e1e_claude.md (하단 Revision 절이 uniform 방식 개정 이력)
