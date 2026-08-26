# [OOS] feat/oos develop 병합 준비 및 잔여 차단 이슈 정리

## Issue Triage

**이슈 수행 목적**: `feat/oos`의 기능 변경과 개발 중 임시 변경을 분리하고, `develop` 병합 전에 반드시 해결할 OOS 정합성 이슈를 명시한다.

**이슈 수행 이유**:

| 구분 | 상태 |
|------|------|
| **AS-IS (현재 동작 / 배경)** | 기능 변경과 개발 중 임시 표면이 섞여 있고, OOS 식별자와 트랜잭션 처리에는 저장 정합성 차단 조건이 남아 있다. |
| **TO-BE (목표 상태 / 기대 동작)** | 임시 표면을 제거해 제품 변경만 리뷰하고, 정합성 차단 이슈의 구현과 회귀 테스트를 대상 브랜치에 포함한 뒤 병합한다. |
| **영향** | 고객 데이터 유실 가능성 — 오래된 OOS 참조나 rollback이 현재 값을 잘못 삭제할 수 있으므로, 단순 빌드 성공만으로 병합 가능 상태로 판단할 수 없다. |

**이슈 수행 방안**: 확정된 임시 코드 제거는 commit `2dc3dddbd66c320bff348036300af13f4f57b578`에 반영한다. CBRD-26950을 선행 적용하고, CBRD-27230의 commit 조건부 통지와 forward-walk 제거로 CBRD-27237의 rollback 문제를 해결한다. CBRD-27089의 근본 원인 수정과 CBRD-27057 구현도 이 브랜치에 통합한 뒤 회귀 테스트로 검증한다.

---

## AI-Generated Context

> 아래는 AI가 코드와 관련 이슈를 분석해 작성한 상세 자료다. 빠른 triage에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현과 리뷰 단계에서 참고하면 된다.

### 요약

- **변경 범위 / 영향**: GitHub Actions, CMake와 빌드 스크립트, CSQL 명령 처리, client-server 통신, `vacuum`(더 이상 보이지 않는 행 버전을 정리하는 백그라운드 작업), heap/OOS 저장 계층, OOS 단위 테스트가 대상이다.
- **호환성**: 제품에 노출하지 않기로 한 `;vacuum`, `;oos_stats`, `db_vacuum()`, `db_get_oos_stats()` 및 전용 RPC를 제거한다. 제품 기능인 `SHOW HEAP OOS`의 VFID(볼륨 안에서 파일을 식별하는 값) 기반 통계 수집은 유지한다.
- **검증 기준점**: `develop`의 `95b79e7ed`를 병합한 뒤 cleanup commit `2dc3dddbd`에서 검토했다.

## Description

OOS(Out-of-row Overflow Storage)는 heap 레코드의 큰 가변 길이 값을 별도 OOS 파일에 저장하고 heap에는 참조자를 남기는 기능이다. `feat/oos`는 여러 하위 이슈를 장기간 통합한 기능 브랜치라, 기능 구현 외에도 개발 중 장애를 빠르게 드러내기 위한 중단 코드와 테스트 편의 인터페이스가 누적됐다.

vacuum과 heap 경로의 일부 진단 코드는 `NDEBUG` 빌드에서도 `abort()`를 호출했다. 이런 코드는 원인 조사에는 유용하지만, 예상하지 못한 OOS 상태가 발생했을 때 서버 프로세스 전체를 종료하므로 제품 병합에는 적합하지 않다. 브랜치 이름을 직접 지정한 workflow 조건과 일반 빌드에 결합된 CTest 실행도 기능 구현과 무관한 병합용 조정이다.

개발용 `;vacuum`과 `;oos_stats`는 CBRD-26837에서 `develop` 제외 대상으로 정했다. 그런데 명령 처리뿐 아니라 공개 DB API와 네트워크 요청까지 함께 노출되어 있어, 명령만 숨기면 불필요한 제품 인터페이스가 남는다. cleanup은 이 표면 전체를 함께 제거한다.

