# [OOS] 끝나지 않은 OOS chunk 삭제가 비운 슬롯을 다른 트랜잭션이 재사용해 rollback undo 가 충돌한다

## Issue Triage

**이슈 수행 목적**: 롤백될 수 있는 OOS chunk 삭제가 끝날 때까지 그 슬롯과 공간을 다른 트랜잭션이 쓰지 못하게 하여, 삭제의 undo 가 항상 원래 자리에 chunk 를 복원하도록 한다.

**이슈 수행 이유**: OOS 페이지는 `ANCHORED` 로 초기화되고 복구 공간 예약(`is_saving`)이 꺼져 있어, `spage_delete` 직후 슬롯과 바이트가 곧바로 재사용 가능해진다. 삭제 주체(vacuum sysop 또는 사용자 트랜잭션)가 끝나기 전에 다른 트랜잭션이 그 슬롯이나 공간에 insert 하고 commit 하면, 이후 삭제 주체의 abort 가 `RVOOS_DELETE` undo 로 같은 슬롯에 이전 chunk 를 넣으려다 충돌한다. PR #7990 의 Greptile 4차 리뷰(r4380243533)가 지적했고, SERVER_MODE 단위 테스트로 재현했다. 같은 날 PR #7990 리뷰어(shparkcubrid)도 코드 확인만으로 이 결함을 블로킹으로 지적하며, 발생 경로로 vacuum sysop 의 중간 abort, vacuum sysop 도중 서버 장애 후 복구 undo, 비-MVCC 즉시 삭제 경로(SA 모드와 in-place update)를 들었다.

**영향**: debug 빌드는 `spage_insert_for_recovery` assert 로 서버가 종료되고, release 빌드는 다른 트랜잭션이 commit 한 OOS chunk 의 슬롯을 덮어쓴다(소스 분석). 충돌이 남은 채 서버가 죽으면 restart recovery 가 같은 undo 를 다시 수행해 debug 빌드 DB 가 boot 되지 않는 것을 확인했다. 현실적인 발생 조건은 vacuum 의 OOS 삭제 sysop 이 일부 chunk 를 지운 뒤 끝나기 전에 다른 트랜잭션이 같은 OOS 파일에 insert 하고, 그 sysop 이 오류로 abort 되거나 서버 장애 후 restart recovery 가 그 sysop 을 되돌리는 경우다. 빈도는 낮다고 판단하나 측정하지 않았다. 리뷰어가 든 SA 모드와 in-place update 경로는 삭제 주체가 끝나기 전에 다른 트랜잭션이 같은 OOS 파일에 insert 할 수 없어 해당하지 않는다고 판단한다(소스 분석).

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

> 아래는 제공된 자료와 확인한 근거를 바탕으로 작성한 상세 맥락이다. 미확인 사항은 본문에 구분한다.

## Description

### 무엇이 문제인가

OOS chunk 삭제(`oos_delete_chain`, `src/storage/oos_file.cpp`)는 chunk 마다 페이지를 write latch 로 잡고, `RVOOS_DELETE` 를 기록한 뒤(undo 데이터는 chunk 전체), `spage_delete` 로 지우고, bestspace 에 늘어난 여유 공간을 알린 다음 latch 를 푼다. 삭제를 되돌릴 때는 `oos_rv_redo_insert` 가 `spage_insert_for_recovery` 로 chunk 를 **같은 슬롯**에 넣어야 한다. 앞 chunk 의 `next_chunk_oid` 와 heap 레코드의 OOS inline stub 이 그 OID 를 가리키기 때문이다. `spage_insert_for_recovery` 는 그 슬롯이 비어 있다고 가정한다(`slotted_page.c:1969` assert).

그런데 OOS 페이지는 `oos_vpid_init_new` 에서 `spage_initialize (..., ANCHORED, OOS_ALIGNMENT, false)` 로 초기화된다.

- `ANCHORED` 페이지에서 `spage_delete` 는 슬롯을 `REC_DELETED_WILL_REUSE` 로 표시하고, 바이트를 `total_free` 로 돌려준다. 다음 `spage_insert` 는 `spage_find_free_slot` 에서 그 슬롯을 가장 먼저 고른다.
- `is_saving` 이 false 라 삭제자의 몫으로 바이트를 예약하지 않는다.

즉 삭제 주체가 끝나기 전에도 다른 트랜잭션이 그 슬롯과 공간을 가져갈 수 있다. heap 은 `ANCHORED_DONT_REUSE_SLOTS`(지운 슬롯을 `REC_MARKDELETED` 로 두고 재사용하지 않음)와 `SAFEGUARD_RVSPACE`(삭제자 몫의 바이트 예약)를 함께 써서 이 상황을 막는다. heap vacuum 은 redo-only 라서 공간 예약에서 빠지지만, OOS vacuum 삭제는 sysop abort 로 되돌려진다는 점이 다르다.

롤백될 수 있는 `RVOOS_DELETE` 를 남기는 호출자는 셋이다.

