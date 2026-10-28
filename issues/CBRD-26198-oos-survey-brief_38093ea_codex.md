## Goal

불필요한 대용량 컬럼 읽기를 줄이는 OOS 도입을 위해 타 DBMS의 저장 방식과 CUBRID의 적용 가능성을 조사한다.

## Scope

- [타 DBMS 조사(CBRD-26262)](http://jira.cubrid.org/browse/CBRD-26262): O사·P사·M사와 기타 DBMS의 대용량 컬럼 저장 구조, 사용자 제어 방식과 한계를 비교하고 요구사항을 정리한다.
- [CUBRID 코드 분석(CBRD-26287)](http://jira.cubrid.org/browse/CBRD-26287): heap·overflow의 저장·조회·갱신·삭제 경로를 분석하여 OOS의 구현 위치와 구조를 구상한다. 트랜잭션·복구·복제·HA 연계도 검토한다.

## Limitations

- 조사·개념 설계와 개념 검증용 POC까지를 범위로 한다. 제품 구현과 성능·정합성 검증은 [후속 개발(CBRD-26357)](http://jira.cubrid.org/browse/CBRD-26357)에서 수행한다.
- 압축·중복 제거·지원 타입·제어 옵션은 검토 항목이며, 이 조사만으로 최종 지원 사양을 확정하지 않는다.

세부 조사 결과와 설계안은 아래 하위 작업에서 관리한다.
