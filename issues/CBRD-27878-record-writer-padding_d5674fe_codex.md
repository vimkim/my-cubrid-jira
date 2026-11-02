# heap 레코드 writer의 미사용 padding 및 bound bit 초기화

## Issue Triage

**이슈 수행 목적**: heap 레코드의 논리적 값에 속하지 않는 padding 바이트와 미사용 bound bit에 초기화되지 않은 버퍼 내용이 남지 않게 한다.

**이슈 수행 이유**: 기존 레코드 바이트 비교에서 VOT 정렬 padding, fixed 영역의 미사용 바이트 및 유효 속성 수 밖의 bound bit가 실행마다 달라졌다고 보고되었다. writer는 버퍼를 확보한 뒤 해당 영역 전체의 초기화를 보장하지 않는다.

**영향**: QA와 개발자가 레코드 바이트의 동등성을 확인할 때 미정의 영역을 따로 마스킹해야 한다. 이전 메모리 내용이 저장 데이터에 포함될 가능성은 있으나, 다른 사용자의 데이터나 민감 정보가 실제 파일 또는 백업에 남았다는 증거는 없다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

> 아래는 기존 writer 비교 보고와 별도의 소스 및 이력 확인을 바탕으로 작성했다. 바이트 차이 관측과 정보 노출 가능성을 구분한다.

## Description

### 무엇이 문제인가

heap writer는 레코드 header, 가변 offset table, fixed 속성, bound bitmap 및 가변 값을 한 버퍼에 직렬화한다. 각 영역에는 정렬이나 속성 배치 때문에 논리적 값에 속하지 않는 바이트 또는 비트가 있을 수 있다.

`heap_attrinfo_transform_to_disk_internal()`은 `resize_buffer()`와 `or_init()`을 호출한 뒤 header와 columns를 쓴다. `heap_attrinfo_transform_columns_to_disk()`는 VOT 끝을 정렬하고 사용 중인 fixed 속성의 bound bit를 각각 설정하거나 해제한다. 이 경로에서 VOT 정렬 gap, 어떤 fixed 속성에도 속하지 않는 영역 및 bitmap의 미사용 비트가 모두 초기화된다는 보장은 확인되지 않는다.

원본 리뷰는 같은 빌드의 두 실행에서 이 영역의 바이트가 달라졌다고 보고한다. 기록 레코드를 비교할 때 해당 바이트와 비트를 따로 마스킹해야 했다. 필요한 결과는 writer가 출력하는 레코드 안의 미정의 영역에 이전 버퍼 내용이 남지 않는 것이다.

### 왜 문제인가

QA와 개발자는 직렬화 변경 전후에 실제 레코드가 같은 값을 담는지 비교한다. 미정의 바이트가 실행마다 달라지면 의미 있는 변경과 버퍼 잔존 내용을 구분하기 위한 마스킹 규칙을 별도로 유지해야 한다. 이는 writer 회귀 검증의 비용을 늘린다.

미초기화 바이트가 레코드에 포함되면 메모리의 이전 내용이 저장 경로로 전달될 가능성도 있다. 다만 이 리뷰는 민감 정보의 잔존, 사용자 간 노출 또는 백업 유출을 증명하지 않았다. 그 영향은 분석 질문으로 남긴다. SQL 결과가 잘못되었다는 증거도 없다.

### 왜 해결해야 하는가

레코드 형식과 논리적 값을 유지하면서 미사용 영역을 일정하게 만들면 writer 검증에서 별도 마스킹에 의존하는 범위를 줄일 수 있다. 버퍼 재사용 시 남는 내용의 저장 여부도 명확하게 판정할 수 있다. 정보 유출 결함으로 긴급성을 단정하기보다 초기화 보장과 검증 가능성을 개선하는 과제로 다룬다.

## Triage Request

Improve Function/Performance 이슈로 확인하고 작성자 측에 ANALYSIS를 배정해 주기를 요청한다. 미사용 영역의 정확한 범위, 저장까지의 경로, 초기화 비용 및 기존 레코드와의 호환성을 확인한다. 전체 버퍼 초기화와 필요한 영역만 초기화하는 방식 중 어느 것을 쓸지는 이 단계에서 확정하지 않는다.

## Specification Changes

SQL 값과 레코드 형식을 바꾸지 않고 writer가 출력하는 미사용 영역의 초기화 보장을 정의한다. 이미 저장된 레코드의 재작성이나 migration 필요 여부는 ANALYSIS에서 확인하며, 이 이슈가 기존 데이터 재작성을 전제하지는 않는다.

## Implementation

TBD - ANALYSIS 단계에서 결정한다.

## Acceptance Criteria

- 서로 다른 값으로 미리 채운 버퍼에 같은 레코드를 직렬화했을 때, 정의된 미사용 영역에 이전 채움 값이 남지 않는다.
- VOT 정렬 padding, fixed 영역의 실제 미사용 바이트 및 bitmap의 유효 속성 밖 비트를 각각 판별한다.
- 논리적 값, 유효 offset 및 사용 중인 bound bit의 의미를 유지한다.
- 초기화 비용과 호환성의 검증 범위를 정하고 결과를 기록한다. 성능 개선 수치나 허용 악화 기준은 이 단계에서 정하지 않는다.

## Definition of done

초기화되지 않는 영역을 공유 가능한 테스트로 입증하고, 필요한 수정 후 같은 테스트에서 잔존 내용이 사라짐을 확인한다. 영향이 확인된 writer 경로의 정상 INSERT와 UPDATE 결과도 검증한다. 민감 정보의 저장이 확인되지 않으면 그 한계를 결과에 명시한다.

## Additional Information

- 소스 기준은 develop `d5674fe94f08d084c6832ba4e3f6521d66cbee0e`의 [버퍼 준비](https://github.com/CUBRID/cubrid/blob/d5674fe94f08d084c6832ba4e3f6521d66cbee0e/src/storage/heap_file.c#L13683)와 [column 직렬화](https://github.com/CUBRID/cubrid/blob/d5674fe94f08d084c6832ba4e3f6521d66cbee0e/src/storage/heap_file.c#L13548)다. 이번 이슈 작성 중 새 writer 실행은 하지 않았다.
- 원본 리뷰의 base는 `dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67`, 초기 head는 `f8114e432d3e97cc7a11149ab8ac852de4a1b935`이다. 정확한 잔존 바이트의 출처와 저장 파일 내용은 별도 분석 대상이다.
- CBRD-26361의 커밋 `aa7e471638`은 writer를 함수들로 분리했다. 이 리팩토링이 미초기화 영역을 처음 만들었다고 확인한 것은 아니다.
- [CBRD-21716](http://jira.cubrid.org/browse/CBRD-21716)은 log header의 padding 초기화다. 이번 heap record writer와 대상이 다르다.
- CBRD-26785의 [PR #7163](https://github.com/CUBRID/cubrid/pull/7163)은 metaclass 및 catalog serializer의 VOT 정렬을 다룬다. 정렬 위치를 맞추는 작업과 heap writer의 미사용 바이트 초기화는 구분한다.
- [원본 리뷰의 non-OOS 기존 문제 절](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27785/CBRD-27785-pr8299-adversarial-review_f8114e432_claude.md#non-oos-existing)과 [후보 기록 CBRD-27873](http://jira.cubrid.org/browse/CBRD-27873)을 근거로 분리한다.