1. vacuum 알림/forward-walk 삭제 `vacuum_forward_walk_oos_delete_atomic` (`src/query/vacuum_oos.cpp:153`): 여러 체인을 sysop 하나에서 지우고(`:172`, `:182`), 뒤쪽 `oos_delete` 가 오류를 내면 sysop 을 abort 한다(`:207`).
2. vacuum REMOVE `vacuum_heap_oos_delete_within_sysop` (`src/query/vacuum_oos.cpp:447`, heap 레코드 vacuum sysop 안에서 `src/query/vacuum.c:2563`, `:2623` 이 호출): OOS 삭제 오류 시 sysop 을 abort 한다(`vacuum.c:2567`, `:2627`).
3. eager cleanup `heap_oos_delete_unreferenced` (`src/storage/heap_oos.cpp:953`): 비-MVCC 연산(`is_mvcc_op` 가 false)의 DELETE 와 UPDATE 에서, 옛 레코드만 참조하던 OOS 체인을 사용자 트랜잭션 안에서 sysop 없이 지운다(`heap_oos.cpp:1033`, 호출 지점 `heap_file.c:23951`, `:24297`, `:24729`, `:25214`). SERVER_MODE 에서 비-MVCC 연산이 되는 경우는 둘이다.
   - **MVCC 비활성 클래스의 DELETE 와 UPDATE**: DELETE 는 이 경우에만 비-MVCC 연산이다(`heap_file.c:25763-25774`). 해당 클래스는 root, `db_serial`, `_db_collation`, `db_ha_apply_info` 다. 그러나 root 는 OOS 대상에서 제외되고, `db_serial` 은 comment 가 1024 바이트로 제한되어 행이 약 2.2 KB 를 넘지 않으며(실측: 1024 자 4 바이트 문자 comment 는 파서가 거부), `_db_collation` 은 작다. `db_ha_apply_info.copied_log_path` 가 약 3.9 KB 를 넘는 경우만 이론상 가능하다.
   - **MVCC 클래스의 in-place UPDATE**: UPDATE 의 연산 종류는 `HEAP_UPDATE_IS_MVCC_OP` 로 정하며, MVCC 클래스라도 in-place 이면 비-MVCC 연산이 된다(`heap_file.c:169-174`, `:25983`). 이전 판은 이 경우를 빠뜨렸다. 아래 "in-place UPDATE 경로" 에서 분석하며, 이 결함으로 이어지지 않는다고 판단한다.

호출자 3 은 SA_MODE 에서도 실행된다. SA_MODE 에서는 UPDATE 와 DELETE 가 모두 비-MVCC 연산이지만(`heap_file.c:172-173`, `:25772-25773`), 트랜잭션이 하나뿐이고 같은 트랜잭션의 이후 insert 는 rollback 에서 먼저 취소되므로(LIFO) 해당하지 않는다.

**in-place UPDATE 경로(소스 분석, 실행하지 않음).** PR #7990 head `dcbf09e4f` 에서 확인했다.

1. SERVER_MODE 의 UPDATE 는 `is_mvcc_op = HEAP_UPDATE_IS_MVCC_OP (is_mvcc_class, update_in_place)` 로 연산 종류를 정한다(`heap_file.c:25983`). 이 매크로는 MVCC 클래스이면서 in-place 가 아닐 때만 true 다(`heap_file.c:169-171`). 따라서 MVCC 클래스의 in-place UPDATE 도 `heap_update_home`(`heap_file.c:25214-25217`)과 `heap_update_relocation`(`heap_file.c:24729-24731`)에서 eager cleanup 을 부른다. `heap_oos_delete_unreferenced` 의 함수 주석(`heap_oos.cpp:920-922`)은 SERVER_MODE 에서 MVCC 비활성 클래스만 언급해 이 경우가 빠져 있다.
2. SQL 로 사용자 클래스 행을 in-place UPDATE 하는 경로는 컬럼 타입 변경 하나다. `ALTER TABLE ... CHANGE/MODIFY` 가 행 갱신을 요구하면(`execute_schema.c:10913-10915`) 클래스마다, 분할 테이블이면 분할마다 `xlocator_upgrade_instances_domain`(`locator_sr.c:12540`)을 부른다(`execute_schema.c:11034`, `:11043`). 이 함수는 `heap_object_upgrade_domain`(`locator_sr.c:12654`)으로 각 행을 `UPDATE_INPLACE_OLD_MVCCID` 로 다시 쓰고(`heap_file.c:19901-19904`), 이 값은 `locator_attribute_info_force` 와 `locator_update_force` 를 거쳐 update context 에 그대로 들어간다(`locator_sr.c:7919`, `:6184`).
3. 이 경로는 클래스에 `SCH_M_LOCK` 을 잡는다(`locator_sr.c:12542`, `:12278-12279`). 오류 경로의 `lock_unlock_object` 도 S_LOCK 이 아니면 풀지 않으므로(`lock_manager.c:7205-7210`) 잠금은 트랜잭션이 끝날 때까지 유지된다. 그동안 다른 트랜잭션은 그 클래스에 INSERT 나 UPDATE 를 할 수 없다.
4. OOS 파일은 heap 파일마다 따로 있다. heap 헤더가 `oos_vfid` 를 갖고(`heap_file.c:216`), OOS insert 와 eager cleanup 은 모두 해당 heap 헤더에서 OOS 파일을 찾는다(`heap_file.c:13242-13323`, `heap_oos.cpp:880`, `:994`). 따라서 ALTER 트랜잭션이 끝나기 전에 그 OOS 파일에 insert 할 수 있는 것은 그 트랜잭션 자신뿐이고, 그 insert 는 rollback 에서 먼저 취소된다(Repro 의 대조군과 같은 상황). vacuum 은 OOS chunk 를 지우기만 하고 insert 하지 않는다.
5. 나머지 in-place UPDATE 는 OOS 를 지우지 않거나 도달할 수 없다.
   - FK 캐시 객체 갱신(`locator_sr.c:5283-5290`)은 `is_cached` 가 true 일 때만 실행되는데, `locator_check_foreign_key`(`locator_sr.c:4068-4230`)는 이 값을 쓰지 않는다. 문법에도 `ON CACHE OBJECT` 가 없다. FK 규칙은 `ON DELETE` 와 `ON UPDATE` 뿐이다(`csql_grammar.y:9520-9653`).
   - 주소만 할당된 새 인스턴스(`ER_HEAP_NODATA_NEWADDRESS`, `locator_sr.c:5884-5886`)는 `REC_ASSIGN_ADDRESS` 레코드라 옛 OOS 가 없다. eager cleanup 은 옛 레코드가 `REC_HOME` 이나 `REC_NEWHOME` 일 때만 실행된다.
   - 클래스 객체, catalog 행, `db_root`, TDE 키 정보의 in-place 갱신(`locator_sr.c:5676-5677`, `:5775-5776`, `catalog_class.c:3953-3954`, `boot_sr.c:6199-6200`, `tde.c:652-653`)은 사용자 클래스 행이 아니다. 이 레코드들은 OOS 플래그를 켜는 attrinfo 변환 경로(`heap_file.c:13646-13647`, `:13734-13737`)를 거치지 않고 직접 만들어지므로(catalog 는 `catalog_class.c:3938`, `:4268`), eager cleanup 조건(`heap_recdes_contains_oos`)을 만족하지 않는다.
   - `compactdb.c:704-705` 는 SA 전용 유틸리티(`sa/CMakeLists.txt:28`)라 SA_MODE 와 같다.

