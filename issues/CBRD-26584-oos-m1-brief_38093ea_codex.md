## Goal

대용량 가변 컬럼을 heap 밖에 저장하는 OOS의 기본 구조와 사용자 수준 동작을 구현·검증한다.

## Scope

- OOS 설계 조사, 저장소 및 생성·삽입·읽기 API, heap 연동을 구현한다.
- INSERT/SELECT/UPDATE/DELETE, WAL·복구·HA 복제와 covered index 연동을 지원한다.
- 개발자 테스트와 SQL/medium/shell/HA 테스트로 기능을 검증하고 성능을 측정한다.

## Limitations

- M1은 기본 기능을 확인하는 POC 단계다. 운영 품질 확보와 `develop` 병합은 [M2(CBRD-26583)](http://jira.cubrid.org/browse/CBRD-26583)에서 수행한다.
- vacuum 연동, DROP TABLE 자원 회수와 공간 재사용 개선은 M2 범위로 둔다.
- 압축·PEEK 등 추가 최적화는 포함하지 않는다.

세부 구현과 검증 결과는 아래 하위 작업에서 관리한다.
