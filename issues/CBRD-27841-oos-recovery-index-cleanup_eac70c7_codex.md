# [OOS] 미사용 복구 인덱스 제거와 로그 번호 정리

## Issue Triage

**이슈 수행 목적**: OOS를 develop에 병합하기 전에 사용하지 않는 복구 로그 항목을 제거하고, 실제 로그 번호와 복구 함수 배열의 일치를 유지한다.

**이슈 수행 이유**: PR 7990의 hornetmj R6 리뷰에서 `RVOOS_NOTIFY_VACUUM`의 생산자가 없는데도 enum, 빈 복구 함수 항목과 두 분류 조건이 남아 있다고 지적했다. 병합 후 로그 형식으로 고정되기 전에 제거할 필요가 있다.

**영향**: 현재 항목이 사용자 오류를 일으킨 실행은 확인하지 않았다. 유지하면 미사용 번호와 분류를 계속 관리해야 한다. 제거하면서 뒤의 번호를 바꾸면 기존 개발 DB의 로그와 호환되지 않으므로, 기존 DB를 복구 전에 거부해야 한다.

**이슈 수행 방안**: R6 리뷰의 제거·번호 정리를 적용하고 ADR-0006의 저장 형식 검사 정책을 따른다. 로컬 수정·검증 결과는 아래에 기록하며, 회사 PR 리뷰와 CI 검증은 별도로 받는다.

---

## AI-Generated Context

> 리뷰어의 관찰, source 확인, 직접 실행한 검증과 미검증 범위를 구분한다.

## Description

### 무엇이 문제인가

복구 로그는 처리 함수의 이름 대신 숫자 인덱스를 저장한다. 현재 `RVOOS_NOTIFY_VACUUM = 140`은 로그를 기록하는 코드가 없지만, `RV_fun[]`의 빈 처리 항목과 MVCC·logical-log 분류에 포함돼 있다. 전체 source 검색에서 실제 생산자를 찾지 못했다.

이 항목 뒤의 `RVREPL_DUMMY_OOS_RECORD = 141`과 `RVHF_DELETE_NEWHOME_NOTIFY_VACUUM = 142`는 실제 사용한다. 전자는 여러 조각으로 저장한 OOS 값의 복제 표시이고, 후자는 MVCC forward 레코드 삭제의 복구·vacuum 처리를 구분한다. `RV_fun[]`은 숫자로 직접 접근하므로 enum과 배열 순서를 함께 바꿔야 한다.

### 왜 문제인가

미사용 항목을 병합하면 이후 로그 형식에서 그 번호를 유지해야 한다. 단순히 빈 배열 항목만 지우면 뒤의 숫자와 배열 위치가 맞지 않는다. 번호까지 정리하면 예전 141·142를 기록한 개발 DB와 호환되지 않는다. 같은 저장 형식 번호를 유지한 채 이런 DB를 열게 해서는 안 된다.

### 왜 해결해야 하는가

리뷰에서 요청한 시점에 미사용 항목을 제거하고, 실제 항목의 처리 함수와 분류를 유지해야 한다. ADR-0006에 따라 저장 형식 번호를 올리면 예전 개발 DB는 로그 복구에 들어가기 전에 정상 오류로 거부된다. 디스크 호환성 수준 11.5는 바꾸지 않는다.

## Parent and Scope

상위 작업은 [OOS M2, CBRD-26583](https://jira.cubrid.org/browse/CBRD-26583)이다. 이 하위 작업은 [PR 7990 R6](https://github.com/CUBRID/cubrid/pull/7990#discussion_r4409612618)의 미사용 복구 항목 정리와 필요한 형식 검증만 다룬다.

[CBRD-27230](https://jira.cubrid.org/browse/CBRD-27230)은 실제 commit 알림을 통해 UPDATE의 OOS 체인을 재사용하는 별도 작업이다. 현재의 빈 예약 항목은 그 기능을 구현하지 않는다. 이번 정리로 해당 요구를 완료하거나 취소하지 않으며, 알림 구현 때 필요한 실제 복구 항목을 다시 정의해야 한다. R5의 forward 슬롯 복구 결함과도 별개다.

## Implementation

로컬 후보는 `eac70c7e740d55b4623b46bb84797e8214dcdcc4`이며 기준은 `dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67`이다.

- 미사용 enum, 빈 `RV_fun[]` 항목과 두 분류 조건을 제거했다.
- 두 실제 항목을 140·141로 정리하고 기존 처리 함수를 유지했다.
- `DISK_STORAGE_FORMAT_REVISION`을 1에서 2로 올렸다.
- 기존 형식 검사 테스트를 확장해 0, 이전 nonzero 형식, 미래 형식을 검사한다. 올바른 형식 복원 후 열기와 거부된 DB의 fixture 정리도 확인한다.

## Validation

debug 빌드에서 수정 전후 같은 집중 CTest가 각각 10/10 통과했다. 이 수에는 setup·cleanup fixture가 포함된다. 실제 검사는 형식 거부 shell 테스트와 GoogleTest 13개다. GoogleTest는 트랜잭션 8개, 실제 crash redo·깨끗한 재시작 2개, TDE 분류 3개다.

별도 DB의 시작 과정에서 `rv_check_rvfuns` 실행을 디버거로 관측했다. 실제 빌드의 140·141 항목과 기존 undo·redo 처리 함수를 확인했다. OOS 값의 INSERT·UPDATE·DELETE commit과 다른 UPDATE·INSERT rollback 뒤 DB를 다시 열어, 저장한 값과 삭제·취소 결과를 검사했다. `checkdb -S`도 통과했다.

집중 테스트는 설치와 빈 전용 DB registry를 선택한 환경에서 실행한다. 기존 사용자 DB를 테스트 fixture로 사용하지 않는다. `CUBRID`, `CUBRID_DATABASES`, 설치의 `bin`을 포함한 `PATH`를 configure 전에 설정해야 한다.

```sh
ctest --test-dir "$CUBRID_BUILD_DIR" \
  -R '^(test_oos_storage_format_guard|test_oos_sql_crash_recovery|test_oos_tde_gate|test_oos_sql_txn)$' \
  --output-on-failure --verbose
```

## Acceptance Criteria

- 미사용 복구 항목이 제거되고 전체 실제 인덱스와 복구 함수 배열 위치가 일치한다.
- 기존 로그 처리 함수와 실제 항목의 MVCC·TDE 분류를 유지한다.
- 새 형식 DB는 열리고, 이전 형식 1을 포함한 다른 형식은 복구 전에 거부된다.
- OOS 데이터의 트랜잭션·재시작·crash redo와 `checkdb` 검증이 통과한다.
- 회사 PR에서 변경과 검증 한계를 리뷰받는다.

## Limitations

release 빌드, 별도 HA replica로의 로그 재생, 두 변경 번호를 실제로 발생시키는 MVCC relocation 통합 시나리오는 이번 로컬 실행에서 검증하지 않았다. SA crash 테스트를 이 경로들의 검증으로 표시하지 않는다. 서로 다른 빌드 간 복제 로그 호환성도 보장하지 않는다.

## Triage Request

OOS M2 하위의 독립 정리 작업으로 확인하고 작성자 측의 ANALYSIS와 회사 PR 리뷰를 진행하도록 배정을 요청한다. 실제 담당자·우선순위·workflow 상태 변경은 이 요청에 포함하지 않는다.