정리하면 in-place UPDATE 의 eager cleanup 은 사용자 트랜잭션 안에서 롤백될 수 있는 `RVOOS_DELETE` 를 남기지만, 그 트랜잭션이 끝날 때까지 다른 트랜잭션이 같은 OOS 파일에 insert 할 수 없어 이 결함으로 이어지지 않는다. 이 판단은 두 전제에 기댄다. 컬럼 타입 변경이 `SCH_M_LOCK` 을 트랜잭션 끝까지 쥔다는 것과, MVCC 클래스의 in-place UPDATE 가 이 경로뿐이라는 것이다. MVCC 클래스에 다른 in-place UPDATE 가 생기면 다시 확인해야 한다.

따라서 현실적인 경로는 1, 2 의 오류 시 abort 와, 같은 sysop 이 끝나기 전에 서버가 죽어 restart recovery 가 그 sysop 을 되돌리는 경우다.

**PR 리뷰어가 든 발생 경로.** 2026-10-27 PR #7990 리뷰어(shparkcubrid)가 review 5662427700 의 인라인 코멘트 https://github.com/CUBRID/cubrid/pull/7990#discussion_r4385247875 에서 이 결함을 블로킹으로 지적했다. 리뷰어는 코드로만 확인했다고 적었다. 리뷰어가 든 경로와 이 이슈의 판단은 다음과 같다.

| 리뷰어가 든 경로 | 이 이슈의 대응 | 판단 | 근거 |
|---|---|---|---|
| vacuum sysop 의 중간 abort(shutdown 인터럽트, I/O 오류) | 호출자 1, 2 | 해당한다. 주된 경로다 | `vacuum_oos.cpp:207`, `vacuum.c:2567`, `:2627` 의 `log_sysop_abort`. sysop abort 형태는 SERVER_MODE gtest 로 재현했다(Repro 의 둘째 케이스) |
| vacuum sysop 도중 서버 장애 후 복구 undo | 호출자 1, 2 | 해당한다(소스 분석, 실행하지 않음) | restart recovery 의 undo 단계는 system worker transaction 의 끝나지 않은 변경도 되돌리므로(`log_recovery.c:6690-6691`) 같은 `RVOOS_DELETE` undo 가 실행된다. 다른 트랜잭션의 insert 가 장애 전에 commit 되어 있어야 한다. 사용자 트랜잭션 D 가 남은 상태의 restart recovery assert 는 Actual Result 에서 관찰했다 |
| SA 모드의 즉시 삭제 | 호출자 3 | 해당하지 않는다 | 트랜잭션이 하나뿐이고, 같은 트랜잭션의 이후 insert 는 rollback 에서 먼저 취소된다(LIFO, Repro 의 대조군) |
| in-place update 의 즉시 삭제 | 호출자 3 | 해당하지 않는다(소스 분석, 실행하지 않음) | 위 "in-place UPDATE 경로". 컬럼 타입 변경이 `SCH_M_LOCK` 을 트랜잭션 끝까지 쥐고, OOS 파일은 heap 마다 따로라서 다른 트랜잭션이 그 OOS 파일에 insert 할 수 없다 |