이 정리는 병합 준비의 필요조건이지 충분조건은 아니다. OOS 식별자에 generation stamp(슬롯이 재사용된 세대를 구분하는 값)가 없어 오래된 참조를 걸러내지 못한다. 또한 현재 forward-walk는 UPDATE undo image를 commit/abort 구분 없이 처리하므로, rollback이 이전 chain을 복원한 뒤 vacuum이 그 live chain을 삭제할 수 있다. 정렬된 레코드 네 개와 slot 항목이 페이지의 물리 용량 안에 들어가도록 하는 4,060바이트 inline 목표 크기 구현도 별도 해결 이슈에는 존재하지만 source commit `2dc3dddbd`에는 들어 있지 않다. 이 목표는 실제 페이지에 항상 네 행이 배치된다는 보장이 아니다.

## Specification Changes

| 항목 | 병합 대상 스펙 |
|------|----------------|
| OOS 테스트 | 기본값은 비활성화한다. OOS 테스트를 선택한 구성에서만 GoogleTest와 관련 테스트 대상을 준비한다. |
| 빌드 동작 | 일반 빌드는 컴파일과 링크만 수행하며 CTest를 자동 실행하지 않는다. |
| 개발 명령/API | `;vacuum`, `;oos_stats`, `db_vacuum()`, `db_get_oos_stats()`와 전용 client-server RPC는 제품 인터페이스에서 제외한다. |
| 통계 기능 | `SHOW HEAP OOS`가 사용하는 `oos_get_stats_by_vfid()`는 유지한다. 테스트가 요구하는 class OID 변환 helper만 `CUBRID_UNIT_TEST_ENABLED` 안에 둔다. |
| 메모리 할당 실패 | OOS 이관 준비 중 `std::vector::reserve()`가 던지는 `std::bad_alloc`을 즉시 잡아 `ER_OUT_OF_VIRTUAL_MEMORY`와 `S_ERROR`로 변환한다. |
| 비정상 OOS 상태 | 임시 `abort()` 대신 기존 오류 처리와 assertion 정책을 따른다. 정합성 원인은 관련 차단 이슈에서 해결한다. |

## Implementation

### 제거한 병합 전용 변경

```
[GitHub Actions]
  feat/oos 전용 branch filter 제거

[빌드 구성]
  일반 build -> 자동 CTest 실행 제거
  OOS test  -> 명시적 선택 시에만 GoogleTest 구성

[개발 인터페이스]
  CSQL command -> DB API -> client/server RPC
       ;vacuum       db_vacuum             전용 요청
       ;oos_stats    db_get_oos_stats      전용 요청
  위 경로 전체 제거

[실행 중 진단]
  vacuum/heap의 임시 abort -> 기존 오류 처리 또는 assertion
```

`heap_file.c`는 C++ 컨테이너를 사용하는 구간을 GNU indent가 건드리지 않도록 `/* *INDENT-OFF* */`와 `/* *INDENT-ON* */`으로 감싼다. `reserve()`의 예외 변환은 유지한다. 메모리가 부족한 상태에서 계속 진행할 안전한 대체 경로가 없으므로, OOS 이관을 시작하기 전에 CUBRID 오류로 반환하는 편이 부분 상태를 만들지 않는다.

제품에서 제외한 두 내부 helper는 OOS 테스트 빌드에만 남긴다. `vacuum_wakeup_master_daemon()`은 vacuum 동기화 테스트가 master daemon을 깨우는 데 사용하고, `xoos_get_stats_by_class_oid()`는 테스트의 class OID를 제품 통계 함수가 받는 VFID로 변환한다.

### 코딩 규칙 검토

| 결과 | 내용 |
|------|------|
| 수정 완료 | 릴리스 경로의 임시 `abort()`, `feat/oos` workflow 필터, 기본 활성 OOS 테스트와 자동 CTest, 제외 대상 CSQL/API/RPC를 제거했다. |
| 수정 완료 | legacy `.c` 파일의 C++ 구간에 정확한 GNU indent 보호 주석을 적용했다. |
| 유지 | `std::bad_alloc` catch는 예외를 엔진 밖으로 전파하지 않고 CUBRID 오류 모델로 변환하는 경계이므로 유지한다. |
| 후속 검토 | 제품 오류 로그와 테스트 관측용 OOS logger의 역할이 겹치는 부분은 별도 정리 후보이나, 이번 임시 변경 제거 범위에는 포함하지 않는다. |

