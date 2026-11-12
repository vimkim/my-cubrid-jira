# [OOS] develop·OOS·Sidecar·Inner Table 저장 방식의 workload별 성능 비교

**한 줄 요약**: 큰 컬럼 값을 행 밖에 저장하는 세 설계(OOS, Sidecar, Inner Table)가 모두 측정 가능한 상태가 되어, develop을 기준으로 같은 workload에서 네 빌드의 성능을 비교하는 작업이다.

## Issue Triage

**이슈 수행 목적**: OOS(CBRD-26357), Sidecar POC(CBRD-28053), Inner Table POC(CBRD-28054)가 develop과 비교해 어떤 workload에서 이득을 보고 어떤 workload에서 손해를 보는지 같은 조건의 측정값으로 보여준다. 저장 구조를 결정할 때 설계 문서가 아니라 측정값으로 비교할 수 있게 한다.

**이슈 수행 이유**: 세 설계는 지금까지 각자 다른 harness, 다른 기준 커밋, 다른 서버 부하에서 측정되었다. OOS는 CBRD-27788의 io_bench, Sidecar는 수락 기준 A1·A2용 측정, Inner Table은 phase 10·11 driver를 썼다. 그래서 수치를 서로 바로 비교할 수 없다. 또 지금까지의 측정은 주로 작은 컬럼만 읽는 scan과 기능 미사용 비용에 맞춰져 있고, 큰 값의 INSERT, 큰 값 UPDATE, 짧은 트랜잭션의 반복 commit처럼 행 밖 저장에 불리할 수 있는 경우는 같은 기준으로 측정되지 않았다.

**영향**: OOS 병합 이후의 방향(OOS 유지·보완 또는 대안 설계 채택)을 판단하는 엔진 개발팀과 리뷰어가 대상이다. 비교 측정이 없으면 각 설계의 손익을 서로 다른 조건의 수치로 추정해야 한다. 이 작업은 측정과 보고만 하며, 어느 브랜치의 코드도 바꾸지 않는다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다. 아래 측정 계획은 2026-11-12에 정한 초기 범위다.

---

## AI-Generated Context

## Description

### 비교 대상

2026-11-12 기준으로 각 브랜치의 현재 HEAD를 그대로 빌드한다(RelWithDebInfo, GCC). 브랜치마다 기준 develop 커밋이 다르며, 이번 측정에서는 맞추지 않는다. 결과를 해석할 때 이 차이를 함께 적는다.

| 대상 | 브랜치 | 커밋 | 기준 develop |
| --- | --- | --- | --- |
| develop | `develop` | `a7f220d5d7` | - |
| OOS | `feature/oos-merge` | `c02f897268` | `a7f220d5d7` |
| Sidecar | `sidecar` | `7c5028d5bd` | `e64a04a79a` |
| Inner Table | `inner-table` | `fbb4f25057` | `81fa5696cd` |

큰 값을 행 밖으로 옮기는 기준은 설계마다 다르다. Sidecar는 행이 4,060 B를 넘을 때 큰 값부터 옮기고(`sidecar_*` 파라미터), Inner Table은 `inner_table_threshold`, OOS는 내장 임계값을 쓴다. 값 크기를 모든 설계가 옮기는 크기, 일부만 옮기는 크기, 아무도 옮기지 않는 크기로 나누어 측정한다.

### 측정 범위

테이블은 `t(id INT PRIMARY KEY, k INT, s VARCHAR(50), big VARCHAR)` 형태다. 큰 값의 크기는 0(기능 미사용), 2 KB, 8 KB, 64 KB로 둔다. 각 시나리오는 대상 하나당 10분 안에 끝나는 규모로 맞춘다.

| # | 시나리오 | 행 밖 저장에 예상되는 영향 |
| --- | --- | --- |
| S1 | 작은 컬럼만 읽는 전체 scan(`SELECT SUM(id)`) | 유리 |
| S2 | 큰 컬럼을 포함한 전체 scan | 불리 |
| S3 | PK 단건 조회, 작은 컬럼과 큰 컬럼 각각 | 혼합 |
| S4 | 큰 값을 가진 행의 대량 INSERT | 불리 |
| S5 | 작은 컬럼만 UPDATE(큰 값은 그대로) | 유리 |
| S6 | 큰 컬럼 UPDATE | 불리 |
| S7 | UPDATE와 INSERT 혼합 | 혼합 |
| S8 | UPDATE 후 commit을 짧게 반복 | 불리할 수 있음 |
| S9 | DELETE 후 vacuum 회수 | 미상 |
| S10 | 큰 값이 없는 작은 행의 INSERT·SELECT·UPDATE | develop과 같아야 함 |

각 시나리오는 두 조건에서 측정한다.

- **IO 있음**: data buffer를 작게 두고 데이터가 buffer보다 훨씬 크며, 서버 재시작 직후 측정한다.
- **IO 없음**: data buffer가 데이터를 모두 담고, 한 번 읽은 뒤 측정한다.

동시 접속 workload(예: CBRD-27827의 OOS 파일 헤더 경합)는 이번 범위에서 뺀다.

### 측정 지표

- 경과 시간과 처리량
- 서버 프로세스의 사용자 공간 명령어 수(`perf stat -e instructions:u`)
- `statdump`의 data page fetch, IO read, IO write 수
- log 생성량과 DB volume 크기

측정 서버는 다른 작업과 공유되며 2026-11-12 load average가 20~38(80 core)이었다. 그래서 명령어 수와 page·IO 횟수를 주 지표로, 경과 시간을 보조 지표로 쓴다. 각 경우를 3~5회 반복해 중앙값을 보고한다.

### 완료 조건

- 네 빌드에서 S1~S10을 IO 있음·없음 조건으로 측정한 결과 표와 해석
- 대상별 develop 대비 비율, 그리고 각 설계가 유리·불리한 workload 요약
- 측정을 다시 실행할 수 있는 driver 스크립트와 실행 방법
- 결과 보고서를 my-cubrid-docs에 두고 이 이슈에 링크

### 관련 이슈

- 상위: CBRD-26978
- 비교 대상: CBRD-26357(OOS), CBRD-28053(Sidecar POC), CBRD-28054(Inner Table POC)
- 기존 측정: CBRD-27788(OOS SELECT IO 벤치마크)