리뷰어가 제안한 두 방향, 즉 heap 처럼 `ANCHORED_DONT_REUSE_SLOTS` 를 쓰는 방향과 삭제 트랜잭션이 끝날 때까지 공간을 예약하는 방향은 Options for Analysis 의 둘째 후보에 해당한다. 공간 예약만으로 부족한 이유는 "왜 해결해야 하는가" 에 적었다.

### 왜 문제인가

OOS 는 큰 가변 컬럼 값을 heap 밖에 저장하므로, 사용자는 commit 한 값이 다른 세션의 작업이나 서버 재시작 이후에도 그대로 읽히기를 기대한다. 이 결함이 발생하면 다음과 같은 결과가 생긴다.

- **commit 된 데이터 손상 (release 빌드)**: vacuum sysop abort 의 undo 가 다른 트랜잭션이 commit 한 chunk 의 슬롯 디렉터리 항목을 덮어쓴다. 그 값을 가진 행을 읽으면 identity stamp 불일치로 `ER_HEAP_OOS_CORRUPTED_RECORD` 가 나거나, 공간 계산이 어긋난다. 덮어쓰기 자체는 오류 없이 일어나므로, 사용자는 나중에 그 값을 읽을 때에야 commit 한 값을 잃었음을 알게 된다. 이 결과는 소스 분석(`spage_insert_for_recovery` 의 release 경로)에서 도출했고, release 빌드 실행으로는 확인하지 않았다.
- **서버 종료와 재시작 불가 (debug 빌드)**: undo 가 assert 로 서버를 종료한다. 충돌 상태가 남은 채 죽으면 restart recovery 가 같은 undo 를 다시 수행해 assert 가 반복되므로 DB 가 boot 되지 않는다(단위 테스트 중 관찰).
- **발생 조건이 드물어 진단이 어렵다**: vacuum 오류(I/O 오류, interrupt, 손상된 non-head chunk)나 vacuum sysop 도중의 서버 장애가 동시 insert 와 겹쳐야 하므로, 현장에서 재현하거나 원인을 특정하기 어렵다.

빈도와 실제 현장 발생 여부는 확인하지 않았다. vacuum 오류가 얼마나 자주 abort 로 이어지는지는 ANALYSIS 에서 확인할 사항이다.

### 왜 해결해야 하는가

- OOS 사양(OOS-CONTEXT §4)은 "chunk 삭제는 로그를 남겨, 삭제 도중 실패나 복구 시 해당 원자 작업을 되돌리거나 재수행한다"고 요구한다. 지금 구현은 되돌리는 경로가 다른 트랜잭션의 commit 된 데이터를 손상시킬 수 있어 이 요구를 충족하지 못한다.
- 같은 사양의 LSA reclaim gate 는 "아직 undo 대상일 수 있는 빈 페이지는 dealloc 하지 않는다"는 원칙으로 페이지 해제만 막는다. 슬롯과 공간 재사용은 막지 않으므로 이 결함을 다루지 않는다.
- 우회책이 없다. 사용자는 vacuum 오류나 서버 장애 시점과 동시 insert 를 통제할 수 없다.
- `SAFEGUARD_RVSPACE` 만 켜는 방안은 해결이 아니다. 바이트만 예약하고 슬롯 id 는 예약하지 않으며, `spage_save_space` 는 vacuum worker 를 예약에서 제외하고 sysop 안이면 debug assert 를 건다(`slotted_page.c:506-511`).
- CBRD-27237(rollback 된 UPDATE 의 옛 체인을 vacuum 이 삭제)과는 다른 결함이다. CBRD-27237 은 삭제 근거가 잘못된 문제이고, 이 이슈는 정당한 삭제의 undo 가 재사용된 슬롯과 충돌하는 문제다. CBRD-27237 을 해결해도 REMOVE 경로와 알림 기반 정리는 여전히 sysop 안에서 삭제하므로 이 결함은 남는다.

PR #7990 에서는 이 결함을 별도 이슈로 분리하기로 결정했다(2026-10-27). 같은 날 PR #7990 리뷰어도 이 결함을 블로킹으로 지적했다("무엇이 문제인가" 의 리뷰어 경로 표 참조).

## Test Build

