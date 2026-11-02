# 손상된 heap 레코드의 가변 필드 offset 및 VOT 순회 경계 검사 보강

## Issue Triage

**이슈 수행 목적**: 일반 heap 레코드의 가변 속성을 읽을 때 VOT 엔트리와 필드 범위를 검사하고, 손상된 입력을 레코드 밖의 읽기 없이 처리하게 한다.

**이슈 수행 이유**: develop의 `heap_attrvalue_point_variable()`은 현재와 다음 offset을 레코드 길이 확인 없이 읽는다. SET 계열과 LOB 계열은 필드 길이를 정하려고 전체 VOT를 추가 순회하며 이 읽기에도 경계 검사가 없다.

**영향**: 손상된 offset 또는 잘린 VOT가 들어오면 레코드 밖의 읽기나 잘못된 필드 범위 전달로 이어질 수 있다. 기존 리뷰는 손상 레코드 실행에서 crash를 보고하지만, 개별 crash와 각 누락 검사의 일대일 대응 및 정상 SQL에서의 발생은 확인하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

> 아래는 기존 손상 레코드 리뷰와 별도의 코드 및 수정 이력 확인을 바탕으로 작성했다. 기존 실행 결과를 새 재현 결과로 취급하지 않는다.

## Description

### 무엇이 문제인가

일반 heap reader는 VOT에서 가변 속성의 위치를 얻은 뒤 그 위치의 바이트를 타입별 decoder에 넘긴다. 이때 엔트리를 읽는 메모리 범위와 엔트리가 가리키는 필드 범위를 모두 확인해야 한다.

develop `d5674fe94f08d084c6832ba4e3f6521d66cbee0e`의 `heap_attrvalue_point_variable()`은 `HEAP_REC_LAYOUT`의 VOT 주소, offset 폭 및 속성 위치로 현재와 다음 엔트리를 직접 읽는다. 함수에는 레코드 길이 인수가 없으며 필드가 레코드 안에 있는지 검사하지 않는다.

SET, MULTISET, SEQUENCE, BLOB 및 CLOB은 table 순서와 실제 값 순서가 다를 수 있으므로, 더 큰 offset 중 가장 가까운 값을 찾기 위해 `n_variable + 1`개 엔트리를 순회한다. 이 순회도 VOT 전체가 실제 레코드 안에 있는지 확인하지 않는다. 따라서 인접한 두 엔트리만 검사하는 것으로 전체 문제가 끝나지 않는다.

### 왜 문제인가

운영자와 검증 담당자는 손상된 행을 읽을 때 서버가 원인을 나타내는 오류를 반환하기를 기대한다. 범위가 확인되지 않은 offset으로 decoder에 접근하면 원래의 저장 데이터 손상이 메모리 오류로 이어질 위험이 있다. 손상 레코드 테스트에서도 같은 입력에 대한 결과가 메모리 배치에 영향을 받아 원인 분리가 어려워질 수 있다. 실제 운영 빈도와 외부 입력을 통한 도달 가능성은 미확인이다.

### 왜 해결해야 하는가

이 문제는 OOS 통합 전 develop의 일반 reader에도 있다. OOS 전용 stub 검사를 보강해도 일반 필드와 전체 VOT 순회의 문제는 남는다. 별도 이슈로 다루면 일반 reader의 검증 범위와 오류 계약을 정하고, 정상 값 순서 및 타입별 읽기 의미를 유지하는 검증을 할 수 있다.

## Triage Request

독립적인 Correct Error 이슈로 확인하고 작성자 측에 ANALYSIS를 배정해 주기를 요청한다. 다음 범위를 분석한다.

- header와 class representation은 정상인 상태에서 잘린 VOT 또는 잘못된 필드 offset을 읽는 경우.
- 현재와 다음 엔트리의 범위, VOT 전체 순회 범위 및 decoder에 전달하는 필드 범위.
- 값 순서와 table 순서가 다른 정상 레코드의 기존 의미.

