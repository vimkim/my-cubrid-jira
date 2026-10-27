# [OOS] 삭제를 취소해 데이터를 복원할 자리를 다른 트랜잭션이 먼저 사용함

## Issue Triage

**이슈 수행 목적**: OOS(큰 컬럼 값을 행 밖에 저장하는 기능)의 삭제를 취소하더라도, 삭제했던 값과 다른 트랜잭션이 저장한 값이 모두 보존되도록 한다.

**이슈 수행 이유**: OOS는 삭제가 끝나기 전에 그 자리를 다시 사용할 수 있게 한다. 다른 트랜잭션이 그 자리에 값을 저장하고 commit한 뒤 원래 삭제를 취소하면, 두 값을 같은 자리에 넣으려는 충돌이 생긴다. 서버 모드 단위 테스트에서 이러한 조기 재사용을 확인했다.

**영향**: debug 테스트에서는 재시작 복구 중 내부 검사 실패로 DB를 열지 못했다. release 빌드에서는 다른 트랜잭션이 commit한 값이 손상될 수 있다고 소스 분석으로 판단한다. release 실행 결과와 실제 발생 빈도는 확인하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

> 아래는 기존 이슈와 확인된 근거를 바탕으로 작성한 상세 맥락이다. 이번 문서 작성에서는 테스트를 다시 실행하지 않았으며, 기존 재현 결과와 소스 분석을 구분한다.

## Description

### 무엇이 문제인가

OOS는 큰 값을 여러 데이터 조각(chunk)으로 나누어 별도 파일에 저장한다. 각 조각에는 페이지 안의 자리 번호인 슬롯(slot)이 있다. 행과 다른 조각은 이 번호가 포함된 주소를 기억한다. 따라서 삭제를 취소할 때는 조각을 **원래 슬롯에 복원해야 한다**.

삭제도 도중에 실패할 수 있다. 이때 이미 지운 조각을 복원하는 처리가 undo이다. 현재 구현은 undo에 필요한 슬롯과 공간을 보호하지 않아, 삭제가 확정되기 전에 다른 트랜잭션이 사용할 수 있다.

두 작업 A와 B가 겹치는 예로 보면 다음과 같다.

1. A가 조각 X를 삭제한다. A는 아직 끝나지 않았으므로 삭제를 취소할 수 있다.
2. B가 새 조각 Y를 저장한다. X가 있던 슬롯과 공간을 재사용한다.
3. B가 commit한다. Y는 보존되어야 하는 데이터가 된다.
4. A의 삭제가 실패해 취소된다. undo는 X를 원래 슬롯에 복원하려 한다.
5. 그 슬롯에는 이미 Y가 있어 충돌한다. 복원 처리가 실패하거나 Y를 손상시킬 수 있다.

이 상황이 실제로 생길 수 있는 주된 경로는 vacuum이다. vacuum은 더 이상 필요 없는 옛 데이터를 정리하는 백그라운드 작업이다. OOS 정리는 여러 삭제를 하나의 내부 작업(sysop)으로 묶고, 중간에 오류가 나면 그 작업 전체를 취소한다. 이 취소 전에 다른 트랜잭션이 빈자리를 사용하면 위 충돌 조건이 만들어진다. 내부 작업이 끝나기 전에 서버가 죽어 재시작 복구가 삭제를 취소하는 경로도 같은 위험이 있다. 이 서버 장애 경로는 소스 분석이며, 실제 vacuum 장애를 주입해 재현하지는 않았다.

소스에서 연결되는 핵심은 다음 세 곳이다. 모두 분석 기준 `dcbf09e4f`의 코드이다.