- 분석 기준 엔진 소스: 최초 판은 `feature/oos-merge` @ `5a70787feea9e0488222af7e3a0249cc431562ca` 이다. 이번 판의 in-place UPDATE 분석, 호출자 줄 번호, 리뷰어 경로 판단은 PR #7990 head `dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67` 기준이다. `5a70787fe` 이후 `dcbf09e4f` 까지의 엔진 변경은 저장 포맷 boot 검사와 `PAGE_TYPE` 순서 조정(`disk_manager.*`, `boot_sr.c`, `page_buffer.c`, `storage_common.h`, `perf_monitor.h`, `error_code.h`)뿐이다. 이 이슈가 인용한 파일(`oos_file.*`, `heap_oos.cpp`, `heap_file.*`, `slotted_page.c`, `vacuum.c`, `vacuum_oos.cpp`, `execute_schema.c`, `locator_sr.c`, `lock_manager.c`, `log_recovery.c`, `csql_grammar.y`)에 대한 `git diff 5a70787fe dcbf09e4f` 는 비어 있다.
- 실행한 소스: `224104a36a37d42847ed0852f312cca9be31e431` 에 아래 Repro 의 회귀 테스트 패치를 적용했다. `5a70787fe` 이후의 `224104a36` 은 `unit_tests/oos` 의 CMake 설정과 DB fixture 스크립트만 바꾸었으므로, 실행한 엔진 소스는 `5a70787fe` 와 같다. `dcbf09e4f` 에서는 다시 실행하지 않았다.
- 빌드: CUBRID 11.5.0 (11.5.0.2776) 64-bit debug 빌드, GCC, `CMAKE_BUILD_TYPE=Debug`, `UNIT_TEST_OOS=ON`, Linux x86_64 (RHEL 9 계열, kernel 5.14).
- 출시 버전(11.4 이하)은 OOS 가 없어 해당하지 않는다. 11.5 는 미출시다.

## Repro

SERVER_MODE gtest 로 재현했다. 트랜잭션 2 개를 한 스레드에서 tran index 를 바꿔 가며 실행한다.

1. 이 절 끝의 "회귀 테스트 패치" 를 `p1a-regression-tests.patch` 로 저장하고, CUBRID 소스 루트에서 `git apply p1a-regression-tests.patch` 로 적용해 회귀 테스트 3 개를 `unit_tests/oos/test_oos_delete_server.cpp` 에 추가한다. 이 파일은 `5a70787fe` 부터 `dcbf09e4f` 까지 같으므로 패치가 그대로 적용된다(`dcbf09e4f` 에서 `git apply --check` 로 확인).
   - `OtherTransactionCannotTakeSpaceOfUncommittedDelete`: 트랜잭션 D 가 commit 된 단일 chunk(페이지 하나를 채우는 크기)를 삭제하고 끝나지 않은 상태에서, 트랜잭션 W 가 같은 크기 값을 insert 후 commit 한다. W 의 chunk 가 D 의 페이지에 들어갔는지 검사한 뒤 D 를 abort 하고, 두 값을 identity stamp 로 다시 읽는다.
   - `OtherTransactionCannotTakeSpaceOfUnfinishedSysopDelete`: 위와 같되 D 의 삭제가 열린 sysop 안에 있고 `log_sysop_abort` 로 되돌린다(vacuum abort 형태).
   - `DeleterReusesItsOwnFreedSpaceAndRollsBack`: D 자신이 비운 슬롯에 insert 한 뒤 abort 해도 안전함을 확인하는 대조군.
2. 빌드 후 실행한다.

```sh
# CUBRID(설치 위치), CUBRID_DATABASES 를 설정하고 $CUBRID/bin 을 PATH 에 넣은 뒤 실행한다.
cmake --preset debug -DUNIT_TEST_OOS=ON
cmake --build build_preset_debug
cmake --install build_preset_debug
ctest --test-dir build_preset_debug -R '^test_oos_delete_server$' --output-on-failure
```

`test_oos_delete_server` 는 CTest fixture `OOS_DB`(`unit_tests/oos/scripts/setup_unittestdb.sh`)가 만드는 `unittestdb` 를 쓴다. `CUBRID`, `CUBRID_DATABASES`, `PATH` 는 configure 시점의 환경이 CTest 에 기록되므로 configure 전에 설정한다. `debug` preset 은 `CMAKE_INSTALL_PREFIX` 를 `$CUBRID` 로 둔다. 이 테스트의 `main` 은 GoogleTest `break_on_failure` 를 켜므로, 첫 실패에서 프로세스가 SIGTRAP 으로 끝나고(셸 종료 코드 133) 뒤의 케이스는 실행되지 않는다.

케이스별로 따로 보려면 케이스마다 fixture 스크립트로 `unittestdb` 를 새로 만들고, 실행한 뒤 지운다. 실패한 케이스가 남긴 DB 는 다음 boot 의 recovery 에서 assert 가 나기 때문이다. 시작 전에 같은 이름의 `unittestdb` 가 없어야 한다. 있으면 setup 스크립트가 새로 만들지 않고 그 DB 를 쓴다.

```sh
# CUBRID 소스 루트에서, 위와 같은 환경으로 실행한다.
for c in OtherTransactionCannotTakeSpaceOfUncommittedDelete \
         OtherTransactionCannotTakeSpaceOfUnfinishedSysopDelete \
         DeleterReusesItsOwnFreedSpaceAndRollsBack; do
  bash unit_tests/oos/scripts/setup_unittestdb.sh
  build_preset_debug/bin/test_oos_delete_server --gtest_filter="OosDeleteServerTest.$c" </dev/null
  echo "case=$c rc=$?"
  bash unit_tests/oos/scripts/cleanup_unittestdb.sh
done
```

### 회귀 테스트 패치

