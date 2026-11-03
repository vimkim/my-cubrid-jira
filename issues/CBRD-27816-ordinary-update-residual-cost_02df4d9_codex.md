# [OOS] [TODO] 일반 UPDATE의 잔여 CPU 비용과 측정 변동 분석 및 개선

**한 줄 요약**: CBRD-27785 개선 뒤에도 일반 UPDATE가 +2% 목표를 넘던 원인을 PR #8299 head에서 분석했다. 정상 상태 차이(+1.34%)와 비동기 vacuum이 만든 후반 spike를 구분했고, 이번 범위에서 엔진 코드를 바꾸지 않기로 한 결정과 남은 연속 UPDATE 측정을 기록한다.

## Issue Triage

**이슈 수행 목적**: 일반 테이블 UPDATE에서 남은 server user-space instructions 증가와 후반 측정 변동을 규명하고, 후속 개선의 효과를 두 일반 SELECT와 함께 검증한다.

**이슈 수행 이유**: CBRD-27785의 개선 후보는 실행 이력을 맞춘 새 DB에서 UPDATE 약 +1.67%를 보였지만, 뒤의 별도 plain batch에서는 +5.0158%였다. 기존 +2% 목표를 모든 검증에서 충족하지 못했으므로 잔여 작업을 별도로 추적한다.

**영향**: OOS 값을 저장하지 않는 일반 테이블의 UPDATE도 instructions를 약 1.3% 더 쓴다(2026-11-03 측정). 같은 UPDATE를 재도 vacuum이 측정 구간에 들어오는 정도에 따라 표본이 최대 약 6% 커질 수 있어, 엔진 개발자와 QA가 재검증할 때 +2% 판정이 실행마다 달라진다. 실제 서비스의 처리량 영향은 미확인이다.

**이슈 수행 방안**: 2026-11-03 분석 결과 고칠 한 곳이 없어, 작성자가 이번 범위에서는 엔진 코드를 바꾸지 않기로 결정했다. 같은 표를 연속으로 UPDATE하는 측정은 아직 하지 않았고 이 이슈에서 계속 추적한다.

---

## AI-Generated Context

> 아래는 2026-10-28의 구현·측정 기록과 2026-11-03의 분석·작성자 결정을 바탕으로 작성한 상세 맥락이다. 측정값, 추정, 미확인 사항을 구분한다.

## Description

### 무엇이 문제인가 (2026-10-28 기록)

