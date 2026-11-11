# [OOS] growth lock 대기 중 질의 취소와 서버 종료에 응답하도록 개선

**한 줄 요약**: [PR #8434](https://github.com/CUBRID/cubrid/pull/8434)의 코드 리뷰 U-1에서 지적한 OOS growth lock 대기가 인터럽트를 확인하지 않는 문제를 분리해, 질의 취소와 서버 종료 요청에 응답하도록 개선한다.

## Issue Triage

**이슈 수행 목적**: OOS 파일의 성장을 기다리는 스레드가 질의 취소나 서버 종료 요청을 확인하고 대기를 중단할 수 있게 한다.

**이슈 수행 이유**: `oos_reclaim_claim_growth`는 같은 OOS 파일의 다른 성장자가 작업 중이면 timeout 없는 `pthread_cond_wait`를 호출한다. 대기 경로에 인터럽트 확인이 없어 취소·종료 요청만으로는 대기에서 빠져나올 수 없다. PR #8434와 분리한 응답성 후속 작업으로 추적한다.

**영향**: 큰 값을 저장하는 질의를 취소하는 사용자와 서버를 종료하는 운영자는 다른 성장자의 페이지 할당이나 빈 페이지 검사가 끝날 때까지 기다릴 수 있다. 이는 소스 분석에 따른 영향이다. 실제 취소·종료 지연과 발생 빈도는 측정하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

[OOS TODO CBRD-26978](https://jira.cubrid.org/browse/CBRD-26978)의 하위 작업으로 다룬다. OOS는 큰 컬럼 값을 행 밖의 전용 파일에 저장한다. Growth lock은 같은 OOS 파일에서 빈 페이지 회수 검사와 새 페이지 할당을 한 스레드만 진행하도록 하는 파일별 상태다. Lap은 회수 가능한 빈 페이지를 찾기 위해 파일의 페이지를 한 바퀴 검사하는 작업이다.

PR #8434 head `443073283d89e4511b2fa9a5b6a16898770f7e65`에서 확인한 경로는 다음과 같다.

1. [`oos_find_best_page`](https://github.com/CUBRID/cubrid/blob/443073283d89e4511b2fa9a5b6a16898770f7e65/src/storage/oos_file.cpp#L3244-L3246)가 기존 페이지를 찾지 못하면 `oos_alloc_page_with_reclaim`을 호출한다.
2. [`oos_reclaim_claim_growth`](https://github.com/CUBRID/cubrid/blob/443073283d89e4511b2fa9a5b6a16898770f7e65/src/storage/oos_file.cpp#L1800-L1838)는 파일별 `sweep_in_progress`를 확인한다. 다른 성장자가 있으면 `bestspace_mutex`와 조건 변수 `oos_Reclaim_sweep_cond`로 대기한다. `pthread_cond_wait`에 timeout이 없고, 반복문에도 인터럽트 확인이 없다.
3. 성장자는 [`oos_alloc_page_with_reclaim`](https://github.com/CUBRID/cubrid/blob/443073283d89e4511b2fa9a5b6a16898770f7e65/src/storage/oos_file.cpp#L2102-L2133)에서 growth lock을 잡은 채 회수 검사와 `oos_file_alloc_new`를 수행한다. 따라서 대기자가 정상 경로로 진행하려면 앞선 성장자의 검사와 `file_alloc`이 끝나야 한다.
4. [`oos_reclaim_release_sweep_locked`](https://github.com/CUBRID/cubrid/blob/443073283d89e4511b2fa9a5b6a16898770f7e65/src/storage/oos_file.cpp#L1360-L1375)가 파일별 상태를 해제하고 broadcast한다. 모든 OOS 파일이 조건 변수 하나를 공유하므로 다른 파일의 해제로 깨어나도 자기 파일의 상태를 다시 확인한다.

이 문제는 대기자가 인터럽트를 확인할 기회를 얻지 못하는 경로를 다룬다. 성장자 자체의 `file_alloc`이나 lap 실행 시간을 이 작업의 측정된 대기 시간으로 취급하지 않는다. 실제 서버에서 취소·종료 지연을 재현한 결과는 없다.

## Existing Evidence

[리뷰 U-1](https://github.com/vimkim/my-cubrid-docs/blob/main/cbrd-27781/code-review-pr8434-8e139f4/report.md#unverified-risks-all-p3-source-only-unless-stated)은 같은 대기 경로의 timeout·인터럽트 확인 부재와 조건 변수 공유를 지적했다. 리뷰의 분석 대상은 `8e139f4db`이며, 위의 현재 head에서도 대기 경로를 소스로 확인했다.

2026-11-11 [growth lock 측정 보고서](https://github.com/vimkim/my-cubrid-docs/blob/0de0c40829f660ac9da1fa082cad7550804c2623/cbrd-27781/perf-growth-lock.md)는 한 OOS 파일에 동시 INSERT하는 부하에서 처리량 회귀를 구별하지 못했다. 아래 수치는 기존 보고서의 결과이며 이 이슈 작성 중 재측정하지 않았다. 비교 대상은 base `c255c7c3b`와 head `8e139f4db`다.

| 동시 세션 수 | head의 처리량 차이 | 순열 검정 p |
| --- | --- | --- |
| 16 | -0.4% | 0.88 |
| 32 | -1.1% | 0.45 |
| 64 | +3.6% | 0.72 |

보고서는 이 부하의 주된 경합 지점을 OOS 헤더 페이지 래치로 판단했고, futex herd 신호를 관측하지 못했다. 취소·종료 지연, 여러 OOS 파일의 동시 성장, 빈 페이지 집합의 4096페이지 상한을 넘은 뒤 긴 lap의 비용은 측정 범위 밖이다. 따라서 이 이슈의 개선 근거는 취소·종료 응답성이며, 처리량 개선을 약속하지 않는다.

## Analysis

해결 방안은 아직 선택하지 않았다.

| 후보 | 기대 효과 | 한계와 확인 사항 |
| --- | --- | --- |
| 일정 시간마다 대기에서 깨어나 인터럽트를 확인하고 `ER_INTERRUPTED`를 반환한다. | 다른 성장자의 완료를 기다리는 동안에도 취소·종료 요청을 확인할 기회를 만든다. | 확인 주기와 오류 전달 경로를 정해야 한다. 대기 중단 뒤 mutex와 파일별 상태가 올바른지 검증해야 한다. |
| 파일별 조건 변수를 둔다. | 다른 OOS 파일의 해제로 인한 불필요한 깨우기를 줄일 수 있다. | 여러 파일에서의 효과는 미측정이다. 조건 변수를 나누는 것만으로 인터럽트 확인 부재가 해결되지는 않는다. |

첫 후보는 대기 중단의 기회를 만들고, 둘째 후보는 깨우는 대상의 범위를 줄인다. 파일별 조건 변수의 필요성은 별도 측정으로 판단하며, 어느 후보도 확정된 구현 방향으로 취급하지 않는다.

Growth lock을 `file_alloc`까지 유지하는 것은 정확성 요구다. 다른 성장자가 회수 검사와 할당 사이에 섹터를 예약하지 못하게 해야 한다. 응답성 개선 후에도 이 보호 범위를 유지한다.

## Acceptance Criteria

- 같은 OOS 파일의 다른 성장자를 기다리는 스레드가 질의 취소와 서버 종료 요청에 응답해 대기를 중단한다. ANALYSIS에서 응답 시간의 판정 기준을 정하고, 다른 성장자의 완료 전 중단 여부와 실제 지연을 검증한다.
- 정상 진행과 대기 중단 뒤에도 mutex·growth lock 상태가 정리된다. 회수 검사부터 `file_alloc`까지의 보호와 성장 전 빈 페이지 회수·재사용 요구를 유지한다.
- 기존 미측정 항목을 구분해 결과를 기록한다. 파일별 조건 변수 같은 추가 변경은 응답성 문제 해결에 필요한지 근거로 판단한다.

## Related Issues

- [CBRD-27925](https://jira.cubrid.org/browse/CBRD-27925)는 빈 페이지 회수·재사용과 재시도를 다룬다. Growth lock 구현의 배경이며, 이 이슈는 그 대기자의 취소·종료 응답성을 분리한다.
- [CBRD-27872](https://jira.cubrid.org/browse/CBRD-27872)는 성장 시 빈 페이지 검사 비용을 다룬다. 여기서는 검사량 자체의 상한을 새로 정하지 않는다.
- [CBRD-28017](https://jira.cubrid.org/browse/CBRD-28017)은 `oos_find_best_page`의 헤더 접근 실패에서 이미 발생한 인터럽트를 버리는 문제다. 이 이슈의 조건 변수 대기 중 인터럽트 미확인과는 발생 지점과 필요한 검증이 다르다.
