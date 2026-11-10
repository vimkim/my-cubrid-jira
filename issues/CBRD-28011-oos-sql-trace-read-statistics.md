# [OOS] SQL trace에서 heap 읽기와 OOS 읽기 비용을 구분한다

**한 줄 요약**: PR #7990에서 heap scan trace에 합산되는 OOS 읽기 비용을 별도로 확인할 수 있게 해 달라는 요청이 있어, 읽기 통계 구분을 후속 작업으로 추적한다.

## Issue Triage

**이슈 수행 목적**: SQL trace에서 heap 페이지와 OOS 페이지를 읽는 비용을 구분하여 쿼리 튜닝과 문제 분석에 활용한다.

**이슈 수행 이유**: PR #7990의 shparkcubrid 요청에 따르면 heap scan trace의 `fetch`, `ioread`, `time`에 OOS 페이지 읽기가 합산되어 두 비용을 구분할 수 없다.

**영향**: 큰 컬럼 값을 행 밖에 저장하는 OOS 테이블을 분석할 때, trace의 읽기 비용이 heap 접근에서 발생했는지 OOS 값 읽기에서 발생했는지 판단하기 어렵다. 영향의 빈도나 크기는 측정하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

SQL trace는 실행 중 발생한 읽기 횟수와 시간을 보고 쿼리의 비용을 분석하는 데 사용한다. OOS는 큰 컬럼 값을 heap 행 밖의 별도 파일에 저장하므로, heap 페이지 접근 비용과 OOS 값 읽기 비용을 구분할 수 있어야 튜닝 대상을 판단할 수 있다.

[PR #7990의 요청 댓글](https://github.com/CUBRID/cubrid/pull/7990#issuecomment-6625292994)에서 shparkcubrid는 heap scan trace의 `fetch`, `ioread`, `time`에 OOS 페이지 읽기가 함께 합산된다고 보고했다. 이 이슈는 해당 요청을 기록한 것이며, 등록 단계에서 엔진 실행이나 소스 분석으로 독립 재현하지 않았다.

[OOS 도입 이슈 CBRD-26357](https://jira.cubrid.org/browse/CBRD-26357)의 후속 개선으로, [OOS TODO CBRD-26978](https://jira.cubrid.org/browse/CBRD-26978)의 하위 작업에서 추적한다. PR #7990 병합을 막는 조건이나 수행 기한은 이 요청에서 정하지 않았다.

## Analysis

`fetch`, `ioread`, `time`의 현재 집계 범위와 계측 위치를 확인한다. heap 통계와 OOS 통계의 포함 관계, 시간의 의미, 지원하는 trace 출력 형식을 검토하여 표시 방식을 결정한다.

## Acceptance criteria

- SQL trace에서 heap 페이지 읽기와 OOS 페이지 읽기의 `fetch`, `ioread`, `time`을 구분하여 확인할 수 있다.
- 각 지표의 집계 범위와 기존 heap scan 합계와의 관계를 설명하여 중복 합산이나 오해를 방지한다.
- OOS 값을 실제로 읽는 조회와 읽지 않는 조회를 비교하여 통계 구분을 검증한다. OOS를 사용하지 않는 조회의 통계와 쿼리 결과도 확인한다.