[CBRD-27785](https://jira.cubrid.org/browse/CBRD-27785)는 OOS 도입에 따른 성능 회귀를 추적한다. 일반 heap/OOS 공통 reader를 유지하면서 반복 layout 계산과 불필요한 pending owner 생성을 줄인 후보를 검증했다.

기준은 develop `4781495f01523a3ecc5891e3377ad62cf876a1cd`, OOS 출발점은 `dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67`, 측정 후보는 로컬 commit `02df4d9fe2d1f24168a18eda8d8be216e2c4ed99`이다. 후보와 기준의 server user-space instructions 중앙값을 비교한 결과는 다음과 같다. 최종 PR revision의 결과는 아래 Analysis Result에서 따로 쟀다.

| 측정 | 후보 / develop |
| --- | ---: |
| 일반 풀 스캔, 통제한 네 라운드 합계 | +0.6498% |
| 일반 조건 스캔, 같은 라운드 | +1.3624% |
| 일반 UPDATE, 매번 새 복제본, 같은 라운드 | +1.6656% |
| 일반 UPDATE, 연속 COMMIT 별도 표본 | +1.6622% |
| 네 라운드 뒤의 별도 plain UPDATE batch | +5.0158% |

각 라운드는 5회 중 첫 회를 버렸고 실행 순서를 번갈아 비교했다. 새 복제본과 연속 UPDATE 표본은 합치지 않았다. +5.0158% batch에서도 대응 테이블의 200,000행, 평균 92B, 1,429 heap pages와 OID/HFID, 설정 및 1GiB physical active log가 같았다. 앞선 탐색 DB의 이력 차이만으로 이 결과를 설명할 수 없다.

### 왜 문제인가

통제한 라운드만 보면 기존 +2% 목표를 만족하지만, 뒤의 유효한 plain batch까지 포함하면 전체 통과로 판정할 수 없다. 2026-10-28에는 실행 구간 안의 고정 추가 비용과 vacuum·log flush 등 background 작업의 기여를 나눌 근거가 부족했다.

별도 역순 진단에서는 기준 서버의 vacuum이 약 103M instructions를 사용한 표본이 있었다. 2026-10-28에는 이를 background 작업이 좁은 차이의 판정에 영향을 줄 수 있다는 관측으로만 기록했다. 2026-11-03 분석은 아래 "후반 spike의 출처"에 있다.

### 왜 해결해야 하는가

작성자는 현재 관측된 약 5% 증가를 수용하고 이번 개선분을 `feature/oos-merge` 대상 PR로 먼저 진행하기로 했다. 이는 현재 편입 범위에 대한 작성자 결정이며, 기존 +2% 목표 달성이나 리뷰어 승인으로 해석하지 않는다. 현재 PR의 진행과 잔여 성능 조사를 분리해 이미 확보한 개선을 검토하면서도 남은 비용을 누락하지 않도록 한다.

후속은 [CBRD-26978 [OOS] [EPIC] TODO](https://jira.cubrid.org/browse/CBRD-26978)의 Sub-task로 관리하고 CBRD-27785와 `relates to`로 연결한다. 별도 구현 PR을 제출할 때 이 이슈 번호를 사용한다.

## Analysis Result (2026-11-03)

상세 근거와 명령, 원자료 위치는 [1단계 분석 보고서](https://github.com/vimkim/my-cubrid-docs/blob/fcca125a1d06fdc24bcc0072fb8ab2e65efb31bb/cbrd-27785/CBRD-27816-ordinary-update-phase1.md)에 있다.

### 측정 조건

- 기준은 develop `4781495f01523a3ecc5891e3377ad62cf876a1cd`, 후보는 [PR #8299](https://github.com/CUBRID/cubrid/pull/8299) head `4c3c8d791ee619ad61701eff9555bc9ef27d9994`다. 10-28의 `02df4d9fe`와 다른 revision이다.
- 둘 다 release build이고 `UNIT_TEST_*`가 모두 OFF이며 compile flag가 같다. DB는 데이터 2GiB, active log 1GiB다. 표는 200,000행이다.
- 계수는 `perf stat --per-thread -e instructions:u -p <server pid>`로 PR의 `ordinary.py`와 같은 구간을 쟀다. 구간은 csql 하나(UPDATE와 COMMIT)이고 csql 종료에서 끝난다.
- 실행 순서를 번갈아 8라운드를 쟀다. block마다 첫 회를 버렸고, UPDATE마다 새 복제본을 썼다. 유지 표본은 한쪽당 36개다.

### 정상 상태 차이

| 경우 | 기준 중앙값 | 후보 중앙값 | 차이 |
| --- | ---: | ---: | ---: |
| UPDATE 서버 전체 | 6,471.55M | 6,558.33M | +86.8M (+1.34%) |
| UPDATE transaction worker | | | +86.2M |
| UPDATE log-flush | 379.74M | 379.86M | +0.1M |
| 일반 풀 스캔 | 250.87M | 248.88M | −0.79% |
| 일반 조건 스캔 | 531.56M | 535.97M | +0.83% |

차이는 UPDATE를 실행하는 transaction worker 하나에 있다. log 양은 양쪽이 같다(UPDATE당 57.750MB 대 57.754MB).

### 후반 spike의 출처

- UPDATE 하나는 COMMIT 뒤에 비동기 vacuum 작업을 남긴다. vacuum 양은 기준 약 390M, 후보 약 425M instructions다(측정 구간을 csql 종료 뒤 3초까지 늘린 진단).
- vacuum의 일부가 csql 종료 전에 시작하면 그만큼 표본이 커진다. 관측한 spike는 17~361M이고, 모두 vacuum 전체량보다 작았다. vacuum이 다 들어오면 표본은 약 6.0~6.5% 커진다.
- 오래 떠 있는 기준 서버에서 호스트 전체 CPU가 100%가 된 뒤, 12개 표본 모두에 vacuum 135~316M가 들어왔다. 10-28의 후반 spike와 같은 모양이다. 그러나 vacuum이 들어오는 정확한 시점과 빈도는 확인하지 못했다.
- "vacuum-master spike"는 별도 원인이 아니다. 구간 중에 생긴 vacuum worker의 계수를 perf가 부모 thread(vacuum-master)에 합친 것이다.
- 기각한 가설은 log archive 생성, 호스트가 느린 것 자체, 후보 vacuum이 기준의 2배라는 가설, 중단 job 재시도, 크기 기준 checkpoint다.
- 후보 vacuum은 UPDATE 하나당 +34.6M(+8.9%) 더 쓴다. 대부분 `vacuum_process_log_record`(+21.7M)에 있다. PR이 `RVHF_UPDATE_NOTIFY_VACUUM` record에서도 undo를 풀어 OOS를 검사하기 때문이다(`src/query/vacuum.c:4276`, `4c3c8d791`). OOS reclaim 변경은 이 이슈의 범위 밖이다.

### 정상 상태 차이의 구성

transaction worker의 profile(`perf record -e instructions:u -c 3000017 --call-graph fp`)로 나눴다. 값은 UPDATE 하나당 instructions다.

- **record 복사(+54M로 보였던 것)는 실제 증가가 아니다.** 기준 build는 `heap_get_record_data_when_all_ready`에서 `spage_get_record`를 tail call(`jmp`)로 부른다. 그래서 frame pointer 호출 사슬이 그 복사를 한 단계 위 함수에 귀속했다. 두 build의 기계어로 확인했다. `heap_get_last_version` 전체로 보면 후보가 14.2M 적다.
- **OOS 값이 없는 행의 OOS 처리 약 +61M는 실제 비용이다.** 행 하나당 약 300 instructions가 여러 작은 검사에 흩어져 있다. `heap_oos_finalize_record` 31.5M, `heap_pending_record` 생성·소멸 18.8M, `heap_record_replace_oos_oids` 9.7M, 나머지 검사 8.3M다. pending record는 새 record의 소유자로 기준의 copy area 할당·해제를 대신하므로, 이 몫이 모두 OOS 비용은 아니다.
- **`heap_update_logical` 안의 +51.2M에는 한 원인이 없다.** 직접 callee 25개 이상에 1~11M씩 퍼져 있다. OOS 고유 검사는 `heap_oos_validate_disk_record`(+4.5M) 하나다. 나머지는 code 배치와 inlining 차이로 보인다(추정).
- PR이 줄인 몫(record 만들기 −44.7M, 속성 읽기 −21.8M, page fix −29.0M 등)이 위 증가를 상쇄한다.

OOS 명세에 따르면 stub이 없는 새 record에는 Expand하거나 새로 넣을 OOS 값이 없다. 그래서 OOS가 없는 행의 finalize를 빠른 경로로 바꾸는 것은 명세와 충돌하지 않는다. 다만 효과는 약 20~30M(정상 상태 +1.34%를 약 +0.9~1.0%로)로 추정되고, 재지 않았다. spike는 vacuum 시점 때문이므로 이 변경으로 바뀌지 않는다.

### +2% 판정과 작성자 결정

- 기존 계수 구간에서 정상 상태 값(+1.34%)은 +2% 안이다. 그러나 표본에 spike가 들어오면 +2%를 넘을 수 있으므로, +2% 목표는 미충족으로 남는다.
- vacuum을 늘 포함하도록 csql 종료 뒤 3초를 더한 진단 지표에서는 +1.76~1.82%다.
- 2026-11-03 작성자 결정은 다음과 같다.
  - 판정은 기존 계수 구간 그대로 한다. vacuum 비용과 꼬리 구간 지표는 별도 줄로 보고한다.
  - 위 빠른 경로를 포함해 이번 범위에서는 엔진 코드를 바꾸지 않는다.

### 미확인 사항

- 같은 표를 연속으로 UPDATE하는 측정은 하지 않았다. 현재 `ordinary.py`는 UPDATE마다 새 복제본만 지원한다.
- vacuum이 csql 종료 전에 들어오는 정확한 시점과, 10-28처럼 spike가 잦아지는 조건.
- checkpoint 뒤 서버는 21~22초 동안 idle이 되지 않는다. 이것이 `ordinary.py`의 idle 대기 마감 10초보다 길어서, 오래 떠 있는 서버에서는 측정이 멈출 수 있다(양쪽 공통).
- 위 빠른 경로의 실제 효과.

## Scope

동일한 UPDATE+COMMIT 구간의 전체 서버 instructions와 per-thread profile을 맞춰 잔여 비용과 변동 원인을 구분한다. profiler 시작·종료가 계수 구간을 넓힌 진단 결과는 plain 측정과 합치지 않는다. 성공한 표본만 골라내거나 background 작업을 끄는 방식으로 통과시키지 않는다.

OOS reclaim tail은 독립 재현·정합성 검증이 필요한 별도 작업이다. allocator 변경과 threshold parameter 작업, 기존 기준 2도 이 이슈의 범위에 포함하지 않는다. 공통 heap/OOS reader와 MVCC, recovery, ownership, identity 검사, COPY 의미는 유지한다.

## Implementation

2026-11-03 작성자 결정에 따라 이번 범위에서는 엔진 코드를 바꾸지 않는다. 위 빠른 경로가 필요해지면 별도로 다룬다.

## Acceptance Criteria

- 후반 비용 증가를 같은 계수 구간의 근거로 설명하고, 재현 조건과 미확인 조건을 구분한다.
  - 2026-11-03: spike의 크기는 비동기 vacuum으로 설명했다. 정확한 시점과 빈도는 미확인이다.
- 기존 일반 UPDATE와 두 SELECT의 +2% 목표를 후속 검증 대상으로 유지한다. 최종 판정 범위와 수용 기준을 ANALYSIS에서 명시하며, 기준 변경이 필요하면 작성자 결정과 함께 기록한다.
  - 2026-11-03: 두 SELECT는 +2% 안이다. UPDATE는 정상 상태 +1.34%이지만 spike 때문에 미충족이다. 판정 구간은 바꾸지 않기로 결정했다.
- production test-OFF 빌드에서 실제 compiler flags, binary identity, live configuration, physical log 크기를 확인한다. 실행 순서를 번갈아 5회 측정하고 첫 회를 제외하며, 새 복제본과 연속 UPDATE 결과 및 유효한 실패를 모두 보고한다.
  - 2026-11-03: 새 복제본 측정과 유효한 실패는 보고했다. 연속 UPDATE 측정이 남았다.
- 코드 변경 시 focused correctness와 두 SELECT를 다시 검증한다. 기존 native test의 addr2line 도구 선택을 유지하고 timeout이나 assertion을 완화하지 않는다.
  - 2026-11-03: 코드 변경이 없어 해당하지 않는다.

## Triage Request

이번 범위에서 엔진 코드를 바꾸지 않는다는 작성자 결정을 확인한다. 이 이슈는 연속 UPDATE 측정을 마칠 때까지 열어 둔다. 로컬 추적은 Work 571이다. 로컬 Work 번호는 JIRA issue key를 대체하지 않는다.
