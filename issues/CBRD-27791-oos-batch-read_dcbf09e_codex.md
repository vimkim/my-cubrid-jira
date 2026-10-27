# [OOS] 큰 값 조회의 읽기 대기를 줄이기 위한 batch read

## Issue Triage

**이슈 수행 목적**: 현실적인 범위의 OOS batch read로 큰 값 조회의 읽기 대기를 줄이면서 작은 컬럼 조회의 이득과 값·MVCC·identity 검증을 보존한다.

**이슈 수행 이유**: PR #7990의 `dcbf09e` 에서 작업 전용 파일 캐시 해제 요청 후 큰 값 하나를 비교하는 SELECT가 기준 2.38초에서 OOS 5.72초로 느려졌다. OOS의 엔진 읽기와 CPU 시간은 더 적다. 읽기 순서·요청 방식을 바꾼 별도 재생 대조에서 개선 여지가 확인되어, 엔진에서 가능한 batch 범위와 비용을 분석할 필요가 있다.

**영향**: 큰 가변 길이 컬럼이 있는 테이블에서 큰 값의 내용을 비교·집계하는 사용자는 읽는 바이트가 줄어도 더 긴 조회 대기를 겪을 수 있다. 특정 fixture와 호스트에서 확인한 영향이며 빈도와 일반 workload의 개선율은 미확정이다. 작은 컬럼만 조회하는 이득은 유지해야 한다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

> 아래는 2026-10-28 Asia/Seoul에 재검증한 source·native SQL·offline 읽기 재생의 상세 맥락이다. 재생 결과는 엔진 수정 후 SQL 성능이 아니며, 미합의 설계와 기준은 ANALYSIS 항목으로 구분한다.

## Description

### 무엇이 문제인가

OOS는 큰 값을 heap record 밖의 value chain에 저장하고, 필요한 속성만 Resolve한다. 작은 컬럼을 조회할 때 큰 값의 page를 읽지 않는 이득이 있다. 반면 큰 값을 읽는 조회는 heap에서 얻은 참조로 OOS page를 찾아가야 한다.