`NULL_REPRID` recache 후 캐시 포인터 불일치는 별도 후속 이슈로 분리한다. 서로의 재현을 가리지 않도록 독립된 입력을 사용한다.

## Test Build

- 코드 비교 기준은 develop `d5674fe94f08d084c6832ba4e3f6521d66cbee0e`이다. develop `2b3158b66843052fdecadff60df864bbee84fab1`에서도 같은 일반 reader와 전체 VOT 순회를 확인했다.
- 원본 리뷰는 feature base `dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67`와 PR #8299 계열의 손상 레코드 sweep에서 crash를 기록한다.
- 이번에 새로 실행한 재현은 없다. release별 영향과 최소 실패 레코드는 ANALYSIS에서 확정한다.

## Repro

아래는 미실행 최소 검증 제안이다. 기존 sweep 전체를 이 이슈의 단일 재현으로 사용하지 않는다.

1. 정상적인 header와 representation을 유지한 일반 가변 레코드를 준비한다.
2. VOT의 현재 엔트리 또는 다음 엔트리가 잘리도록 길이를 줄인 경우를 각각 만든다.
3. VOT 자체는 남기고 필드 offset이 유효 범위를 벗어나도록 바꾼다.
4. SET 또는 LOB 속성에서는 인접 엔트리가 남고 전체 순회가 읽는 뒤쪽 엔트리만 잘린 경우를 별도로 만든다.
5. sanitizer 또는 경계 보호 버퍼로 범위 밖 읽기를 판별하고, 정상 NULL과 정상 값 순서의 대조군을 실행한다.

최소 테스트와 정확한 실행 명령은 ANALYSIS에서 공유 가능한 형태로 추가한다.

## Expected Result

레코드 범위 검증에 성공한 엔트리와 필드만 읽는다. 손상 입력은 오류 처리로 이어지고, 정상 레코드의 NULL 및 SET 계열과 LOB 계열 길이 계산은 유지한다.

## Actual Result

소스에서 인접 VOT 읽기, 전체 VOT 순회 및 일반 필드 포인터 생성에 레코드 길이 검사가 없음을 확인했다. 기존 리뷰의 crash를 각 검사 누락에 대응하는 최소 재현으로 분리하는 작업은 남아 있다.

## Additional Information

- [develop의 가변 필드 reader](https://github.com/CUBRID/cubrid/blob/d5674fe94f08d084c6832ba4e3f6521d66cbee0e/src/storage/heap_file.c#L11262)와 [전체 VOT 순회](https://github.com/CUBRID/cubrid/blob/d5674fe94f08d084c6832ba4e3f6521d66cbee0e/src/storage/heap_file.c#L11299)를 확인했다.
- CBRD-26369의 커밋 `8ac881d52` 이전에도 기존 reader는 검사 없는 `OR_VAR_IS_NULL()`과 `OR_VAR_LENGTH()`를 사용했다. 함수 분리나 CBRD-27215의 layout 최적화가 이 문제를 처음 만들었다고 단정하지 않는다.
- [CBRD-26769](http://jira.cubrid.org/browse/CBRD-26769)와 [PR #7296](https://github.com/CUBRID/cubrid/pull/7296)은 OOS 읽기 실패를 호출자에게 전파하는 작업이다. 일반 가변 필드 전체의 경계 검사를 완료한 이슈가 아니다.
- [CBRD-26488](http://jira.cubrid.org/browse/CBRD-26488)은 MVCC header 크기 lookup의 인덱스 범위를 다룬다. 이번 VOT와 payload 범위 검증과는 대상이 다르다.
- [원본 리뷰의 non-OOS 기존 문제 절](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27785/CBRD-27785-pr8299-adversarial-review_f8114e432_claude.md#non-oos-existing)과 [후보 기록 CBRD-27873](http://jira.cubrid.org/browse/CBRD-27873)을 근거로 분리한다.