### 스펙 검토

| 관련 이슈 | 현재 상태와 병합 조건 |
|-----------|----------------------|
| [CBRD-26950](http://jira.cubrid.org/browse/CBRD-26950) | OOS 슬롯 재사용을 구분할 generation stamp가 source commit `2dc3dddbd`에 없다. 이전 참조가 새 값을 가리키지 않도록 식별자와 검증 로직을 먼저 통합해야 한다. |
| [CBRD-27089](http://jira.cubrid.org/browse/CBRD-27089) | `HAS_OOS` 상태인데 OOS file이 없는 불변식 위반의 근본 원인이 미해결이다. 임시 중단 코드 제거와 별개로 원인을 고쳐야 한다. |
| [CBRD-27230](http://jira.cubrid.org/browse/CBRD-27230) | `RVOOS_NOTIFY_VACUUM`을 commit될 때만 내보내고 forward-walk(vacuum이 UPDATE 로그의 undo image에서 옛 head OOS OID를 다시 찾아 chain을 삭제하는 경로)를 제거해야 한다. CBRD-26950이 선행 조건이다. |
| [CBRD-27237](http://jira.cubrid.org/browse/CBRD-27237) | update rollback 중 현재 OOS 값이 삭제되는 문제다. 별도 순서 변경이 아니라 CBRD-27230의 구조로 해결하고 rollback 회귀 테스트를 추가한다. |
| [CBRD-27057](http://jira.cubrid.org/browse/CBRD-27057) | 이슈는 해결 상태지만 정렬된 레코드 네 개와 slot 항목을 물리 용량 안에 수용하는 4,060바이트 목표 구현이 source commit `2dc3dddbd`에 없다. 해당 fix를 이 브랜치에 통합해야 한다. |

위 항목은 cleanup commit과 독립적인 기능 정확성 조건이다. 하나라도 남아 있으면 draft PR을 ready for review 또는 병합 가능 상태로 전환하지 않는다.

### 검증 결과

- Debug 구성의 전체 CUBRID 빌드가 성공했다.
- RelWithDebInfo 구성의 전체 CUBRID 빌드가 성공했다.
- 구성된 OOS CTest 26개가 모두 통과했다.
- `git diff --check`가 통과했으며, 임시 중단 표식과 workflow의 `feat/oos` 조건이 남지 않았다.

## Acceptance Criteria

- [x] 릴리스 경로의 OOS/vacuum 임시 `abort()`를 제거한다.
- [x] 브랜치 전용 workflow 조건과 일반 빌드의 자동 테스트 실행을 제거한다.
- [x] CBRD-26837에서 제외한 CSQL 명령, 공개 API와 전용 RPC를 제거한다.
- [x] OOS 테스트를 opt-in으로 구성하고 테스트 전용 helper를 제품 빌드에서 제외한다.
- [x] `reserve()` 실패를 CUBRID 메모리 오류로 변환한다.
- [x] Debug/RelWithDebInfo 빌드와 OOS CTest 26개를 통과한다.
- [ ] CBRD-26950의 generation stamp 구현과 회귀 테스트를 현재 브랜치에 통합한다.
- [ ] CBRD-27089의 OOS file 불변식 위반 원인을 해결한다.
- [ ] CBRD-27230의 commit 조건부 통지와 forward-walk 제거를 적용하고 CBRD-27237 rollback 회귀 테스트를 통과한다.
- [ ] CBRD-27057의 4,060바이트 물리 용량 목표 구현을 현재 브랜치에 통합한다.

## Definition of done

- [ ] 위 Acceptance Criteria를 모두 충족한다.
- [ ] 대상 commit의 SQL, medium, shell CI 결과에서 OOS 관련 회귀가 없다.
- [ ] draft PR의 차단 이슈가 모두 해결된 뒤 ready for review로 전환한다.
- [ ] 사용자 공개 동작이나 설정이 추가로 바뀌면 매뉴얼과 QA 시나리오를 함께 갱신한다.