`feature/oos-merge` 의 `5a70787fe` 부터 `dcbf09e4f` 까지 적용된다. 수정 전에는 앞의 두 케이스가 실패하므로 PR #7990 에는 커밋하지 않았다.

```diff
diff --git a/unit_tests/oos/test_oos_delete_server.cpp b/unit_tests/oos/test_oos_delete_server.cpp
index 62c6ce764..d63ca9b70 100644
--- a/unit_tests/oos/test_oos_delete_server.cpp
+++ b/unit_tests/oos/test_oos_delete_server.cpp
@@ -24,6 +24,9 @@
  */
 
 #include "test_oos_server_common.hpp"
+#include "xserver_interface.h"
+
+#include <string>
 
 // XXX: SHOULD BE THE LAST INCLUDE HEADER
 #include "memory_wrapper.hpp"
@@ -470,6 +473,120 @@ TEST (OosDeleteServerTest, OosDeleteStaleReferenceAfterSlotReuseKeepsLiveChain)
   recdes_free_data_area (&rec_out);
 }
 
+// ============================================================================
+// TC: a delete that can still roll back keeps its slot and its space
+//
+// The undo of an OOS chunk delete puts the chunk back into the same slot, which its chain and the
+// heap stub still name. Until the deleter ends, another transaction must not insert into that slot
+// or into the space the delete freed. Vacuum deletes in a system operation, and the SA/non-MVCC
+// eager cleanup deletes inside the user transaction, so both can roll back while others insert.
+// ============================================================================
+
+/* Reads the chain through its reference, so a slot now holding another chunk fails the stamp check. */
+static void
+expect_chain_holds (const oos_chain_ref &ref, const std::string &expected)
+{
+  std::string value (expected.size () + 1, '\0');
+  ASSERT_EQ (oos_read (thread_p, ref, oos_buffer (&value[0], value.size ())), NO_ERROR);
+  EXPECT_STREQ (value.c_str (), expected.c_str ());
+}
+
+static void
+insert_by_other_transaction_during_pending_delete (bool delete_in_sysop)
+{
+  const int worker_idx = LOG_FIND_THREAD_TRAN_INDEX (thread_p);
+
+  VFID oos_vfid;
+  ASSERT_EQ (oos_create_file (thread_p, oos_vfid), NO_ERROR);
+
+  /* Single chunks that each fill a page: the page of the deleted chunk has room for one of them. */
+  const int value_size = bridge_oos_get_max_chunk_size_within_page () - 1;
+  std::string deleted_value (value_size, 'd');
+  std::string inserted_value (value_size, 'i');
+
+  oos_chain_ref deleted;
+  ASSERT_EQ (oos_insert (thread_p, oos_vfid, oos_buffer (&deleted_value[0], deleted_value.size () + 1),
+			 deleted.head_oid, &deleted.identity_stamp), NO_ERROR);
+  ASSERT_EQ (xtran_server_commit (thread_p, false), TRAN_UNACTIVE_COMMITTED);
+
+  TRAN_STATE deleter_state;
+  const int deleter_idx = logtb_assign_tran_index (thread_p, NULL_TRANID, TRAN_ACTIVE, NULL, &deleter_state,
+			  TRAN_LOCK_INFINITE_WAIT, TRAN_READ_COMMITTED);
+  ASSERT_NE (deleter_idx, NULL_TRAN_INDEX);
+  if (delete_in_sysop)
+    {
+      log_sysop_start (thread_p);
+    }
+  ASSERT_EQ (oos_delete (thread_p, oos_vfid, deleted), NO_ERROR);
+
+  LOG_SET_CURRENT_TRAN_INDEX (thread_p, worker_idx);
+  oos_chain_ref inserted;
+  ASSERT_EQ (oos_insert (thread_p, oos_vfid, oos_buffer (&inserted_value[0], inserted_value.size () + 1),
+			 inserted.head_oid, &inserted.identity_stamp), NO_ERROR);
+  ASSERT_EQ (xtran_server_commit (thread_p, false), TRAN_UNACTIVE_COMMITTED);
+  /* Rolling the delete back now would put the chunk into the slot or space the insert took. */
+  ASSERT_FALSE (deleted.head_oid.volid == inserted.head_oid.volid
+		&& deleted.head_oid.pageid == inserted.head_oid.pageid)
+      << "another transaction inserted into the page of a delete that can still roll back";
+
+  LOG_SET_CURRENT_TRAN_INDEX (thread_p, deleter_idx);
+  if (delete_in_sysop)
+    {
+      log_sysop_abort (thread_p);
+    }
+  (void) log_abort (thread_p, deleter_idx);
+  logtb_release_tran_index (thread_p, deleter_idx);
+  LOG_SET_CURRENT_TRAN_INDEX (thread_p, worker_idx);
+
+  expect_chain_holds (deleted, deleted_value);
+  expect_chain_holds (inserted, inserted_value);
+}
+
+TEST (OosDeleteServerTest, OtherTransactionCannotTakeSpaceOfUncommittedDelete)
+{
+  insert_by_other_transaction_during_pending_delete (false);
+}
+
+TEST (OosDeleteServerTest, OtherTransactionCannotTakeSpaceOfUnfinishedSysopDelete)
+{
+  insert_by_other_transaction_during_pending_delete (true);
+}
+
+/* The deleter itself may reuse what it freed: its rollback undoes the insert before the delete. */
+TEST (OosDeleteServerTest, DeleterReusesItsOwnFreedSpaceAndRollsBack)
+{
+  const int worker_idx = LOG_FIND_THREAD_TRAN_INDEX (thread_p);
+
+  VFID oos_vfid;
+  ASSERT_EQ (oos_create_file (thread_p, oos_vfid), NO_ERROR);
+
+  const int value_size = bridge_oos_get_max_chunk_size_within_page () - 1;
+  std::string deleted_value (value_size, 'd');
+  std::string inserted_value (value_size, 'i');
+
+  oos_chain_ref deleted;
+  ASSERT_EQ (oos_insert (thread_p, oos_vfid, oos_buffer (&deleted_value[0], deleted_value.size () + 1),
+			 deleted.head_oid, &deleted.identity_stamp), NO_ERROR);
+  ASSERT_EQ (xtran_server_commit (thread_p, false), TRAN_UNACTIVE_COMMITTED);
+
+  TRAN_STATE deleter_state;
+  const int deleter_idx = logtb_assign_tran_index (thread_p, NULL_TRANID, TRAN_ACTIVE, NULL, &deleter_state,
+			  TRAN_LOCK_INFINITE_WAIT, TRAN_READ_COMMITTED);
+  ASSERT_NE (deleter_idx, NULL_TRAN_INDEX);
+  ASSERT_EQ (oos_delete (thread_p, oos_vfid, deleted), NO_ERROR);
+
+  oos_chain_ref inserted;
+  ASSERT_EQ (oos_insert (thread_p, oos_vfid, oos_buffer (&inserted_value[0], inserted_value.size () + 1),
+			 inserted.head_oid, &inserted.identity_stamp), NO_ERROR);
+  EXPECT_TRUE (OID_EQ (&inserted.head_oid, &deleted.head_oid)) << "the deleter did not reuse its freed slot";
+
+  (void) log_abort (thread_p, deleter_idx);
+  logtb_release_tran_index (thread_p, deleter_idx);
+  LOG_SET_CURRENT_TRAN_INDEX (thread_p, worker_idx);
+
+  expect_chain_holds (deleted, deleted_value);
+}
+
 int
 main (int argc, char **argv)
 {
```

