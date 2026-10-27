# [OOS] [M2] 최신 PR #7990의 SELECT 성능 측정 결과

## Issue Triage

**이슈 수행 목적**: 최신 OOS 구현의 작은 컬럼 조회 이득과 큰 컬럼 조회 비용을 통합 전 엔진과 직접 비교하고 재현 근거를 남긴다.

**이슈 수행 이유**: PR #7990의 성능 답글에서 최신 버전의 I/O 이득을 별도로 실측하기로 했다. CBRD-27014의 7월 결과는 다른 revision이므로 최신 성능의 증거로 재사용하지 않는다.

**영향**: 큰 컬럼이 있는 테이블의 작은 값 조회는 읽기 페이지가 줄지만, 일반 heap에 있던 큰 값을 다시 읽는 조회에는 별도 비용이 생긴다. 입력과 조회 패턴별 이득·비용을 함께 판단해야 한다.

**이슈 수행 방안**: 두 exact revision의 독립 release 설치와 새 DB에서 같은 두 layout과 다섯 SQL을 측정했다. 기본 200개 표본과 작업 전용 파일 캐시 해제 요청 후의 24개 보조 표본을 검증했다.

---

## AI-Generated Context

> 아래는 2026-10-27 Asia/Seoul에 직접 실행한 측정과 저장 진단이다. 이 이슈는 성능 실측 결과이며 기능 수정이나 전체 회사 회귀 통과를 의미하지 않는다.

## Description

