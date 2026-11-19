# [OOS][SERIAL] serial 행 keep-form의 OOS stub 유지 분기와 DDL 병합 분기를 자동 테스트로 검증한다

**한 줄 요약**: PR #8514(CBRD-28073) 리뷰에서 새 serial 테스트 8개가 모두 inline comment로 시작해 keep-form의 OOS stub 유지 분기와 DDL 병합 분기를 한 번도 실행하지 않는다는 지적(리뷰 F5, V3-1)이 나왔다. 이 Sub-task는 두 분기가 깨지면 실패하는 자동 테스트를 만든다. PR 작성자는 이 작업을 PR #8514 범위에서 빼서 후속으로 미루었다.

## Issue Triage

**이슈 수행 목적**: `_db_serial` 행을 다시 쓸 때 저장 형태를 유지하는 keep-form의 두 분기를 자동 테스트로 검증한다. 하나는 이미 OOS에 있는 comment의 24바이트 stub을 그대로 쓰는 분기이고, 다른 하나는 DDL이 쓰는 행에 page의 `current_val`/`started`를 합치는 분기다. 이 분기가 깨지면 CI가 실패해야 한다.

**이슈 수행 이유**: CBRD-28073의 테스트 8개(`unit_tests/oos/sql/test_oos_sql_serial*.cpp`)는 inline comment에서 시작한다. PR #8514를 적용한 빌드로 만든 DB에서는 SQL로 OOS `_db_serial` 행을 만들 수 없다. 그래서 두 분기는 리뷰어가 손으로 돌린 시험에서만 실행되었다. OOS 행은 이전 빌드로 만든 DB에서 가져왔고, 병합 분기는 gdb로 조건을 강제했다. 리뷰에서 확인한 `feature/oos-merge` 재병합 실수가 실제 예다. stub 복사 필드(`reused_stub`)를 채우지 않으면 `_db_serial` 행에 OID가 0인 stub이 쓰인다. 소스상 이 실수는 8개 테스트를 모두 통과한다(실행하지는 않았다).

**영향**: OOS 저장 코드를 바꾸는 개발자와 리뷰어가 영향을 받는다. 이 분기가 깨진 채 병합되면 이전 OOS 빌드에서 넘어온 DB에서 문제가 생긴다. NEXT VALUE 한 번에 serial comment를 읽을 수 없게 되고 OOS chain은 고아가 된다. DDL 병합 분기에서는 serial 행이 OOS 상태를 다시 얻어 HA 복제가 멈출 수 있다. 현재 코드는 수동 시험에서 정상 동작했으므로, 이 이슈는 결함이 아니라 회귀 감지 수단이 없는 문제다. 영향받는 DB는 미출시 `feature/oos-merge` 빌드가 만든 개발 DB로 한정된다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

### 검증 대상

PR #8514(head `8e9d71fda07687ca5c5c28af92d869658a527dec`, base `feature/oos-merge` `8c478d8559`, 아직 병합 전)는 `heap_attrinfo_transform_to_disk_keep_form`을 추가했다. 이 함수는 바꾸지 않은 열의 저장 형태를 기존 레코드대로 유지한다. inline 열은 inline으로 두고, OOS 열은 기존 stub을 그대로 쓰며 OOS에는 아무것도 쓰지 않는다. 호출하는 곳은 두 군데다.