## Expected Result

- 다른 트랜잭션의 insert 는 끝나지 않은 삭제가 있는 페이지의 슬롯이나 공간을 쓰지 않는다.
- D 의 abort 뒤 삭제된 chunk 가 원래 OID 와 identity stamp 로 복원되고, W 가 commit 한 chunk 도 그대로 읽힌다.
- 대조군은 계속 통과한다.

## Actual Result

Test Build 의 실행 소스(엔진은 `5a70787fe` 와 같음)에서 케이스마다 새 `unittestdb` 로 실행한 결과:

| 케이스 | 결과 |
|---|---|
| `OtherTransactionCannotTakeSpaceOfUncommittedDelete` | 실패: W 의 chunk 가 D 가 지운 chunk 와 같은 페이지에 들어감 |
| `OtherTransactionCannotTakeSpaceOfUnfinishedSysopDelete` | 실패: 같은 현상 |
| `DeleterReusesItsOwnFreedSpaceAndRollsBack` | 통과 |

두 실패 케이스의 출력은 같다.

```
<소스 루트>/unit_tests/oos/test_oos_delete_server.cpp:528: Failure
Value of: deleted.head_oid.volid == inserted.head_oid.volid && deleted.head_oid.pageid == inserted.head_oid.pageid
  Actual: true
Expected: false
another transaction inserted into the page of a delete that can still roll back
```

테스트는 페이지 일치를 검사한다. W 의 chunk 가 D 가 비운 슬롯까지 차지했다는 점은 아래 restart recovery assert(복원할 슬롯이 비어 있다는 가정이 깨짐)로 확인했다.

첫 시도에서 DB 를 케이스 간 공유했을 때, 첫 케이스가 D 가 살아있는 상태로 종료된 뒤 다음 프로세스의 boot 가 restart recovery 중 다음 assert 로 종료되었다.

