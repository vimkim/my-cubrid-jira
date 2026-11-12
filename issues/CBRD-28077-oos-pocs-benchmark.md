# [OOS] develop·OOS·Sidecar·Inner Table 저장 방식의 workload별 성능 비교

**한 줄 요약**: 큰 컬럼 값을 행 밖에 저장하는 세 설계(OOS, Sidecar, Inner Table)를 develop과 같은 workload에서 비교했다. 작은 컬럼 scan은 세 설계 모두 크게 이기고, 손해 보는 workload는 설계마다 달랐다.

## Issue Triage

**이슈 수행 목적**: OOS(CBRD-26357), Sidecar POC(CBRD-28053), Inner Table POC(CBRD-28054)가 develop과 비교해 어떤 workload에서 이득을 보고 어떤 workload에서 손해를 보는지 같은 조건의 측정값으로 보여준다. 저장 구조를 결정할 때 설계 문서가 아니라 측정값으로 비교할 수 있게 한다.

**이슈 수행 이유**: 세 설계는 지금까지 각자 다른 harness, 다른 기준 커밋, 다른 서버 부하에서 측정되었다. OOS는 CBRD-27788의 io_bench, Sidecar는 수락 기준 A1·A2용 측정, Inner Table은 phase 10·11 driver를 썼다. 그래서 수치를 서로 바로 비교할 수 없었다. 또 지금까지의 측정은 주로 작은 컬럼만 읽는 scan과 기능 미사용 비용에 맞춰져 있었다. 큰 값의 INSERT, 큰 값 UPDATE, 짧은 트랜잭션의 반복 commit처럼 행 밖 저장에 불리할 수 있는 경우는 같은 기준으로 측정되지 않았다.

**영향**: OOS 병합 이후의 방향(OOS 유지·보완 또는 대안 설계 채택)을 판단하는 엔진 개발팀과 리뷰어가 대상이다. 이 작업은 측정과 보고만 하며, 어느 브랜치의 코드도 바꾸지 않는다. 측정 중 OOS의 비용 원인 두 가지와 develop 결함 하나를 확인했다.

**이슈 수행 방안**: 같은 driver로 다섯 빌드를 동시에 측정하고, 결과·checksum·값 길이를 빌드끼리 비교해 측정 자체를 검증한다. 상세 결과는 아래 보고서에 있다. 후속 조치는 아래 "후속"에 정리했다.

---

## AI-Generated Context

## Description

### 결과 요약 (3차 실행, 2026-11-13)

큰 값이 행 밖으로 나가는 4 KB·8 KB·64 KB 값에서, develop `a7f220d5d7` 대비 서버 명령어 수(drain 포함) 비율이다. 작을수록 좋다. 범위는 세 크기와 IO 있음·없음 조건의 중앙값(각 3회 반복)이다.

| 작업 | OOS | Sidecar | Inner Table |
| --- | --- | --- | --- |
| 작은 컬럼만 읽는 scan | ×0.03~0.85 | ×0.02~0.37 | ×0.02~0.24 |
| 큰 값을 읽는 scan | ×1.05~3.03 | ×0.98~1.71 | ×2.03~21.95 |
| PK 조회, 작은 컬럼 | ×0.74~0.99 | ×0.75~1.01 | ×1.05~1.74 |
| 작은 컬럼 UPDATE | ×3.90~11.29 | ×0.08~0.65 | ×0.50~1.04 |
| 큰 값 교체 UPDATE | ×2.33~597 | ×1.47~2.17 | ×3.01~8.21 |
| 반복 UPDATE+COMMIT | ×1.00~2.04 | ×0.70~1.27 | ×0.94~1.61 |
| DELETE | ×0.33~1.23 | ×0.35~1.30 | ×1.32~6.08 |
| 8 client 동시 UPDATE·INSERT | ×1.08~2.43 | ×1.01~1.05 | ×1.08~1.54 |
| 기능 미사용(100 B, 모든 작업) | ×0.92~1.12 | ×0.92~1.12 | ×0.96~1.12 |

- 이번 workload에서 develop보다 나빠지는 폭이 가장 작은 설계는 Sidecar다. 대가는 큰 값 교체(×1.5~2.2)와 적재(×1.14~1.26)다.
- OOS는 UPDATE 계열에서 손해가 크다.
- Inner Table은 큰 값을 읽거나 지우거나 교체할 때, 그리고 PK 조회에서 비용이 크다.
- 기능 미사용 비용은 develop 커밋 사이의 차이(develop `e64a04a79` 대비 ×0.95~1.16)와 같은 폭이다.
- 모든 측정은 `ha_mode=off`다. Sidecar와 Inner Table에 HA 지원이 없어서 생긴 차이는 아니다. HA를 켠 비교는 두 POC가 HA를 구현한 뒤에 할 수 있다.

### 원인을 확인한 것