| 분기 | 코드(head `8e9d71fda0`) | 지켜야 할 결과 |
|---|---|---|
| OOS stub 유지 | `serial_update_serial_object`(NEXT VALUE, serial cache 값 기록) → `heap_attrinfo_keep_column_form`(`heap_file.c:14170-14220`): 기존 stub을 `heap_oos_parse_inline_ref`로 검증한 뒤 `plan.reused_stub`에 그대로 복사한다. 크기 계산은 `OR_OOS_INLINE_SIZE`(24바이트)를 더하고, writer는 `reused_stub`을 그대로 쓴다(`heap_file.c:15180`). | NEXT VALUE를 commit하거나 rollback해도, cache 값을 기록해도 stub 24바이트가 바이트 단위로 같다. OOS 레코드 수가 그대로이고 comment를 읽을 수 있다. |
| DDL 병합 | `serial_row_write_keep_value`(`serial.c:2228-2290`): DDL이 쓰는 행의 `current_val`/`started`가 page 값과 다를 때만 page 값을 합친 행을 keep-form으로 만든다(`serial.c:2287`). | 합친 행은 inline이며(HAS_OOS 플래그 없음) page의 `current_val`/`started`를 유지한다. OOS chain을 새로 만들지 않는다. |

keep-form이 아니면 serial 경로는 OOS 배치를 다시 결정한다. 그러면 redo 전용 로그 아래에서 새 OOS chain이 생겨 CBRD-28035(chain 누수)와 CBRD-28052(SA 롤백 뒤 손상)가 다시 나타난다.

### 현재 테스트가 두 분기에 닿지 않는 이유

- `test_oos_sql_serial`(3개)과 `test_oos_sql_serial_rollback`(5개)은 inline comment를 가진 serial에서 시작한다. `NextValueWritesNoCommentChain`은 새 chain이 생기지 않는지를 본다. 실행 시작 시점에 OOS 레코드가 0개라서, `heap_attrinfo_keep_column_form`은 모든 열에서 첫 검사(`heap_recdes_contains_oos`)를 통과하지 못하고 바로 돌아간다(리뷰 V3 probe).
- PR #8514를 적용한 빌드로 만든 DB에서는 OOS `_db_serial` 행을 만들 길이 없다.
  - 시스템 클래스 행은 클라이언트에서 OOS로 바꾸지 않는다(`locator_finalize_oos_record`).
  - `UPDATE _db_serial`은 권한 오류로 거부된다.
  - NEXT VALUE와 DDL 병합은 이제 keep-form이라 OOS로 내보내지 않는다.
  - 남는 방법은 이전 OOS 빌드(예: `71993ddb63`)로 만든 DB를 여는 것뿐이다.
- DDL 병합 분기는 ALTER SERIAL의 행 쓰기와 동시 NEXT VALUE가 좁은 구간에서 겹쳐야 실행된다. 리뷰 V1의 CS 모드 시험에서 ALTER 660회 동안 0번 실행되었다. 수정 전 HA 시험(R1)에서는 5회 중 1회 실행되었다. 단일 세션에서는 클라이언트가 다음 질의 전에 ALTER를 먼저 flush하므로 실행되지 않는다. `RolledBackAlterAndNextValueRestoreTheCommittedRow`도 이 분기에 들어가지 않는다(V3 probe).

### 수동 검증 결과 (회귀 테스트가 지켜야 할 기준)

리뷰 V1이 `71993ddb63` optdebug 빌드로 만든 4K DB를 PR head 빌드로 열어 확인했다(level 5, SA 모드).

- OOS comment를 가진 serial 5개에 NEXT VALUE를 12회씩 실행했다. rollback과 commit을 섞었고 cache serial은 cache 블록을 넘겼다. 실행 전후 OOS 레코드는 6개로 같았다. stub 5개의 24바이트도 바이트 단위로 같았다. comment MD5가 원본과 같았고 `checkdb`는 0으로 끝났다.
- gdb로 병합 조건(`cmp_result`)을 강제했을 때 ALTER한 행은 inline이 되었다. 이전 chain은 commit 때 회수되었고 rollback하면 stub과 chain이 원래대로 돌아왔다.
- 리뷰 V3도 같은 두 분기를 gdb로 실행해 정상 동작을 확인했다.

자세한 절차와 stub 바이트는 리뷰 보고서와 그 Addendum에 있다.

### 테스트가 잡아야 할 회귀의 예