상위 [CBRD-26583](https://jira.cubrid.org/browse/CBRD-26583)의 OOS 구현은 큰 가변 값을
별도 파일로 분리해 작은 컬럼 조회에서 불필요한 큰 값을 읽지 않게 한다. 이 이득은
기존 record가 일반 heap인지 overflow인지, 큰 컬럼을 실제로 조회하는지에 따라 달라진다.
최신 성능을 검토할 때는 이 구분과 실제 페이지 읽기 증거가 필요하다.

[PR #7990 답글 5번](https://github.com/CUBRID/cubrid/pull/7990#issuecomment-6441306406)의
후속 실측을 완료했다. 7월 발표 결과는 과거 비교 자료로 유지하고, 최신 측정과 섞지 않는다.
일반 작은 행의 CPU 회귀 대응과 별도 PR #8299는 [CBRD-27785](https://jira.cubrid.org/browse/CBRD-27785)에서 다룬다.

## Test Build

| 역할 | full SHA |
| --- | --- |
| 기준 | `4781495f01523a3ecc5891e3377ad62cf876a1cd` |
| 측정한 PR #7990 head | `dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67` |

GCC 11.5.0, RelWithDebInfo, O2, 테스트 계측 없음, source 수정 없음이다.
DB/log page 16KiB, data buffer 512MiB, log buffer 16MiB, max_clients 20,
query cache entries/pages 0으로 맞췄다. 서버 CPU 16–19, CSQL CPU 12를 사용했다.
공유 호스트에서 DB 서버는 한 번에 하나씩 실행했으며 설치·registry·port·설정·TMP·DB를 분리했다.

## Workload and Storage

layout별 100,000행, 인덱스 없는 id·hot_col, 섞인 lookup_key와 그 인덱스,
압축에 따른 물리 크기 변화를 피한 BIT VARYING payload를 사용했다.

| 입력 | 기준 저장 형태 | OOS 후보의 compact heap | 후보 OOS record 수 |
| --- | --- | --- | ---: |
| heap | 평균 14,480B, 100,001 pages, overflow 0 | 평균 4,012B, 33,337 pages | 200,000 |
| overflow | 평균 22,016B, overflow 100,000행, SHOW 200,085 pages | 평균 4,040B, 33,337 pages | 300,000 |

실제 저장은 SHOW HEAP CAPACITY와 후보의 SHOW HEAP OOS로 확인했다.
OOS 전체 파일의 크기까지 작아졌다는 결론은 아니다. 작은 컬럼 조회가 큰 값의 페이지를 건너뛰는 효과를 측정한다.

Q1은 SUM(id), Q2는 모든 id 반환, Q3는 섞인 non-covering index range lookup,
Q4는 큰 컬럼 하나의 전체 내용 비교, Q5는 모든 컬럼의 내용 비교와 checksum이다.
모든 SQL을 직렬 실행하고 결과·행 수·계획을 검사했다. cache·layout·SQL·엔진마다 5회 측정했다.

## Results

아래는 전체 실행 시간의 중앙값이다. 변화율은 `(OOS / 기준 - 1) * 100`이다.
restart-only는 DB 서버 재시작 조건이고, warm은 해당 SQL을 한 번 실행한 뒤의 반복 조건이다.
둘 다 OS cache를 유지했다. Q2/Q3와 instructions·페이지 접근·원시 범위는 상세 보고서에 있다.

| 입력 | 조회 | restart-only 기준 / OOS | 변화 | warm 기준 / OOS | 변화 |
| --- | --- | ---: | ---: | ---: | ---: |
| heap | Q1 | 0.74s / 0.38s | -48.6% | 0.30s / 0.09s | -70.0% |
| heap | Q4 | 1.08s / 1.36s | +25.9% | 0.73s / 0.86s | +17.8% |
| heap | Q5 | 1.83s / 2.22s | +21.3% | 1.46s / 1.70s | +16.4% |
| overflow | Q1 | 1.47s / 0.41s | -72.1% | 0.74s / 0.08s | -89.2% |
| overflow | Q4 | 1.84s / 1.53s | -16.8% | 1.33s / 1.10s | -17.3% |
| overflow | Q5 | 3.03s / 3.43s | +13.2% | 2.53s / 2.90s | +14.6% |

작은 컬럼 집계 Q1에서 restart-only의 엔진 ioread는 heap 입력
100,003 → 33,339,
overflow 입력 200,087 → 33,339였다.
일반 heap에서 큰 컬럼을 읽는 Q4/Q5는 별도 OOS 읽기 비용을 함께 평가해야 한다.

일반 heap Q1의 파일 캐시 해제 요청 후 OS read_bytes는
1,576.6 → 1,640.8MiB로
줄지 않았다. 엔진 페이지 읽기 감소만으로 실제 저장장치 읽기 감소를 주장하지 않는다.
overflow Q1의 같은 계수는 3,146.2 →
1,650.5MiB였다. readahead·데이터 배치의 영향은 가설이며 원인을 확정하지 않았다.

기본 표본의 OS read_bytes 합계는 0B였다.
엔진 ioread 감소를 저장장치까지 비운 cold 성능이라고 부르지 않는다.
작업 전용 DB의 정지한 permanent volume 파일만 POSIX_FADV_DONTNEED로 해제 요청하고,
fincore로 residency를 확인한 뒤 24개 보조 표본을 추가 수집했다.

| 입력 | SQL | 기준 / OOS (초) | 시간 변화 | OS read_bytes 기준 → OOS (MiB) | 엔진 ioread 기준 → OOS |
| --- | --- | ---: | ---: | ---: | ---: |
| heap | Q1 | 1.01 / 0.95 | -5.9% | 1,576.6 → 1,640.8 | 100,003 → 33,339 |
| heap | Q4 | 1.43 / 1.91 | +33.6% | 1,576.6 → 2,095.4 | 100,003 → 133,339 |
| overflow | Q1 | 1.81 / 0.90 | -50.3% | 3,146.2 → 1,650.5 | 200,087 → 33,339 |
| overflow | Q4 | 2.32 / 5.72 | +146.6% | 3,146.2 → 2,793.9 | 200,087 → 133,339 |

OS read_bytes는 서버에 귀속된 저장장치 읽기 집계이며 장치 내부 cache나 NAND 상태를 보증하지 않는다.
파일 캐시 해제 요청 후 overflow의 Q4는
2.32s → 5.72s
(+146.6%)였다. OS cache 유지 조건과 성능 방향이 반대이므로
이 결과를 숨기지 않고 CBRD-27785의 후속 원인 분석 후보로 남긴다. 원인은 확정하지 않았다.

## Completion Evidence

기본 200개 표본, warmup 20개, 파일 캐시 해제 요청 후의 보조 24개 표본에서
결과·행 수·실행 계획·직렬 실행·프로세스와 설치 identity·perf 계수 검증을 완료했다.
서버·CSQL·DSO의 SHA-256, full SHA, SQL, 설정, 저장 진단과 IO 전후 값을 보존했다.
최소 perf event running은 100.0%였다.

[상세 실측 보고서와 재현 절차](https://github.com/vimkim/my-cubrid-docs/blob/main/CBRD-27788/CBRD-27788-oos-select-performance_dcbf09e_codex.md) 및 그 보고서가 연결하는 선별 기계 요약을 참고한다.
벤치마크 구현은 소스의 `contrib/benchmarks/oos-performance/io_bench.py`와 `IO_README.md`다.
과거 입력은 [CBRD-27014의 첨부 보고서](https://jira.cubrid.org/secure/attachment/1021347/oos-performance-report.md)와
원본 workload SQL revision `88f3297fbf10a2786ed4b2d1dff85bf55aaddc12`로 추적했다.

## Scope and Limitations

측정 시작 시점의 PR #7990 head를 고정했다. 별도 PR #8299나 약 16KB 임계값 비교용
빌드는 포함하지 않았다. UPDATE 재사용·DML·HA·복구·전체 회사 회귀는 별도 범위다.
공유 호스트의 wall time 변동과 OS page cache 영향을 명시했다. 제품 임계값 변경이나
PR merge, CI 재실행을 이 결과에 포함하지 않는다.
