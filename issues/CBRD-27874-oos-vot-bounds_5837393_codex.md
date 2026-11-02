# [OOS] 복합 인덱스 키 크기 계산 및 복제 OID 보정에서 VOT 접근 전 경계 검사 추가

## Issue Triage

**이슈 수행 목적**: 잘린 heap 레코드를 처리할 때 복합 인덱스 키 크기 계산과 HA 복제 OID 보정이 가변 offset table을 범위 밖에서 읽지 않게 한다.

**이슈 수행 이유**: 두 OOS 호출처가 경계 검사를 수행하는 stub 접근 함수보다 먼저 `OR_VAR_IS_NULL()`을 호출한다. PR #8299가 다른 OOS 읽기 경로에 추가한 검사와 같은 종류의 누락이 남아 있다.

**영향**: 손상되거나 잘린 레코드가 해당 경로에 들어오면 레코드 밖의 offset 엔트리를 읽을 수 있다. 이는 코드로 확인한 위험이다. 정상 SQL이나 실제 HA 운영 환경에서 이 두 호출처의 장애를 재현하지는 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

> 아래는 제공된 리뷰 보고서와 소스 및 수정 이력을 확인해 작성한 맥락이다. 기존 보고서의 실행 결과와 이번 코드 검토를 구분한다.

## Description

### 무엇이 문제인가

VOT는 가변 속성의 시작 위치를 담은 offset table이다. `OR_VAR_IS_NULL()`은 현재 속성과 다음 속성의 offset 차이를 이용해 NULL 여부를 판정한다. 이 매크로는 `RECDES.length`를 받지 않으므로 두 엔트리가 레코드 안에 있는지 검사하지 않는다.

PR #8299 head `5837393ffb9d69bccb93271d63b0e38b884e0ed4`에서 다음 두 호출처에 이 매크로가 남아 있다.

- `heap_midxkey_get_oos_extra_size()`는 복합 인덱스 키 버퍼의 추가 크기를 계산한다. NULL 판정 뒤에야 `heap_recdes_get_oos_inline_stub()`을 호출한다.
- `locator_fixup_oos_oids_in_recdes()`는 복제 레코드의 OOS 참조를 slave의 OID로 보정한다. NULL 판정과 별도의 offset 읽기 뒤에 stub을 검사한다.

따라서 뒤의 stub 검사는 앞에서 수행한 범위 밖 읽기를 막지 못한다. 필요한 결과는 header와 두 VOT 엔트리를 검증한 뒤 NULL 및 OOS 여부를 판정하는 것이다.

### 왜 문제인가

운영자와 개발자는 손상 레코드의 인덱스 키를 만들거나 복제 레코드를 반영할 때, 유효하지 않은 입력이 통제된 오류 처리로 이어지기를 기대한다. 현재는 손상 여부를 판단하는 과정에서 입력 범위를 벗어날 수 있어 원래 손상과 별개의 메모리 오류를 만들 위험이 있다. 실제 발생 빈도와 운영 영향은 확인하지 않았다.

### 왜 해결해야 하는가

동일한 입력을 다루는 다른 OOS 경로에는 이미 검사된 접근 함수가 있다. 두 호출처를 별도 작업으로 추적하면 정상 레코드의 의미를 유지하면서 손상 입력의 처리 범위를 확인할 수 있다. 이 작업은 OOS 값의 저장 형식이나 chain identity 정책을 바꾸는 과제가 아니다.

## Triage Request

[OOS TODO CBRD-26978](http://jira.cubrid.org/browse/CBRD-26978)의 하위 이슈로 확인하고 작성자 측에 ANALYSIS를 배정해 주기를 요청한다. [CBRD-27873](http://jira.cubrid.org/browse/CBRD-27873)의 후보 1번을 구현 가능한 독립 작업으로 분리한다.

ANALYSIS에서는 검사 실패 시 크기 계산 함수의 기존 반환 계약과 복제 경로의 오류 처리를 확인한다. 검사된 raw 엔트리의 플래그를 제거한 offset으로 NULL을 판정해야 한다. 복제 함수의 선행 header 접근과 별도 offset 읽기도 함께 확인한다.

## Test Build

이번에 실행한 재현 빌드는 없다. 코드 검토 기준은 PR #8299 head `5837393ffb9d69bccb93271d63b0e38b884e0ed4`이다. 이 코드는 `feature/oos-merge`에 속하며, develop에 이미 도입된 결함으로 분류하지 않는다.

## Repro

아래는 미실행 검증 제안이다.

1. 정상 header가 있지만 현재 또는 다음 VOT 엔트리가 잘린 `RECDES`를 만든다.
2. 두 대상 호출처를 각각 실행해 레코드 범위를 벗어난 읽기가 있는지 sanitizer 또는 경계 보호 버퍼로 확인한다.
3. 정상 NULL, 일반 가변 값, OOS 값 및 지원하는 offset 폭과 header 크기를 대조한다.

최소 재현과 일반 SQL 또는 HA 경로의 도달 가능성은 ANALYSIS에서 확정한다.

## Expected Result

VOT와 OOS stub은 해당 범위를 검사한 뒤 읽는다. 정상 레코드의 NULL 판정, 키 크기 및 OID 보정 결과는 유지한다. 손상 입력은 각 호출처의 오류 처리 계약에 따라 처리한다.

## Actual Result

두 호출처 모두 VOT 경계 검사보다 앞에서 `OR_VAR_IS_NULL()`을 호출한다. 이 두 호출처를 대상으로 한 실행 증거는 아직 없다.

## Additional Information

- [PR #8299의 두 호출처 중 키 크기 계산 코드](https://github.com/CUBRID/cubrid/blob/5837393ffb9d69bccb93271d63b0e38b884e0ed4/src/storage/heap_file.c#L11844)와 [복제 OID 보정 코드](https://github.com/CUBRID/cubrid/blob/5837393ffb9d69bccb93271d63b0e38b884e0ed4/src/transaction/locator_sr.c#L14423)를 확인했다.
- [CBRD-26950](http://jira.cubrid.org/browse/CBRD-26950)과 [PR #7695](https://github.com/CUBRID/cubrid/pull/7695)는 OOS identity 및 stub 필드 경계를 다룬다. 이번 대상은 그 검사 전에 수행하는 VOT 읽기이므로 남은 범위가 다르다.
- [PR #8299](https://github.com/CUBRID/cubrid/pull/8299)는 `heap_oos_attr_has_inline_ref()`에 검사된 pair reader를 적용했다. 두 대상 호출처에는 적용하지 않았다. 해당 helper를 사용하는 구현은 #8299와의 통합 순서를 확인해야 한다.
- [원본 리뷰의 OOS 기존 문제 절](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27785/CBRD-27785-pr8299-adversarial-review_f8114e432_claude.md#oos-existing)에 후보의 출처와 미재현 상태가 기록되어 있다.