`feature/oos-merge`에 CBRD-27230(`b43275e944`)이 들어오면서 같은 함수들이 바뀌었다. 리뷰 F1에서 다음 두 가지 잘못된 재병합을 확인했다.

- 단순히 충돌만 해결하면 keep-form 호출의 `true`가 다른 bool 매개변수(`reuse_oos_stubs`)에 묶인다. 이 경우 keep-form이 꺼지고 테스트 8개 중 5개가 실패한다. R4가 실제로 병합하고 빌드해 확인했으므로 현재 테스트로 잡힌다.
- 호출부만 고치고 `heap_attrinfo_keep_column_form`이 `reused_stub`을 채우지 않으면 writer는 0으로 초기화된 stub을 복사한다. 그러면 OID가 0인 stub이 `_db_serial` 행에 쓰이고, 이전 빌드에서 온 OOS 행은 첫 NEXT VALUE에서 comment를 읽을 수 없게 된다. 테스트가 이 분기에 들어가지 않으므로 소스상 8개를 모두 통과한다. 실행하지는 않았고 근거는 R4의 소스 판독이다.

### Definition of done

- OOS stub 유지 분기: 테스트가 OOS stub을 가진 `_db_serial` 행에서 시작한다. NEXT VALUE commit, NEXT VALUE rollback, serial cache 값 기록 뒤에 stub 24바이트가 같은지, OOS 레코드 수가 같은지, comment를 읽을 수 있는지 확인한다.
- DDL 병합 분기: 테스트가 page 값과 다른 `current_val`/`started`를 가진 DDL 행 쓰기로 병합 분기를 실행한다. 합친 행에 HAS_OOS 플래그가 없는지, page의 `current_val`/`started`가 유지되는지, OOS 레코드가 늘지 않는지 확인한다. 테스트는 분기가 실제로 실행되었다는 것도 보여야 한다.
- 위 두 회귀 예 가운데 `reused_stub`을 채우지 않는 변경을 임시로 넣으면 새 테스트가 실패하는지 한 번 확인한다.
- 새 테스트는 OOS ctest에 등록되어 CI에서 실행된다.

## Options for Analysis

아래는 후보이며 선택은 ANALYSIS에서 한다.

