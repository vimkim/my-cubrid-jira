# 짧은 heap 레코드를 읽을 때 재사용한 속성 캐시의 불일치 처리

## Issue Triage

**이슈 수행 목적**: 정상 레코드를 읽은 속성 캐시를 짧은 레코드에 재사용할 때, 유효한 class representation 없이 record layout을 만들지 않게 한다.

**이슈 수행 이유**: `heap_attrinfo_recache(NULL_REPRID)`는 `read_classrepr`을 비운 뒤 반환하지만 각 속성의 `read_attrepr`은 남긴다. 기존 리뷰는 이 상태에서 `heap_rec_layout_init()`의 assert에 도달했다고 보고했고, 해당 상태 전이를 소스로 확인했다.

**영향**: 짧은 레코드를 읽는 오류 경로가 통제된 오류 반환 대신 debug assertion으로 종료될 수 있다. 정상 레코드에서의 발생이나 release 빌드의 결과는 확인하지 않았다. OOS에 한정된 문제가 아니다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

> 아래는 기존 손상 레코드 리뷰와 별도의 소스 및 이력 확인을 바탕으로 작성했다. 이번 이슈 작성 과정에서는 해당 재현을 새로 실행하지 않았다.

## Description

### 무엇이 문제인가

heap reader는 여러 행을 읽으면서 `HEAP_CACHE_ATTRINFO`를 재사용한다. `read_classrepr`은 현재 레코드의 class representation을 가리키고, 각 `values[i].read_attrepr`은 그 representation에 속한 속성 정보를 가리킨다. layout을 만들려면 두 상태가 일치해야 한다.

레코드가 header보다 짧으면 `or_rep_id()`는 `NULL_REPRID`를 반환한다. `heap_attrinfo_recache()`는 기존 `read_classrepr`을 비운 후 `NULL_REPRID` 분기에서 성공을 반환한다. 각 값의 `read_attrepr`을 초기화하는 코드는 그 분기 뒤에 있으므로 실행되지 않는다.

이 캐시가 이전의 정상 레코드에서 사용되었다면 `read_classrepr == NULL`이면서 `read_attrepr != NULL`인 상태가 된다. 후속 속성 읽기는 남은 속성 포인터를 보고 layout을 만들 수 있으며, `heap_rec_layout_init()`의 `read_classrepr != NULL` assert에 도달한다. 기존 리뷰는 base와 head에서 같은 assertion을 재현했다고 기록한다.

### 왜 문제인가

개발자와 운영자는 손상된 행을 읽다가 오류가 발생하면 원인을 확인할 수 있어야 한다. 현재는 직전에 정상 행을 읽었는지에 따라 캐시 상태가 달라지고, 원래의 짧은 레코드 오류가 내부 invariant 실패로 이어질 수 있다. 이 때문에 손상 레코드 검증과 장애 분석에서 이전 행의 상태까지 추적해야 한다. 일반 운영에서의 빈도와 release 결과는 아직 알 수 없다.

### 왜 해결해야 하는가

레코드 자체를 복구하는 작업과, 유효하지 않은 입력에서 reader의 캐시 상태를 일관되게 유지하는 작업은 구분할 수 있다. 후자를 해결하면 잘못된 입력이 내부 상태 불일치로 확대되는 것을 막고 재현 및 진단 결과를 안정시킬 수 있다. VOT와 개별 필드의 전체 경계 검사는 별도 범위로 둔다.

## Triage Request

독립적인 Correct Error 이슈로 확인하고 작성자 측에 ANALYSIS를 배정해 주기를 요청한다. 정상 행, 짧은 행, 다음 정상 행을 같은 캐시로 읽는 상태 전이를 대상으로 한다. 최종 오류 코드와 캐시 복원 정책은 ANALYSIS에서 결정한다.

## Test Build

- 원본 리뷰의 base는 `dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67`, 초기 head는 `f8114e432d3e97cc7a11149ab8ac852de4a1b935`이다. 리뷰는 양쪽에서 assertion을 보고한다.
- develop 소스 기준은 `d5674fe94f08d084c6832ba4e3f6521d66cbee0e`이다. 동일한 recache 순서와 layout assert가 있다.
- 이번에 새 실행을 하지 않았다. 구체적인 실패 레코드, 전체 재현 명령 및 release 결과는 ANALYSIS에서 확보한다.

## Repro

아래는 기존 보고서의 재현 조건을 정리한 것이다. 독립적인 최소 재현 명령은 아직 없다.

1. 일반 가변 속성이 있는 정상 레코드를 `HEAP_CACHE_ATTRINFO`로 읽어 속성 포인터를 채운다.
2. 같은 캐시로 header보다 짧은 레코드를 읽어 `NULL_REPRID` recache 분기를 실행한다.
3. class representation과 각 속성 포인터의 상태 및 후속 layout 생성을 확인한다.
4. 수정 검증에서는 다음 정상 행도 같은 캐시로 읽어 오류 뒤 재사용 결과를 확인한다.

기존 리뷰 harness는 개인 fork의 [CBRD-27785-review-harness 브랜치](https://github.com/vimkim/cubrid/tree/CBRD-27785-review-harness), 커밋 `7472ed577850c13be1aed915691a35b6dec23b6b`에 공개되어 있다. 이 자료의 접근 가능성을 확인했다. 다만 이 이슈만의 최소 실패 입력과 정확한 실행 명령을 검증하지는 않았으므로, ANALYSIS에서 별도로 정리한다.

## Expected Result

짧은 레코드는 적절한 오류 경로로 처리한다. class representation이 없는 상태에서 이전 레코드의 속성 포인터로 layout을 만들지 않는다. 정상 행 사이의 캐시 재사용은 유지한다.

## Actual Result

기존 리뷰는 `heap_rec_layout_init()`의 assert를 보고한다. 소스에서는 `NULL_REPRID` 조기 반환이 속성 포인터 초기화보다 앞에 있음을 확인했다. release 빌드에서의 실제 증상은 미확인이다.

## Additional Information

- [develop의 recache 상태 전이](https://github.com/CUBRID/cubrid/blob/d5674fe94f08d084c6832ba4e3f6521d66cbee0e/src/storage/heap_file.c#L10903)와 [layout assert](https://github.com/CUBRID/cubrid/blob/d5674fe94f08d084c6832ba4e3f6521d66cbee0e/src/storage/heap_file.c#L11098)를 확인했다.
- `NULL_REPRID` 조기 반환 순서는 오래된 코드이며, layout assert는 [CBRD-27215](http://jira.cubrid.org/browse/CBRD-27215)의 커밋 `b8199438e`에서 추가되었다. 이 사실만으로 지원 릴리스별 발생 시점을 단정하지 않는다.
- PR #8299에도 기본 recache 순서가 남아 있다. 일부 바깥 경로의 layout 검사는 이 캐시 상태 전이를 모두 해결한 증거가 아니다.
- 관련 검색에서 나온 CBRD-24539는 MIDXKEY 함수 정리, CBRD-25984는 함수 인덱스의 key filter 및 covered scan 과제다. 이번 짧은 레코드 상태 전이와 범위가 다르다.
- [원본 리뷰의 non-OOS 기존 문제 절](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27785/CBRD-27785-pr8299-adversarial-review_f8114e432_claude.md#non-oos-existing)과 [후보 기록 CBRD-27873](http://jira.cubrid.org/browse/CBRD-27873)을 근거로 분리한다.
