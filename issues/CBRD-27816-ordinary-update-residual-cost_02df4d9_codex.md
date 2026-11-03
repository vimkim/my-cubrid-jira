# [OOS] [TODO] 일반 UPDATE의 잔여 CPU 비용과 측정 변동 분석 및 개선

**한 줄 요약**: CBRD-27785 개선 뒤에도 일반 UPDATE의 성능 저하가 2% 목표를 넘던 원인을 PR #8299 head에서 분석했다. 늘 나타나는 저하(−1.34%)와 비동기 vacuum이 가끔 만드는 큰 저하를 구분했고, 이번 범위에서 엔진 코드를 바꾸지 않기로 한 결정과 남은 연속 UPDATE 측정을 기록한다.

## Issue Triage

**이슈 수행 목적**: 일반 테이블 UPDATE에 남은 CPU 비용과 후반 측정 변동을 규명하고, 후속 개선의 효과를 두 일반 SELECT와 함께 검증한다.

**이슈 수행 이유**: CBRD-27785의 개선 후보는 실행 이력을 맞춘 새 DB에서 UPDATE 성능이 약 −1.67%였지만, 뒤의 별도 plain batch에서는 −5.0158%였다. 성능 저하를 2% 이내로 두는 기존 목표를 모든 검증에서 충족하지 못했으므로 잔여 작업을 별도로 추적한다.

**영향**: OOS 값을 저장하지 않는 일반 테이블의 UPDATE도 CPU 명령어를 약 1.3% 더 쓴다(성능 −1.34%, 2026-11-03 측정). 또 vacuum이 측정 구간에 들어오는 정도에 따라 같은 UPDATE가 더 나쁘게 측정된다. 관측한 최악은 −5.0158%이고, 계산상 최악은 약 −7.9%다. 그래서 엔진 개발자와 QA가 재검증할 때 2% 판정이 실행마다 달라진다. 실제 서비스의 처리량 영향은 미확인이다.

**이슈 수행 방안**: 2026-11-03 분석 결과 고칠 한 곳이 없어, 작성자가 이번 범위에서는 엔진 코드를 바꾸지 않기로 결정했다. 같은 표를 연속으로 UPDATE하는 측정은 아직 하지 않았고 이 이슈에서 계속 추적한다.

---

## AI-Generated Context

> 아래는 2026-10-28의 구현·측정 기록과 2026-11-03의 분석·작성자 결정을 바탕으로 작성한 상세 맥락이다. 측정값, 계산값, 추정, 미확인 사항을 구분한다.

## Description

### 수치를 읽는 법

- **무엇을 세었나.** DB 서버 프로세스가 SQL 하나를 처리하는 동안 CPU가 실행한 명령어 수(user-space instructions)다. 같은 일을 하는 데 명령어가 적을수록 좋다. 실행 시간은 호스트 부하에 따라 흔들려서 판정에 쓰지 않는다. `M`은 백만 개다.
- **무엇을 비교했나.** 기준은 OOS가 없는 develop이고, 후보는 OOS를 통합하고 성능 개선을 더한 판이다. 같은 데이터와 같은 SQL로 양쪽을 번갈아 쟀다.
- **성능 변화.** (기준 명령어 수 − 후보 명령어 수) ÷ 기준 명령어 수로 계산한다. 후보가 명령어를 덜 쓰면 +(좋아짐), 더 쓰면 −(나빠짐)이다.
- **목표.** 후보의 성능 변화가 −2%보다 나쁘지 않아야 한다(성능 저하 2% 이내).
- **표.** 2026-11-03 측정 대상은 200,000행 일반 테이블 하나다. 열은 `id INT PRIMARY KEY`, `a INT`, `s VARCHAR(100)`이고, OOS 값은 없다.
- **주의.** PR #7990 리뷰어 원문처럼 이 규칙을 정하기 전에 쓴 PR·JIRA 댓글은 반대 부호를 쓴다. 그 기록에서는 명령어가 늘면 +다. 아래 링크한 분석 보고서는 이 문서와 같은 부호를 쓴다.

