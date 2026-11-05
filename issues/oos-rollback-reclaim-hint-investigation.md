# [OOS][조사] INSERT rollback과 빈 페이지 검사 경합으로 회수 힌트가 소실되는 후보 확인

**한 줄 요약**: TLA+ 탐색에서 INSERT rollback이 비운 페이지의 회수 표시가 사라지는 경합 경로를 발견하여, 실제 발생 조건과 필요한 보완을 조사한다.

## Issue Triage

**이슈 수행 목적**: rollback 뒤 안전하게 회수할 수 있는 빈 OOS 페이지가 후속 회수 검사에서 누락되는지 확인하고, 회수 작업의 재시도에 필요한 조건을 정한다.

**이슈 수행 이유**: INSERT undo는 페이지 WRITE 래치를 가진 채 삭제를 알린다. 이때 성장 경로의 sweep이 해당 페이지의 조건부 READ 획득에 실패하면 유예 건수에 반영하지 않고 지나간다. 한 바퀴 검사 뒤 시작 시점의 삭제 건수를 차감하면 회수 표시가 0이 되는 순서를 TLA+와 추출 소스 실행에서 확인했다.

**영향**: 큰 값을 반복 삽입하고 rollback하는 테이블에서 빈 페이지를 재사용할 기회가 누락되고 추가 공간 할당으로 이어질 가능성이 있다. 실제 DB 발생 여부와 빈도, 디스크 증가량은 미확인이다. 영구 누수로 단정하지 않는다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

확인한 엔진 소스는 `f67f2f692a7ad9f9efada2178759ca713e596b9d`다. 2026-11-04부터 11-05까지 수행한 검증에서 회수할 일을 나타내는 `pending_deletes`와 페이지 래치의 순서를 대조했다. 이 값은 실제 빈 페이지 목록이 아니라 후속 회수 검사를 시작하게 하는 파일별 메모리 힌트다.

소스에 연결한 유한 모델의 반례와 의존 함수를 대체한 추출 소스 실행을 확보했다. 실제 CUBRID 서버와 SQL을 통한 통합 재현은 수행하지 않았다. 조사 이슈 등록이 결함 확정이나 재현 착수 승인을 의미하지 않는다.

## Evidence

1. INSERT undo가 마지막 chunk를 삭제하고 WRITE 래치를 유지한 상태에서 삭제를 알린다. [삭제와 알림](https://github.com/CUBRID/cubrid/blob/f67f2f692a7ad9f9efada2178759ca713e596b9d/src/storage/oos_file.cpp#L3658-L3680)을 확인한다.
2. sweep이 알림 건수를 저장하고 해당 페이지의 조건부 READ 획득에 실패한다. [1차 검사](https://github.com/CUBRID/cubrid/blob/f67f2f692a7ad9f9efada2178759ca713e596b9d/src/storage/oos_file.cpp#L1587-L1611)는 이 실패를 유예 건수로 남기지 않는다.
3. rollback이 래치를 해제하고 끝난다. sweep은 다른 페이지를 검사하고 한 바퀴 정산에 도달한다.
4. [정산](https://github.com/CUBRID/cubrid/blob/f67f2f692a7ad9f9efada2178759ca713e596b9d/src/storage/oos_file.cpp#L1790-L1807)이 시작 건수를 차감하면서 `pending_deletes=0`, `swept_this_boot=true`가 된다. 후속 성장 호출이 빈 페이지를 남기고 회수 검사를 생략하는 모델 경로가 있다.

TLA+ 모델은 파일 1개, 데이터 페이지 2개, sweep 호출자 2개와 한 번의 삭제를 다룬다. `NoLostHint`의 최단 반례는 11개 전이다. 별도 `NoSkippedEmptyGrowth` 검사도 실패한다. 일반 삭제 경로와 부팅 뒤 첫 검사 대조군은 해당 유한 범위에서 통과했다. 이 결과는 모델의 조건에 대한 것이며 엔진 전체의 증명이 아니다.

추출 소스 실행은 페이지 검색과 선택적 bestspace 보충, sweep, 정산, undo callback, 할당 호출을 연결했다. 트랜잭션 관리자와 페이지 버퍼 등 일부 의존 함수는 대체했다. 표본 검색이 빈 페이지를 다시 찾는 대조군에서는 추가 할당을 피했다. 그러므로 모든 INSERT에서 발생하거나 항상 파일이 증가한다고 주장하지 않는다.

## Acceptance Criteria

- [ ] 팀장에게 실제 DB 재현의 목적, 환경과 실행 범위를 승인받고 승인 근거를 기록한다. 승인 전 서버·DB를 이용한 재현에 착수하지 않는다.
- [ ] 승인 후 동일 호출의 page emptiness, 래치 획득 결과, 삭제 알림, 시작 건수와 정산 결과를 연결해 후보를 확인하거나 기각한다.
- [ ] 후보가 성립하면 회수 표시 보존과 후속 재방문 조건을 정한다. 데이터 보존을 위한 LSA gate를 약화하지 않는다.
- [ ] 부분 여유 공간 재사용, 표본 재발견과 새 섹터 예약을 구분하여 실제 영향을 기록한다.

## Related Work

[CBRD-27925](https://jira.cubrid.org/browse/CBRD-27925)는 LSA gate에서 유예된 페이지의 재시도 문제를 다룬다. 이번 후보는 그 gate에 도달하기 전 READ 래치 획득 실패와 INSERT undo의 알림 순서를 특정한다. [CBRD-26786](https://jira.cubrid.org/browse/CBRD-26786)의 과거 2차 WRITE 획득 실패 수리와 같은 것으로 취급하지 않는다. [CBRD-27872](https://jira.cubrid.org/browse/CBRD-27872)는 회수 검사의 비용에 관한 별도 과제다.