```
slotted_page.c:1969: int spage_insert_for_recovery(THREAD_ENTRY*, PAGE_PTR, PGSLOTID, RECDES*):
Assertion `slot_p->offset_to_record == SPAGE_EMPTY_OFFSET' failed.
```

## Additional Information

- 발견 경위: PR #7990 Greptile 리뷰 https://github.com/CUBRID/cubrid/pull/7990#discussion_r4380243533
- 리뷰어 지적: PR #7990 review 5662427700(shparkcubrid, CHANGES_REQUESTED, 2026-10-27, 대상 commit `4408135c0`)의 인라인 코멘트 https://github.com/CUBRID/cubrid/pull/7990#discussion_r4385247875 에서 지적했다. 리뷰어는 Greptile 지적이 맞다고 보고, 코드로만 확인한 블로킹 항목으로 적었다. 리뷰어가 든 발생 경로 중 SA 모드와 in-place update 는 이 판에서 해당하지 않는다고 판단했고, in-place update 경로는 이 판에서 처음 분석했다("무엇이 문제인가" 참조).
- 분리 경위: PR #7990 작성자의 결정으로 이 결함을 PR #7990 범위에서 분리해 이 이슈에서 다룬다(2026-10-27). PR #7990 에는 엔진 변경을 넣지 않았고, 회귀 테스트는 Repro 의 패치로 남겼다.
- 상위 이슈: CBRD-26978 (OOS TODO 추적)
- SQL 수준 재현 시도: `db_serial` comment 로 eager 경로를 SERVER_MODE 에서 일으키려 했으나, comment 1024 바이트 제한으로 OOS 대상이 될 수 없음을 확인했다. vacuum 오류 경로를 SQL 로 결정적으로 일으키는 방법은 아직 없다(오류 주입 필요).
- 관련 이슈: CBRD-27237 (다른 결함, 위 설명 참조), CBRD-26786 (LSA reclaim gate), CBRD-26950 (identity stamp 와 슬롯 재사용 전제).

## Options for Analysis

아래는 ANALYSIS 에서 비교할 후보이며, 선택된 설계가 아니다.

| 후보 방안 | 기대 효과와 장점 | 한계·단점과 실패 조건 | 비용·위험·호환성 | 근거와 ANALYSIS 확인 사항 |
|---|---|---|---|---|
| 끝나지 않은 삭제가 있는 페이지를 insert 후보에서 제외하는 메모리 guard (`VPID -> {삭제 주체 trid, 삭제 LSA}`) | 슬롯과 공간을 함께 보호한다. 세 호출자를 한 곳에서 다룬다. 디스크와 로그 포맷이 그대로다 | 삭제 주체가 끝날 때까지 그 페이지의 빈 공간을 다른 트랜잭션이 못 쓴다. system tdes 는 trid 가 worker 마다 고정이라 바깥 sysop 종료를 head LSA 로 판정해야 한다 | `oos_file.cpp` 내부 변경. insert 경로에 맵 조회가 추가된다. 맵 정리 정책이 필요하다 | 삭제 주체 본인의 재사용 허용 조건(sysop 밖), 맵 크기 상한, 성능 영향 측정 |
| `SAFEGUARD_RVSPACE` + 슬롯 재사용 금지(`ANCHORED_DONT_REUSE_SLOTS`) | heap 과 같은 기존 장치를 쓴다 | vacuum worker 는 공간 예약에서 제외된다. 막은 슬롯을 다시 여는 단계가 OOS 에는 없어 슬롯 디렉터리가 자란다. 슬롯 재사용을 전제로 한 CBRD-26950 과 어긋난다 | 페이지 초기화와 vacuum 경로 변경, 기존 DB 와 동작 차이 | 슬롯 회수 단계를 새로 만들 비용 |
| 삭제를 commit 시점 postpone 으로 미뤄 undo 자체를 없앰 | 근본적으로 undo 충돌이 사라진다 | 로그/복구/vacuum retry 의미가 바뀐다. postpone 실행 중 오류 처리와 부분 실행 복구가 필요하다 | 새 recovery index, 사양 개정 | 기존 postpone 기반 파일 해제와의 일관성, 크래시 중 부분 실행 처리 |

첫 후보는 변경 범위가 가장 작고 세 경로를 모두 덮지만, 보호 기간 동안 공간 재사용이 늦어지는 비용이 있다. 두 번째는 기존 장치를 재사용하지만 vacuum 경로를 보호하지 못해 단독으로는 부족하다. 세 번째는 가장 근본적이지만 이 결함에 비해 변경 범위가 크다. 선택은 vacuum 오류 빈도, insert 경로 비용 측정, 사양 개정 범위를 근거로 ANALYSIS 에서 결정한다.

## Triage Request

이 결함을 확인하고 OOS 담당(PR #7990 작성자 측)에 ANALYSIS 배정을 요청한다. ANALYSIS 에서 확인할 사항:

- vacuum 의 OOS 삭제 sysop 이 실제로 abort 되는 오류 경로와 그 빈도, 오류 주입으로 결정적 재현을 만들 수 있는지. vacuum sysop 도중 서버 장애 후 복구 undo 경로도 소스 분석만 했으므로 함께 재현한다.
- `db_ha_apply_info` 등 MVCC 비활성 클래스의 eager 경로가 SERVER_MODE 에서 실제로 OOS 대상이 될 수 있는지에 대한 최종 확인.
- in-place UPDATE 경로 판단의 두 전제(컬럼 타입 변경이 `SCH_M_LOCK` 을 트랜잭션 끝까지 쥔다, MVCC 클래스의 in-place UPDATE 는 이 경로뿐이다)의 확인. 해결 방안이 이 경로까지 덮을지, 아니면 전제를 사양과 `heap_oos_delete_unreferenced` 주석(`heap_oos.cpp:920-922`)에 적을지 정한다.
- 위 후보의 비교와 선택, 그리고 OOS-CONTEXT §4 에 추가할 요구사항.