- [OOS 페이지 초기화와 삭제](https://github.com/CUBRID/cubrid/blob/dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67/src/storage/oos_file.cpp#L3174): 삭제한 슬롯을 재사용할 수 있고, 복원에 필요한 공간 예약은 꺼져 있다. 삭제는 `RVOOS_DELETE` 로그를 남긴다.
- [vacuum 내부 작업의 오류 처리](https://github.com/CUBRID/cubrid/blob/dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67/src/query/vacuum_oos.cpp#L172): 도중에 삭제 오류가 나면 `log_sysop_abort`로 앞서 한 삭제도 취소한다.
- [원래 슬롯에 복원하는 함수](https://github.com/CUBRID/cubrid/blob/dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67/src/storage/slotted_page.c#L1964): `spage_insert_for_recovery`는 복원할 슬롯이 비어 있다고 가정한다. 이미 사용 중이면 debug 빌드의 assert(내부 조건 검사)가 실패한다.

### 왜 문제인가

사용자는 B가 commit한 값이 다른 작업의 실패나 서버 재시작 때문에 손상되지 않기를 기대한다. 그러나 이 구현에서는 A의 삭제를 복구하는 과정이 B의 값을 침범할 수 있다. 데이터를 지우는 작업 자체가 정당했더라도, 그 작업을 취소하는 처리가 안전하지 않은 것이다.

debug 빌드에서는 이 충돌이 프로세스 종료로 드러난다. 기존 단위 테스트에서는 충돌 상태가 남은 DB를 다시 열 때도 같은 복원 처리가 실패했다. release 빌드는 해당 assert가 없어 슬롯 정보를 덮어쓸 수 있으며, 나중에 값을 읽을 때 손상 오류가 날 것으로 소스 분석에서 판단한다. release 빌드의 손상 결과는 실행으로 확인하지 않았다.

vacuum 삭제의 실패 또는 서버 장애가 다른 트랜잭션의 저장과 겹쳐야 하므로 발생 조건은 제한적이다. 실제 환경에서 얼마나 자주 생기는지는 측정하지 않았다.

### 왜 해결해야 하는가

삭제를 복구하려다 이미 commit된 다른 데이터를 잃는 상태는 허용할 수 없다. 사용자는 vacuum의 오류 시점이나 동시 저장 시점을 통제하기 어려워 응용에서 피할 수 있는 우회책도 확인되지 않았다.

빈 페이지의 해제를 늦추는 기존 보호만으로는 충분하지 않다. 페이지가 남아 있어도 그 안의 슬롯과 공간을 다른 트랜잭션이 먼저 쓸 수 있기 때문이다. 해결 시에는 슬롯 번호와 데이터 공간을 함께 고려해야 한다.

PR #7990 작성자는 이 문제를 별도 이슈로 분리했으나, 2026-10-27 리뷰어는 머지 차단 사유로 지적했다. 분리 여부와 별개로 안전성을 확인할 필요가 있다.

## Test Build

- 분석 기준: `feature/oos-merge`의 `dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67`. 아래 기존 실행 결과를 이 커밋에서 다시 실행한 것은 아니다.
- 기존 실행: `224104a36a37d42847ed0852f312cca9be31e431`에 회귀 테스트 패치를 적용했다. 기존 분석에 따르면 실행한 엔진 코드는 `5a70787feea9e0488222af7e3a0249cc431562ca`와 같으며, 이 결함 관련 코드는 분석 기준까지 바뀌지 않았다.
- 환경: CUBRID 11.5.0.2776, 64-bit debug, GCC, `CMAKE_BUILD_TYPE=Debug`, `UNIT_TEST_OOS=ON`, Linux x86_64(RHEL 9 계열, kernel 5.14).
- 기존 이슈 작성 당시 OOS는 미출시 기능이었다. 출시 버전 11.4 이하는 OOS가 없어 해당하지 않는다.

## Repro

기존 재현은 서버 모드 gtest에서 두 트랜잭션을 번갈아 실행한 것이다. 실제 vacuum의 오류를 SQL로 일으킨 재현은 아직 없다.

1. [기존 상세 기록의 회귀 테스트 패치](https://github.com/vimkim/my-cubrid-jira/blob/b89dc2bd34c15c312bddf9ee91e10a3b3738858c/issues/CBRD-27781-oos-slot-reuse-rollback-undo_dcbf09e_claude.md#회귀-테스트-패치)를 `p1a-regression-tests.patch`로 저장한다. 이 패치는 분석 기준 커밋에 적용 가능하다고 기존 기록에서 확인했다.
2. CUBRID 소스 루트에서 아래 명령을 실행한다. configure 전에 설치 위치 `CUBRID`, 테스트 DB 위치 `CUBRID_DATABASES`, `$CUBRID/bin`이 포함된 `PATH`를 설정한다.

```sh
git apply p1a-regression-tests.patch
cmake --preset debug -DUNIT_TEST_OOS=ON
cmake --build build_preset_debug
cmake --install build_preset_debug
ctest --test-dir build_preset_debug -R '^test_oos_delete_server$' --output-on-failure
```

테스트용 `unittestdb`가 미리 있으면 새로 만들지 않고 그 DB를 사용하므로, 기존 DB가 없는 환경에서 실행한다. 테스트는 첫 실패에서 중단한다. 세 케이스를 각각 확인하려면 케이스마다 테스트 DB를 새로 만들어야 한다. [기존 Repro](https://github.com/vimkim/my-cubrid-jira/blob/b89dc2bd34c15c312bddf9ee91e10a3b3738858c/issues/CBRD-27781-oos-slot-reuse-rollback-undo_dcbf09e_claude.md#repro)에 개별 실행 및 fixture(DB 준비·정리 스크립트) 절차를 보존한다.

## Expected Result

A의 삭제를 취소하면 X가 원래 주소와 식별 정보로 복원되고, B가 commit한 Y도 그대로 읽혀야 한다. 이를 위해 복원에 필요한 슬롯과 공간이 다른 트랜잭션의 저장에 빼앗기지 않아야 한다. A 자신이 빈자리를 재사용한 뒤 취소하는 대조군도 계속 정상 동작해야 한다.

## Actual Result

기존 실행에서 각 케이스에 새 테스트 DB를 사용한 결과이다.

| 테스트 | 결과 |
|---|---|
| `OtherTransactionCannotTakeSpaceOfUncommittedDelete` | 실패: 끝나지 않은 A의 삭제가 비운 페이지에 B가 저장함 |
| `OtherTransactionCannotTakeSpaceOfUnfinishedSysopDelete` | 실패: 삭제를 내부 작업으로 묶은 경우에도 같은 조기 재사용 발생 |
| `DeleterReusesItsOwnFreedSpaceAndRollsBack` | 통과: A 자신이 재사용한 경우는 저장부터 취소한 뒤 삭제를 되돌림 |

앞의 두 테스트는 B가 같은 페이지를 사용한 시점에서 실패해 중단한다. 이 결과와 별도로, 처음에 테스트 간 DB를 공유했을 때는 끝나지 않은 A의 삭제를 재시작 복구가 되돌리다가 아래 검사에서 종료되었다. 이로써 복원할 슬롯까지 이미 사용 중인 상태를 확인했다.

```text
slotted_page.c:1969: spage_insert_for_recovery
Assertion `slot_p->offset_to_record == SPAGE_EMPTY_OFFSET' failed.
```

실제 vacuum 내부 작업을 수행하다 서버를 죽인 결과와 release 빌드의 손상 결과는 미확인이다.

## Additional Information

- 상위 이슈는 [CBRD-26978](https://jira.cubrid.org/browse/CBRD-26978)(OOS TODO 추적)이다. 이 하위 이슈는 삭제 취소 중의 슬롯·공간 충돌을 다룬다.
- [CBRD-27237](https://jira.cubrid.org/browse/CBRD-27237)은 살아있는 데이터를 삭제 대상으로 잘못 고르는 문제이다. 이 이슈는 삭제한 것을 되돌릴 자리가 이미 사용 중인 문제이므로, CBRD-27237을 고쳐도 남는다.
- [Greptile 최초 지적](https://github.com/CUBRID/cubrid/pull/7990#discussion_r4380243533), [리뷰어의 머지 차단 지적](https://github.com/CUBRID/cubrid/pull/7990#discussion_r4385247875). 리뷰어는 코드로 확인했으며 실행 재현은 하지 않았다고 적었다.
- SA_MODE(단독 실행 모드)는 트랜잭션이 하나라 위 A/B 충돌 조건에 해당하지 않는다. 자신의 뒤이은 저장은 삭제보다 먼저 취소된다.
- 사용자 행을 제자리에서 바꾸는 in-place UPDATE도 기존 소스 분석에서는 이 충돌에 해당하지 않는다고 판단했다. 컬럼 타입 변경이 테이블 잠금을 트랜잭션 끝까지 유지해 다른 트랜잭션의 저장을 막는다는 전제이다. 이 경로는 실행하지 않았으며, 경로가 추가되거나 잠금 조건이 달라지면 재검토해야 한다.
- `db_ha_apply_info` 등 일부 시스템 테이블의 즉시 삭제 경로가 실제로 OOS를 사용할 수 있는지는 남은 확인 사항이다. 세부 호출 경로와 해결 후보 비교는 [기존 상세 분석](https://github.com/vimkim/my-cubrid-jira/blob/b89dc2bd34c15c312bddf9ee91e10a3b3738858c/issues/CBRD-27781-oos-slot-reuse-rollback-undo_dcbf09e_claude.md)에 보존한다. 후보는 확정된 설계가 아니다.

## Triage Request

이 결함을 확인하고 OOS 담당(PR #7990 작성자 측)에 ANALYSIS 배정을 요청한다. 분석에서는 다음을 확인한다.

- 실제 vacuum의 중간 오류와 서버 장애 후 복구에서도 충돌하는지, 오류 주입으로 결정적으로 재현할 수 있는지 확인한다.
- release 빌드의 손상 결과와 발생 조건을 확인한다. 실제 발생 빈도는 미상이다.
- in-place UPDATE를 제외한 근거와 시스템 테이블의 즉시 삭제 경로를 최종 확인한다.
- 삭제 취소의 안전성을 보장할 방안을 비교하고 선택한다. 기존 공간 예약 기능만 적용하면 슬롯 보호와 vacuum 작업 보호가 충분한지도 함께 검증한다.