### 무엇이 문제인가 (2026-10-28 기록)

[CBRD-27785](https://jira.cubrid.org/browse/CBRD-27785)는 OOS 도입에 따른 성능 회귀를 추적한다. 일반 heap/OOS 공통 reader를 유지하면서 반복 layout 계산과 불필요한 pending owner 생성을 줄인 후보를 검증했다.

기준은 develop `4781495f01523a3ecc5891e3377ad62cf876a1cd`, OOS 출발점은 `dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67`, 측정 후보는 로컬 commit `02df4d9fe2d1f24168a18eda8d8be216e2c4ed99`이다. 값은 명령어 수의 중앙값으로 계산했다. 최종 PR revision의 결과는 아래 Analysis Result에서 따로 쟀다.

| 측정 | 무엇을 했나 | 성능 변화 | 뜻 |
| --- | --- | ---: | --- |
| 일반 풀 스캔 | 표 전체를 읽는 집계 SELECT, 통제한 네 라운드 합계 | −0.6498% | 조금 나빠졌다. 목표 안이다 |
| 일반 조건 스캔 | 모든 행의 문자열 열을 검사하는 SELECT, 같은 라운드 | −1.3624% | 나빠졌다. 목표 안이다 |
| 일반 UPDATE (새 복제본) | 매번 같은 내용의 새 표를 만들어 전체 행을 UPDATE하고 COMMIT, 같은 라운드 | −1.6656% | 나빠졌다. 목표 안이다 |
| 일반 UPDATE (연속) | 같은 표를 이어서 UPDATE하고 COMMIT, 별도 표본 | −1.6622% | 나빠졌다. 목표 안이다 |
| 일반 UPDATE (뒤의 별도 batch) | 네 라운드 뒤에 같은 UPDATE를 다시 잰 별도 plain batch | −5.0158% | 크게 나빠졌다. 목표 밖이다 |

각 라운드는 5회 중 첫 회를 버렸고 실행 순서를 번갈아 비교했다. 새 복제본과 연속 UPDATE 표본은 합치지 않았다. −5.0158% batch에서도 대응 테이블의 200,000행, 평균 92B, 1,429 heap pages와 OID/HFID, 설정 및 1GiB physical active log가 같았다. 앞선 탐색 DB의 이력 차이만으로 이 결과를 설명할 수 없다.

### 왜 문제인가

통제한 라운드만 보면 성능 저하 2% 이내 목표를 만족하지만, 뒤의 유효한 plain batch까지 포함하면 전체 통과로 판정할 수 없다. 2026-10-28에는 실행 구간 안의 고정 추가 비용과 vacuum·log flush 등 background 작업의 기여를 나눌 근거가 부족했다.

별도 역순 진단에서는 기준 서버의 vacuum이 약 103M instructions를 사용한 표본이 있었다. 2026-10-28에는 이를 background 작업이 좁은 차이의 판정에 영향을 줄 수 있다는 관측으로만 기록했다. 2026-11-03 분석은 아래 "가끔 나오는 큰 저하의 출처"에 있다.

### 왜 해결해야 하는가

작성자는 현재 관측된 약 5%의 성능 저하를 수용하고 이번 개선분을 `feature/oos-merge` 대상 PR로 먼저 진행하기로 했다. 이는 현재 편입 범위에 대한 작성자 결정이며, 2% 목표 달성이나 리뷰어 승인으로 해석하지 않는다. 현재 PR의 진행과 잔여 성능 조사를 분리해 이미 확보한 개선을 검토하면서도 남은 비용을 누락하지 않도록 한다.

후속은 [CBRD-26978 [OOS] [EPIC] TODO](https://jira.cubrid.org/browse/CBRD-26978)의 Sub-task로 관리하고 CBRD-27785와 `relates to`로 연결한다. 별도 구현 PR을 제출할 때 이 이슈 번호를 사용한다.

## Analysis Result (2026-11-03)

상세 근거와 명령, 원자료 위치는 [1단계 분석 보고서](https://github.com/vimkim/my-cubrid-docs/blob/fcca125a1d06fdc24bcc0072fb8ab2e65efb31bb/cbrd-27785/CBRD-27816-ordinary-update-phase1.md)에 있다.

### 측정 조건

- 기준은 develop `4781495f01523a3ecc5891e3377ad62cf876a1cd`, 후보는 [PR #8299](https://github.com/CUBRID/cubrid/pull/8299) head `4c3c8d791ee619ad61701eff9555bc9ef27d9994`다. 10-28의 `02df4d9fe`와 다른 revision이다.
- 둘 다 release build이고 `UNIT_TEST_*`가 모두 OFF이며 compile flag가 같다. DB는 데이터 2GiB, active log 1GiB다.
- 계수는 `perf stat --per-thread -e instructions:u -p <server pid>`로 PR의 `ordinary.py`와 같은 구간을 쟀다. 구간은 SQL 하나를 실행하는 csql 한 번이고, csql이 끝나면 계수도 끝난다.
- 실행 순서를 번갈아 8라운드를 쟀다. 라운드마다 첫 회를 버렸고, UPDATE는 매번 새 복제본에서 했다. 남긴 UPDATE 표본은 한쪽당 36개다.

### 늘 나타나는 차이

| 측정 | 실행한 SQL | 기준 (develop) | 후보 (PR #8299) | 성능 변화 | 뜻 |
| --- | --- | ---: | ---: | ---: | --- |
| 일반 UPDATE | `UPDATE t SET a=a+1; COMMIT;` (전체 200,000행) | 6,472M (행당 32,358) | 6,558M (행당 32,792) | −1.34% | 행 하나를 고칠 때 명령어를 434개 더 쓴다. 목표 안이다 |
| 일반 풀 스캔 | `SELECT COUNT(*), SUM(a) FROM t;` | 250.9M (행당 1,254) | 248.9M (행당 1,244) | +0.79% | 행 하나를 읽을 때 10개 덜 쓴다. 조금 좋아졌다 |
| 일반 조건 스캔 | `SELECT COUNT(*) FROM t WHERE SUBSTR(s,30,1)='a';` | 531.6M (행당 2,658) | 536.0M (행당 2,680) | −0.83% | 행 하나를 검사할 때 22개 더 쓴다. 목표 안이다 |

값은 중앙값이다. 세 측정 모두 늘 나타나는 차이로는 목표 안이다.

UPDATE의 차이(86.8M)는 UPDATE를 실행하는 transaction thread 하나에서 나온다. 그 thread가 86.2M 더 쓴다. 로그를 디스크에 쓰는 log-flush thread는 양쪽이 같다(379.7M, 379.9M). 로그 양도 같다(UPDATE당 57.750MB, 57.754MB).

### 가끔 나오는 큰 저하의 출처

- **vacuum.** UPDATE는 COMMIT 뒤에 vacuum 작업을 남긴다. vacuum은 지난 버전의 행을 나중에 치우는 뒷정리이고, 별도 thread에서 비동기로 돈다.
- **vacuum의 양.** UPDATE 하나가 남기는 vacuum은 기준 약 390M, 후보 약 425M 명령어다. 측정 구간을 csql 종료 뒤 3초까지 늘린 진단에서 쟀다.
- **큰 저하가 생기는 방식.** 계수는 csql이 끝날 때 끝난다. 그 전에 vacuum이 일부라도 시작하면, 그만큼 그 표본의 명령어 수가 커진다.
  - 관측한 추가분은 17~361M이었고, 모두 vacuum 전체량보다 작았다.
  - 후보 표본 하나에 vacuum이 다 들어오면 기준 중앙값과 비교한 성능 변화가 약 −7.9%가 된다(계산값).
- **재현.** 오래 떠 있는 기준 서버에서 호스트 전체 CPU가 100%가 된 뒤, 표본 12개 모두에 vacuum 135~316M가 들어왔다. 10-28의 큰 저하와 같은 모양이다. 그러나 vacuum이 들어오는 정확한 시점과 빈도는 확인하지 못했다.
- **"vacuum-master spike".** 별도 원인이 아니다. 구간 중에 새로 생긴 vacuum worker의 계수를 perf가 부모 thread인 vacuum-master에 합친 것이다.
- **기각한 가설.** log archive 생성, 호스트가 느린 것 자체, 후보 vacuum이 기준의 2배라는 가설, 중단 job 재시도, 크기 기준 checkpoint다.
- **후보 vacuum의 추가 비용.** 후보 vacuum은 UPDATE 하나당 34.6M를 더 쓴다(vacuum 성능 −8.9%). 대부분 `vacuum_process_log_record`(21.7M 더 씀)에서 나온다. PR이 `RVHF_UPDATE_NOTIFY_VACUUM` record에서도 undo를 풀어 OOS를 검사하기 때문이다(`src/query/vacuum.c:4276`, `4c3c8d791`). OOS reclaim 변경은 이 이슈의 범위 밖이다.

### 늘 나타나는 차이의 구성

transaction thread를 profile(`perf record -e instructions:u -c 3000017 --call-graph fp`)로 나눴다. 값은 UPDATE 하나(200,000행)당 명령어 수다.

| 구성 | 후보가 더 쓰는 양 | 행당 | 판단 |
| --- | ---: | ---: | --- |
| record 복사 | 0 (처음에 54M로 보였다) | 0 | 실제 증가가 아니다. 기준 build는 `heap_get_record_data_when_all_ready`에서 `spage_get_record`를 tail call(`jmp`)로 불러, frame pointer 호출 사슬이 그 복사를 한 단계 위 함수에 귀속했다. 두 build의 기계어로 확인했다. `heap_get_last_version` 전체로 보면 후보가 14.2M 덜 쓴다 |
| OOS 값이 없는 행의 OOS 처리 | 약 61M | 약 300 | 실제 비용이다. `heap_oos_finalize_record` 31.5M, `heap_pending_record` 생성·소멸 18.8M, `heap_record_replace_oos_oids` 9.7M, 나머지 검사 8.3M다. pending record는 새 record의 소유자로 기준의 copy area 할당·해제를 대신하므로, 이 몫이 모두 OOS 비용은 아니다 |
| `heap_update_logical` 안 | 51.2M | 약 256 | 한 원인이 없다. 직접 callee 25개 이상에 1~11M씩 퍼져 있다. OOS 고유 검사는 `heap_oos_validate_disk_record`(4.5M) 하나다. 나머지는 code 배치와 inlining 차이로 보인다(추정) |
| PR이 줄인 몫 | 덜 쓴다 | | record 만들기 44.7M(행당 224), 속성 읽기 21.8M(행당 109), page fix 29.0M(행당 145) 등을 덜 쓴다. 위의 증가를 상쇄한다 |

구성 사이에 겹치는 호출 경로가 있어, 표의 값을 더하고 빼도 thread 차이 86.2M와 정확히 맞지 않는다.

OOS 명세에 따르면 stub이 없는 새 record에는 Expand하거나 새로 넣을 OOS 값이 없다. 그래서 OOS가 없는 행의 finalize를 빠른 경로로 바꾸는 것은 명세와 충돌하지 않는다. 다만 효과는 약 20~30M로 추정되고, 재지 않았다. UPDATE 성능 변화를 −1.34%에서 약 −0.9~−1.0%로 줄이는 크기다(추정). 가끔 나오는 큰 저하는 vacuum 시점 때문이므로 이 변경으로 바뀌지 않는다.

### 2% 판정과 작성자 결정

- 기존 계수 구간에서 UPDATE의 늘 나타나는 성능 변화(−1.34%)는 목표 안이다. 그러나 vacuum이 들어온 표본은 −2%보다 나빠질 수 있으므로, 2% 목표는 미충족으로 남는다.
- vacuum을 늘 포함하도록 csql 종료 뒤 3초를 더한 진단 지표에서는 −1.76~−1.82%다.
- 2026-11-03 작성자 결정은 다음과 같다.
  - 판정은 기존 계수 구간 그대로 한다. vacuum 비용과 꼬리 구간 지표는 별도 줄로 보고한다.
  - 위 빠른 경로를 포함해 이번 범위에서는 엔진 코드를 바꾸지 않는다.

### 미확인 사항

- 같은 표를 연속으로 UPDATE하는 측정은 하지 않았다. 현재 `ordinary.py`는 UPDATE마다 새 복제본만 지원한다.
- vacuum이 csql 종료 전에 들어오는 정확한 시점과, 10-28처럼 큰 저하가 잦아지는 조건.
- checkpoint 뒤 서버는 21~22초 동안 idle이 되지 않는다. 이것이 `ordinary.py`의 idle 대기 마감 10초보다 길어서, 오래 떠 있는 서버에서는 측정이 멈출 수 있다(양쪽 공통).
- 위 빠른 경로의 실제 효과.

## Scope

동일한 UPDATE+COMMIT 구간의 전체 서버 instructions와 per-thread profile을 맞춰 잔여 비용과 변동 원인을 구분한다. profiler 시작·종료가 계수 구간을 넓힌 진단 결과는 plain 측정과 합치지 않는다. 성공한 표본만 골라내거나 background 작업을 끄는 방식으로 통과시키지 않는다.

OOS reclaim tail은 독립 재현·정합성 검증이 필요한 별도 작업이다. allocator 변경과 threshold parameter 작업, 기존 기준 2도 이 이슈의 범위에 포함하지 않는다. 공통 heap/OOS reader와 MVCC, recovery, ownership, identity 검사, COPY 의미는 유지한다.

## Implementation

2026-11-03 작성자 결정에 따라 이번 범위에서는 엔진 코드를 바꾸지 않는다. 위 빠른 경로가 필요해지면 별도로 다룬다.

## Acceptance Criteria

- 후반 비용 증가를 같은 계수 구간의 근거로 설명하고, 재현 조건과 미확인 조건을 구분한다.
  - 2026-11-03: 큰 저하의 크기는 비동기 vacuum으로 설명했다. 정확한 시점과 빈도는 미확인이다.
- 일반 UPDATE와 두 SELECT의 성능 저하 2% 이내 목표를 후속 검증 대상으로 유지한다. 최종 판정 범위와 수용 기준을 ANALYSIS에서 명시하며, 기준 변경이 필요하면 작성자 결정과 함께 기록한다.
  - 2026-11-03: 두 SELECT는 목표 안이다(+0.79%, −0.83%). UPDATE는 늘 나타나는 차이가 −1.34%이지만, vacuum이 들어온 표본 때문에 미충족이다. 판정 구간은 바꾸지 않기로 결정했다.
- production test-OFF 빌드에서 실제 compiler flags, binary identity, live configuration, physical log 크기를 확인한다. 실행 순서를 번갈아 5회 측정하고 첫 회를 제외하며, 새 복제본과 연속 UPDATE 결과 및 유효한 실패를 모두 보고한다.
  - 2026-11-03: 새 복제본 측정과 유효한 실패는 보고했다. 연속 UPDATE 측정이 남았다.
- 코드 변경 시 focused correctness와 두 SELECT를 다시 검증한다. 기존 native test의 addr2line 도구 선택을 유지하고 timeout이나 assertion을 완화하지 않는다.
  - 2026-11-03: 코드 변경이 없어 해당하지 않는다.

## Triage Request

이번 범위에서 엔진 코드를 바꾸지 않는다는 작성자 결정을 확인한다. 이 이슈는 연속 UPDATE 측정을 마칠 때까지 열어 둔다. 로컬 추적은 Work 571이다. 로컬 Work 번호는 JIRA issue key를 대체하지 않는다.