| 후보 방안 | 기대 효과와 장점 | 한계·단점과 실패 조건 | 비용·위험·호환성 | 근거와 ANALYSIS 확인 사항 |
|---|---|---|---|---|
| A. 서버 측 unit test(`CUBRID_UNIT_TEST_ENABLED`)에서 OOS `_db_serial` 레코드를 직접 만든다. `heap_attrinfo_transform_to_disk`(OOS 배치를 결정하는 기본 경로)나 테스트 hook으로 만든 뒤 NEXT VALUE를 실행한다. | 실제 serial 경로(`serial_update_serial_object`)를 그대로 지난다. `unit_tests/oos`에 서버 측 harness(`test_oos_server_common.hpp`, CBRD-27230의 `test_oos_update_reuse_server.cpp`)가 있다. | 시스템 클래스 행을 서버에서 직접 고치는 준비 코드가 필요하다. 준비 과정의 로깅과 page latch가 실제 상태와 다르면 테스트가 실제 경로를 대표하지 못할 수 있다. | 테스트 전용 코드가 늘어난다. 제품 코드는 바꾸지 않거나 `CUBRID_UNIT_TEST_ENABLED` 안의 hook만 추가한다. | 준비한 레코드가 이전 빌드가 만든 행과 같은 형태(repid, HAS_OOS, VOT)인지 확인해야 한다. |
| B. 테스트 전용 fault point로 병합 조건을 강제한다. 예를 들어 `serial_row_write_keep_value`의 비교 결과를 바꾼다. | 좁은 경쟁 구간을 기다리지 않고 DDL 병합 분기를 매번 결정적으로 실행한다. 리뷰 V1과 V3가 gdb로 같은 일을 했다. 이미 `heap_oos_test_fail_*` 같은 hook 관례가 있다. | 강제한 비교 결과는 page 값과 DDL 행이 실제로 다르지 않은 상태라서 합친 행이 DDL 행과 같을 수 있다. 실제로 다른 값을 만들려면 page 값도 조작해야 한다. | 제품 코드에 `#if defined(CUBRID_UNIT_TEST_ENABLED)` 분기가 하나 들어간다. | 합친 행이 page 값을 유지하는지 확인하려면 page와 DDL 행의 값을 실제로 다르게 만드는 방법을 정해야 한다. |
| C. 이전 OOS 빌드로 만든 fixture DB를 쓴다. | 실제로 넘어온 DB와 같은 상태여서 리뷰 V1의 수동 검증을 그대로 자동화한다. | 바이너리 fixture를 저장소나 CI에 두어야 한다. 디스크 형식이 바뀌면 fixture를 다시 만들어야 한다. DDL 병합 분기는 이 방법만으로 실행되지 않는다. | fixture 관리 비용이 생기고 page 크기·버전 의존성이 있다. | CI에 DB fixture를 둘 수 있는지, 형식 변경 때 누가 다시 만드는지 정해야 한다. |
| D. keep-form 함수 단위 테스트를 둔다. 사용자 클래스 레코드에서 `heap_attrinfo_transform_to_disk_keep_form`을 직접 호출해 stub 바이트와 OOS 레코드 수를 비교한다(리뷰 R4 제안). | 시스템 클래스를 다루지 않아 준비가 가장 간단하다. stub 복사 회귀(`reused_stub`)를 직접 잡는다. | serial 호출부, 로깅, rollback, cache 기록 경로를 거치지 않는다. DDL 병합 분기도 실행하지 않는다. | 비용이 가장 작다. | 이것만으로 충분한지, A나 B와 함께 써야 하는지 정해야 한다. |

A는 OOS stub 유지 분기를 실제 serial 경로로 검증하는 데 가장 가깝고, B는 병합 분기를 결정적으로 실행하는 거의 유일한 방법이다. 그래서 두 분기를 모두 다루려면 A·B 조합이나 D·B 조합이 후보가 된다. C는 실제성은 높지만 병합 분기를 다루지 못하고 fixture 관리 비용이 든다. ANALYSIS에서는 A의 준비 코드가 이전 빌드의 행 형태를 재현하는지, B에서 page 값을 어떻게 다르게 만들지를 확인해 고른다.

### 관련 이슈

| 이슈 | 관계 |
|---|---|
| [CBRD-28073](https://jira.cubrid.org/browse/CBRD-28073) | keep-form을 도입한 이슈(PR #8514). 이 Sub-task는 그 PR에서 미룬 테스트를 다룬다. 그 이슈의 [설계 검토 댓글](https://jira.cubrid.org/browse/CBRD-28073?focusedCommentId=4778778#comment-4778778)은 다른 redo 전용 writer가 keep-form 없이 인코더를 부르는 것을 막는 구조적 장치(인코더 분리)를 별도 후속 후보로 적었다. 이 Sub-task는 그 리팩터링을 다루지 않고, 현재 두 분기의 테스트만 다룬다. |
| [CBRD-27230](https://jira.cubrid.org/browse/CBRD-27230) | `reused`/`reused_stub` stub 복사 구조와 서버 측 테스트 harness를 도입했다. keep-form은 이 구조를 쓴다. |
| [CBRD-28035](https://jira.cubrid.org/browse/CBRD-28035), [CBRD-28052](https://jira.cubrid.org/browse/CBRD-28052) | keep-form이 막는 원래 결함. keep-form이 깨지면 다시 나타난다. |

### 참고

- PR #8514 리뷰 보고서의 F1, F5, Addendum: [code-review-pr8514.md](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-28073/code-review-pr8514.md)
- PR: [CUBRID/cubrid#8514](https://github.com/CUBRID/cubrid/pull/8514)