이번 대상은 [CBRD-26978](https://jira.cubrid.org/browse/CBRD-26978)의 성능 후속 Sub-task다. 기존 제목의 batch read 목표를 유지한다. [CBRD-27788](https://jira.cubrid.org/browse/CBRD-27788)은 SELECT 실측 결과이고, [CBRD-27785](https://jira.cubrid.org/browse/CBRD-27785)의 일반 heap CPU 회귀 대응과 이번 읽기 대기 개선은 별도로 검증한다. 본 작업을 PR #7990의 merge 선행 조건으로 지정한 결정은 확인하지 못했다.

기존 `heap_oos_read_grouped_payloads` 는 한 record의 여러 OOS 속성을 모으고, `oos_read_many` 는 같은 head page를 공유한 요청의 page fix를 줄인다. 여러 행을 모으거나 연속 page I/O를 발행하는 기능은 아니다. Q4처럼 OOS 속성 하나를 읽는 경우에는 scalar Resolve를 사용한다.

### 왜 문제인가

사용자는 큰 컬럼 내용으로 조건을 검사하거나 전체 값을 집계해 결과를 얻으려 한다. 같은 100,000행을 비교한 Q4에서 파일 캐시 해제 요청 후 기준 2.38초, OOS 5.72초가 걸렸다. OOS는 엔진 ioread가 200,087회에서 133,339회로 줄었지만 조회 대기는 약 2.4배가 됐다. 따라서 작은 컬럼 이득이나 엔진 읽기 감소만으로 큰 값 조회도 빨라진다고 판단할 수 없다.

OS 캐시 조건은 구분해야 한다. 같은 overflow Q4의 warm 조건에서는 기준 1.23초, OOS 1.00초였다. 단순 재시작 표본에는 OS cache hit와 실제 읽기가 섞인다. 이번 영향은 파일 캐시 해제 요청 후의 불연속 읽기 조건에서 확인했으며, 장치 cache 초기화나 모든 storage의 동작을 뜻하지 않는다.

### 왜 해결해야 하는가

큰 값을 다시 읽어야 하는 workload에서는 compact heap의 이득과 별도로 읽기 대기를 줄일 방법이 필요하다. OS readahead를 끄는 `data_file_os_advise=3` 은 기존 대조에서 양쪽을 느리게 했으므로 해결책으로 제안하지 않는다. 전체 요청을 사후 정렬한 재생은 미래 주소를 모두 아는 대조여서 그대로 엔진 전략이 될 수 없다.

제한된 범위에서 주소를 수집하고 읽는 순서·묶음을 조절하는 batch read의 실현성과 비용을 분석할 근거는 있다. 다만 작은 범위와 병합의 효과는 일정하지 않으며 gap 읽기는 요청량을 늘린다. 성능·메모리·첫 결과 지연을 함께 평가해야 한다. 실서비스 발생 빈도와 긴급도는 미확정이므로 이 본문으로 우선순위를 올리거나 통합을 차단하지 않는다.

## Measurement Evidence

| 구분 | 확인 내용 |
| --- | --- |
| 비교 source | base `4781495f01523a3ecc5891e3377ad62cf876a1cd`, OOS `dcbf09e4f7fd02ff9c8fc6493ec8887fc2919d67` |
| 빌드 | GCC 11.5.0, RelWithDebInfo/O2, 테스트 계측 없음. 각 revision의 독립 설치·DB와 matching CSQL/DSO를 확인했다. |
| 입력 | 100,000행, 기준은 평균 22,016B record overflow, OOS는 평균 4,040B heap과 속성별 chain. 큰 값은 7,000/6,000/5,000B다. |
| 조건 | 16KiB DB/log page, DB buffer 512MiB, query cache 0, 직렬 TABLE SCAN. CPU affinity와 실행 순서 교대, 반복별 정답 검증. |
| 파일 캐시 해제 요청 후 Q4 | 3회 중앙값: base 2.38초, OOS 5.72초. CPU task-clock 2,333.30ms/2,266.97ms. |
| 작은 컬럼 Q1 | 같은 overflow 입력의 파일 캐시 해제 요청 조건에서 base 1.88초, OOS 0.82초. |
| 전체 값 Q5 | 같은 조건에서 base 3.46초, OOS 4.12초. 큰 컬럼 하나와 여러 개의 동작도 구분한다. |

기존 trace를 독립 파서로 재조립하고 FD 전후 일치·요청 순서·페이지 중복 횟수를 대조했다. 새 trace도 같은 요청 수와 주소 패턴을 재현했다. strace를 붙인 시간은 성능 수치에서 제외했다. 읽기 주소는 OS volume 파일 offset이며 NVMe LBA가 아니다.

새 offline 재생에서 OOS 원래 순서는 4.413초, 64 heap-page 단위 정렬은 3.449초였다. 같은 범위에서 인접 요청을 병합하면 3.974초로 정렬만 한 경우보다 느렸다. gap까지 읽으면 1.965초지만 요청 바이트가 72.4% 늘었다. 각각 3회 중앙값이다. 이 대조도 trace의 주소를 미리 아는 모델이며, 실제 행 수집·MVCC·latch·buffer hit와 첫 행 반환 비용을 수행하지 않는다. 따라서 엔진 구현의 효과와 상한은 native prototype에서 검증해야 한다.

기존 결과: [전체 SELECT 실측](https://github.com/vimkim/my-cubrid-docs/blob/main/CBRD-27788/CBRD-27788-oos-select-performance_dcbf09e_codex.md), [읽기 순서·요청 방식 진단](https://github.com/vimkim/my-cubrid-docs/blob/main/CBRD-27788/CBRD-27788-oos-cold-read-diagnosis_dcbf09e_codex.md). 이번 [상세 재측정](https://github.com/vimkim/my-cubrid-docs/blob/main/CBRD-27791/CBRD-27791-oos-batch-read-analysis_dcbf09e_codex.md)과 [구현·검증 계획](https://github.com/vimkim/my-cubrid-docs/blob/main/CBRD-27791/CBRD-27791-oos-batch-read-plan_dcbf09e_codex.md)에 수치·범위·후속 단계를 정리했다.

## Repro

아래 SQL은 양쪽 독립 DB에 [동일 fixture](https://github.com/vimkim/my-cubrid-docs/blob/main/CBRD-27791/fixture.sql)를 적재한 후 실행한다. 이 입력은 최초 실측 파일과 byte 단위로 같다. 각 matching install의 `csql -C -u dba -i fixture.sql <database>` 로 새 DB에 적재한다. 전체 byte 내용 비교이므로 길이만 읽는 최적화와 구분된다.

```sql
SELECT /*+ NO_MERGE RECOMPILE PARALLEL(0) NO_PARALLEL_HEAP_SCAN */ COUNT(*)
FROM perf_overflow_22000
WHERE cold_1 = CAST(REPEAT(X'AA', 7000) AS BIT VARYING);
```

정답은 100,000이다. 각 engine의 `csql -C -u dba -i q4.sql <database>` 로 실행한다. 파일 캐시 조건은 서버를 정지한 뒤 작업 전용 permanent volume에만 `fsync` 와 `POSIX_FADV_DONTNEED` 를 적용하고 `fincore` 로 residency를 확인해 만들었다. 단순 DB 재시작과 같은 조건이 아니다. 기존 DB를 다른 revision으로 열지 않는다.

## Specification Changes

batch read로 큰 값 조회 대기를 줄이는 결과가 필요하다. 적용할 scan과 window·메모리 정책은 ANALYSIS에서 정한다. 저장 형식 변경은 현재 선택하지 않았다.

MVCC snapshot과 undo record의 참조, stale/deallocated/retyped page·slot·identity stamp 검사, page latch, 결과 복사 수명을 보존한다. 필요한 속성만 Resolve하는 계약과 predicate short-circuit을 유지한다. `FILE_OOS` 는 logical file이며 별도 OS 파일과 동일시하지 않는다.

## Implementation

TBD - ANALYSIS 단계에서 결정한다.

수집 책임은 가시성과 필요한 속성을 아는 scan 층, 읽기 순서와 참조 검증은 OOS 층, cache·동시 miss·DWB·TDE를 포함한 실제 page I/O는 page buffer 층에서 검토한다. 기존 grouped Resolve 확장, bounded demand-read 순서 변경, 선행 읽기는 후보이며 채택된 구현이 아니다. raw `pread` 재생이나 `fileio_read_pages` 직접 호출로 page buffer 계약을 대체하지 않는다.

## Acceptance Criteria

- [ ] 현실적인 bounded batch가 큰 값 조회 대기를 줄이는 native SQL 근거를 제시한다. 개선율과 cache/workload 범위는 ANALYSIS에서 합의한다.
- [ ] 정답·MVCC·identity·latch·복사 수명과 실패·취소 처리를 보존한다.
- [ ] 작은 컬럼만 읽는 이득과 lazy Resolve를 유지한다. 허용 회귀 예산은 TBD다.
- [ ] 추가 읽기, peak memory, first-result latency의 상한과 실측을 제시한다. 제품 상한은 TBD다.
- [ ] 단일/다중 속성, multi-chunk와 buffer 경계 중 실제 설계 위험에 필요한 집중 검증 범위를 결정하고 결과를 남긴다.

## Definition of done

ANALYSIS에서 인터페이스·수집 범위·상한·fallback과 성능 예산을 결정한다. 구현 후 동일 revision 계열의 독립 환경에서 집중 정확성 및 tracer 없는 성능 대조를 수행한다. 필요한 CTest·SQL·shell·medium 및 PR CI 범위는 실제 변경에 맞춰 정한다. 이번 분석·재생 완료만으로 이 구현 이슈를 완료 처리하지 않는다.

## Triage Request

부모 CBRD-26978의 batch read 후속 성능 과제로 문제와 필요한 결과를 확인하고, 기존 담당자 측에서 ANALYSIS를 진행하도록 요청한다. 현재 Sub-task 유형과 parent를 유지하며, summary·우선순위·담당자·상태 변경은 이 본문 게시 범위에 포함하지 않는다.
