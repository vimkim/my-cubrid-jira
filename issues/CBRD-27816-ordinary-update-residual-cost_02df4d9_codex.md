# [OOS] [TODO] 일반 UPDATE의 잔여 CPU 비용과 측정 변동 분석 및 개선

## Issue Triage

**이슈 수행 목적**: 일반 테이블 UPDATE에서 남은 server user-space instructions 증가와 후반 측정 변동을 규명하고, 후속 개선의 효과를 두 일반 SELECT와 함께 검증한다.

**이슈 수행 이유**: CBRD-27785의 개선 후보는 실행 이력을 맞춘 새 DB에서 UPDATE 약 +1.67%를 보였지만, 뒤의 별도 plain batch에서는 +5.0158%였다. 기존 +2% 목표를 모든 검증에서 충족하지 못했으므로 잔여 작업을 별도로 추적한다.

**영향**: OOS 값을 저장하지 않는 일반 테이블의 갱신에도 비용이 남는다. 변동 원인을 구분하지 못하면 엔진 개발자와 QA가 재검증할 때 개선 효과를 일관되게 판정하기 어렵다. 실제 서비스의 발생 빈도와 처리량 영향은 미확인이다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 원인과 해결 방안, 구현 범위를 결정한다.

---

## AI-Generated Context

> 아래는 2026-10-28의 구현·측정 기록과 작성자 결정을 바탕으로 작성한 상세 맥락이다. 원인이 확인되지 않은 변동은 관측 결과와 구분한다.

## Description

### 무엇이 문제인가

[CBRD-27785](https://jira.cubrid.org/browse/CBRD-27785)는 OOS 도입에 따른 성능 회귀를 추적한다. 일반 heap/OOS 공통 reader를 유지하면서 반복 layout 계산과 불필요한 pending owner 생성을 줄인 후보를 검증했다.

기준은 develop `4781495f01523a3ecc5891e3377ad62cf876a1cd`, OOS 출발점은 `dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67`, 측정 후보는 로컬 commit `02df4d9fe2d1f24168a18eda8d8be216e2c4ed99`이다. 후보와 기준의 server user-space instructions 중앙값을 비교한 결과는 다음과 같다. 최종 PR revision의 결과는 별도로 검증해야 한다.

| 측정 | 후보 / develop |
| --- | ---: |
| 일반 풀 스캔, 통제한 네 라운드 합계 | +0.6498% |
| 일반 조건 스캔, 같은 라운드 | +1.3624% |
| 일반 UPDATE, 매번 새 복제본, 같은 라운드 | +1.6656% |
| 일반 UPDATE, 연속 COMMIT 별도 표본 | +1.6622% |
| 네 라운드 뒤의 별도 plain UPDATE batch | +5.0158% |

각 라운드는 5회 중 첫 회를 버렸고 실행 순서를 번갈아 비교했다. 새 복제본과 연속 UPDATE 표본은 합치지 않았다. +5.0158% batch에서도 대응 테이블의 200,000행, 평균 92B, 1,429 heap pages와 OID/HFID, 설정 및 1GiB physical active log가 같았다. 앞선 탐색 DB의 이력 차이만으로 이 결과를 설명할 수 없다.

### 왜 문제인가

통제한 라운드만 보면 기존 +2% 목표를 만족하지만, 뒤의 유효한 plain batch까지 포함하면 전체 통과로 판정할 수 없다. 실행 구간 안의 고정 추가 비용과 vacuum·log flush 등 background 작업의 기여를 나눌 근거가 부족하다. 뒤에 수집한 profile은 실패 batch와 다른 실행이므로 그 실패의 직접 원인 증거로 사용할 수 없다.

별도 역순 진단에서는 기준 서버의 vacuum이 약 103M instructions를 사용한 표본이 있었다. 이는 background 작업이 좁은 차이의 판정에 영향을 줄 수 있다는 관측이며, 후보의 +5.0158% 원인을 vacuum으로 확정한 결과는 아니다.

### 왜 해결해야 하는가

작성자는 현재 관측된 약 5% 증가를 수용하고 이번 개선분을 `feature/oos-merge` 대상 PR로 먼저 진행하기로 했다. 이는 현재 편입 범위에 대한 작성자 결정이며, 기존 +2% 목표 달성이나 리뷰어 승인으로 해석하지 않는다. 현재 PR의 진행과 잔여 성능 조사를 분리해 이미 확보한 개선을 검토하면서도 남은 비용을 누락하지 않도록 한다.

후속은 [CBRD-26978 [OOS] [EPIC] TODO](https://jira.cubrid.org/browse/CBRD-26978)의 Sub-task로 관리하고 CBRD-27785와 `relates to`로 연결한다. 별도 구현 PR을 제출할 때 이 새 이슈 번호를 사용한다.

## Scope

동일한 UPDATE+COMMIT 구간의 전체 서버 instructions와 per-thread profile을 맞춰 잔여 비용과 변동 원인을 구분한다. profiler 시작·종료가 계수 구간을 넓힌 진단 결과는 plain 측정과 합치지 않는다. 성공한 표본만 골라내거나 background 작업을 끄는 방식으로 통과시키지 않는다.

OOS reclaim tail은 독립 재현·정합성 검증이 필요한 별도 작업이다. allocator 변경과 threshold parameter 작업, 기존 기준 2도 이 이슈의 범위에 포함하지 않는다. 공통 heap/OOS reader와 MVCC, recovery, ownership, identity 검사, COPY 의미는 유지한다.

## Implementation

TBD - ANALYSIS 단계에서 결정한다. 먼저 소스를 고정하고 실패 이력을 재현해 동일 구간의 비용을 수집한다. 원인 근거가 확보된 뒤 개선 후보를 비교한다.

## Acceptance Criteria

- 후반 비용 증가를 같은 계수 구간의 근거로 설명하고, 재현 조건과 미확인 조건을 구분한다.
- 기존 일반 UPDATE와 두 SELECT의 +2% 목표를 후속 검증 대상으로 유지한다. 최종 판정 범위와 수용 기준을 ANALYSIS에서 명시하며, 기준 변경이 필요하면 작성자 결정과 함께 기록한다.
- production test-OFF 빌드에서 실제 compiler flags, binary identity, live configuration, physical log 크기를 확인한다. 실행 순서를 번갈아 5회 측정하고 첫 회를 제외하며, 새 복제본과 연속 UPDATE 결과 및 유효한 실패를 모두 보고한다.
- 코드 변경 시 focused correctness와 두 SELECT를 다시 검증한다. 기존 native test의 addr2line 도구 선택을 유지하고 timeout이나 assertion을 완화하지 않는다.

## Triage Request

잔여 일반 UPDATE 성능 조사를 독립 후속으로 확인하고 작성자 측에 ANALYSIS 배정을 요청한다. 원인 규명 결과와 최종 PR revision에 대응하는 재현 자료를 남긴다. 선행 구현의 로컬 추적은 Work 564, 이 후속의 로컬 추적은 Work 571이다. 로컬 Work 번호는 JIRA issue key를 대체하지 않는다.
