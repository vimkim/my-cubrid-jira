**후속 작업 모음**: [CBRD-26978 — OOS TODO Epic](https://jira.cubrid.org/browse/CBRD-26978)

## Description

대용량 컬럼 값을 행 외부의 OOS(Out-of-row Overflow Storage) 파일에 저장하는 기능을 도입한다. 필요한 컬럼만 읽도록 하여 큰 값을 포함한 테이블의 조회 I/O와 힙 페이지 사용량을 줄이는 것이 목적이다.

저장·조회와 트랜잭션 처리, 복구·HA, vacuum·공간 회수, 관련 도구 및 회귀 검증을 포함한다.

## Related Work

- 사전 조사: [CBRD-26198](https://jira.cubrid.org/browse/CBRD-26198)
- M1 — 기본 기능: [CBRD-26584](https://jira.cubrid.org/browse/CBRD-26584)
- M2 — 운영 품질: [CBRD-26583](https://jira.cubrid.org/browse/CBRD-26583)
- develop 병합 준비 및 회귀 검증: [CBRD-26835](https://jira.cubrid.org/browse/CBRD-26835)
- 엔진 PR: [CUBRID/cubrid#7990](https://github.com/CUBRID/cubrid/pull/7990)