- **OOS 작은 컬럼 UPDATE.** 바꾸지 않은 큰 값을 다시 읽고 새로 적재한다. 8 KB 30,000행에서 UPDATE 한 번에 OOS 페이지가 30,001개에서 60,001개가 되었다. CBRD-27230의 동작과 같다.
- **OOS 큰 값 교체 UPDATE.** 새 OOS 페이지를 할당할 때마다 빈 페이지 회수 sweep이 파일의 데이터 페이지를 훑는다. 64 KB warm 조건에서 750행 교체가 23~71초, page fetch 5,200만~1억 8,000만 회였고, 프로파일의 85%가 `oos_try_reclaim_page_internal`이었다. CBRD-27872의 sweep이다.
- **Inner Table PK 조회.** index scan을 여는 경로가 참조 확장 생략 flag(`inner_table_skip_expand`)를 켜지 않는다. 그래서 큰 컬럼을 고르지 않아도 모든 chunk를 읽는다. 코드로 확인했다.
- **develop 결함.** 같은 형태의 `UPDATE ... SET b = REPEAT(X'D1', 100)`가 처음 실행될 때는 100바이트를 저장한다. XASL cache의 plan을 재사용하면 16진 텍스트 25바이트를 저장한다. develop `a7f220d5d7`에서 재현했다. CBRD-28079로 등록했다.

### 측정 방법

- 빌드는 다섯 개다. develop `a7f220d5d7`, develop `e64a04a79a`(대조군), OOS `c02f897268`, Sidecar `7c5028d5bd`, Inner Table `fbb4f25057`이며, 모두 release 빌드다. 다섯 빌드를 동시에 실행했다.
- 테이블은 `t (id INT PRIMARY KEY, k INT, s VARCHAR(50), big BIT VARYING)`이고, 값 크기는 100 B, 4 KB, 8 KB, 64 KB다.
- IO 있음 조건은 `data_buffer_size=128M`이다. 측정마다 서버를 재시작하고 OS page cache를 비운다. IO 없음 조건은 `data_buffer_size=4G`이고 데운 뒤 잰다.
- 시나리오는 적재, 작은 컬럼 scan, 큰 값 scan, PK 조회(작은·큰 컬럼), 작은 컬럼 UPDATE, 큰 값 교체, UPDATE+INSERT 반복, 큰·작은 컬럼 UPDATE+COMMIT 반복, DELETE, 8 client 동시 UPDATE·INSERT다. 모두 3회씩 반복했다.
- 검증 결과는 다음과 같다. 측정한 문장 240개의 결과와 단계별 checksum 20개가 빌드 사이에 모두 일치했다. 의도한 길이가 아닌 값은 0행이었고, 실패한 문장은 없었다. 반복 사이 흔들림은 명령어 수 중앙값 0.05, 경과 시간 중앙값 0.30이다. 그래서 결론은 명령어 수와 page·IO 횟수로 낸다.

### 1차 실행의 정정

1차 실행(2026-11-12)의 S7과 S8b는 위 develop 결함 때문에 첫 실행 뒤로 의도한 크기의 1/4 값을 썼다. 3차 실행이 이 항목들을 대체한다. 1차 실행의 다른 결론(작은 컬럼 scan, 큰 값 scan, PK 조회, OOS 재적재)은 3차 실행에서도 재현되었다.

### 후속

- REPEAT plan 재사용 결함은 CBRD-28079로 등록했다.
- CBRD-27230(재적재)과 CBRD-27872(회수 sweep)이 반영된 OOS로 작은 컬럼 UPDATE, 큰 값 교체, 반복 UPDATE를 다시 측정한다.
- Inner Table의 index 경로 참조 확장을 생략할 수 있는지 확인한다. 생략할 수 있다면 PK 조회를 다시 측정한다.
- HA를 켠 비교는 Sidecar와 Inner Table이 HA를 구현한 뒤에 한다.

### 산출물

- 시나리오별 보고서(3차): [run3-report.md](https://github.com/vimkim/my-cubrid-docs/blob/main/CBRD-28077/run3-report.md)
- 팀장 검토용 보고서(1차, 정정 포함): [lead-report.md](https://github.com/vimkim/my-cubrid-docs/blob/main/CBRD-28077/lead-report.md)
- 1차 실행 보고서(정정 포함): [benchmark-report.md](https://github.com/vimkim/my-cubrid-docs/blob/main/CBRD-28077/benchmark-report.md)
- 측정·분석 도구: [tools/](https://github.com/vimkim/my-cubrid-docs/tree/main/CBRD-28077/tools)

### 관련 이슈

- 상위: CBRD-26978
- 비교 대상: CBRD-26357(OOS), CBRD-28053(Sidecar POC), CBRD-28054(Inner Table POC)
- 원인과 관련된 이슈: CBRD-27230, CBRD-27872, CBRD-27827
- 기존 측정: CBRD-27788
