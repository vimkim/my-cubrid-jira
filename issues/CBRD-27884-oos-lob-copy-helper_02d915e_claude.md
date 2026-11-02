# [OOS] heap 속성 쓰기 함수 두 곳에 복사된 LOB 복사 코드를 하나로 합친다

## Issue Triage

**이슈 수행 목적**: BLOB/CLOB 값이 가리키는 외부 LOB 파일(ELO)을 복사하는 코드를 한 함수로 모아, 앞으로 한쪽만 고쳐지는 일을 막는다.

**이슈 수행 이유**: OOS 병합 준비 작업(CBRD-26835, PR #7803)이 `heap_attrinfo_transform_variable_to_disk`의 LOB 복사 블록(약 40줄)을 `heap_attrinfo_dbvalue_to_recdes`에 그대로 복사했다. 두 블록은 클래스 OID를 가리키는 표현만 다르다.

**영향**: 동작은 바뀌지 않는다. LOB 경로 prefix, 메타데이터 교체, 중복 복사를 막는 상태 표시 규칙을 바꿀 때 한 곳만 고치면 된다.

**이슈 수행 방안**: 복사 코드를 `heap_attrvalue_copy_lob` helper로 옮기고 두 함수가 호출하게 한다. ELO가 NULL일 때 함수 전체를 `S_SUCCESS`로 끝내는 기존 동작은 바꾸지 않고, 별도 확인 대상으로 남긴다.

---

## AI-Generated Context

- CBRD-27881의 OOS 리팩토링 후보 조사(`feature/oos-merge` dcbf09e4f 기준)에서 나온 세 번째 단위이다.
- 검증: OOS 관련 ctest 44개가 변경 전후 모두 통과했다. `OosSqlDeferredWrite.LobPreparationPreservesSourceAndDestinationValues`를 gdb로 실행해, 두 호출부가 모두 새 helper를 거치는 것을 확인했다.
- 진행 중인 CBRD-27860(PR #8350)은 같은 위치에 함수를 추가하므로, 나중에 병합되는 쪽에서 단순한 충돌 하나를 해결해야 한다.
