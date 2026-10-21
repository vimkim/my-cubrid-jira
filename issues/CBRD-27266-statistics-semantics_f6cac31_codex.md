# [PGBUF] 논리 페이지 처리와 물리 I/O를 구분할 수 있도록 통계 의미와 관측 경로를 정리한다

## Issue Triage

**이슈 수행 목적**: page buffer의 논리 flush, 파일에 기록한 페이지 양, 읽기 요청, victim 후보를 구분하여 관측할 수 있도록 지표의 집계 단위·완료 시점·수집 조건을 명확히 한다.

**이슈 수행 이유**: 현재 소스에서 SHOW의 counter 컬럼 9개는 폐기되어 NULL을 반환하지만, 대체 관측 경로인 statdump의 쓰기·읽기 지표도 동일한 사건을 세지 않는다. DWB 경로의 별도 집계와 논리 flush 지표의 활성화 조건을 구분하지 않으면 부하 비교의 기준을 잘못 정할 수 있다. SHOW에 남아 있는 `Victim_candidate_pages`도 내부 victim 후보와 다른 집합을 센다.

**영향**: DBA와 성능 분석자가 DWB 설정 변경, checkpoint, victim flush의 동작을 비교할 때 처리한 논리 페이지 수와 파일 쓰기량을 혼동하거나 미수집 값을 작업량 0으로 해석할 수 있다. 집계 지점과 조건은 소스로 확인했으며, 운영 오판 사례·빈도·성능 손실 규모는 확인하지 않았다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

> 아래는 제공된 자료와 확인한 근거를 바탕으로 작성한 상세 맥락이다. 미확인 사항은 본문에 구분한다.

## Description

### 무엇이 문제인가

페이지 버퍼(page buffer)는 디스크 페이지를 메모리에 보관하고 읽기, 변경 페이지의 flush, 교체를 관리한다. BCB는 각 버퍼 슬롯의 식별자와 상태를 관리하는 제어 구조이다. 변경 페이지를 flush하는 사건, 파일에 페이지 데이터를 쓰는 사건, 해당 페이지가 버퍼에서 교체되는 사건은 서로 다르다. 이 이슈는 [CBRD-27193](https://jira.cubrid.org/browse/CBRD-27193)의 통계 의미와 관측 가능성 범위를 다룬다.

분석 기준은 CUBRID 커밋 `f6cac312310f39f46711693da157a08f0e725693`이다. 아래 내용은 이 기준의 소스 확인 결과이며, 별도 실행 실험이나 출시 버전별 검증 결과는 아니다.

### SHOW 폐기 이후의 현재 상태

[PR #7592](https://github.com/CUBRID/cubrid/pull/7592)는 2026-08-21 병합되었으며, per-thread `PGBUF_STATUS`와 이전 조회값을 보관하던 상태를 제거했다. 결과 컬럼 배치는 유지하면서 다음 9개 컬럼을 항상 NULL로 반환한다. 과거의 SHOW write 누락과 조회 간 델타 간섭은 이 상태 제거 이전의 문제이다. [병합 변경](https://github.com/CUBRID/cubrid/commit/667f1c8dce9bb4e845edc5e4ad8c9f9092355320), [현재 컬럼 정의](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/parser/show_meta.c#L694-L723)

`Hit_rate`, `Num_hit`, `Num_page_request`, `Num_pages_created`, `Num_pages_written`, `Pages_written_rate`, `Num_pages_read`, `Pages_read_rate`, `Num_flusher_waiting_threads`가 대상이다. 현재 `pgbuf_start_scan()`도 이 컬럼들에 직접 NULL을 넣는다. [현재 반환 코드](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L17422-L17488)

소스는 statdump의 `Num_data_page_fetches`, `Num_data_page_ioreads`, `Num_data_page_iowrites`, `Data_page_buffer_hit_ratio`를 대체 지표로 안내한다. 다만 대체 경로가 있다는 사실과 각 지표가 논리 작업량 또는 물리 I/O를 정확히 무엇으로 정의하는지는 별개이다. 남은 지표의 의미와 수집 조건을 함께 정리해야 한다.

### 현재 지표가 세는 사건

| 지표 | 확인한 집계 조건과 해석상 제약 |
|---|---|
| `Num_data_page_iowrites` (`PSTAT_PB_NUM_IOWRITES`) | non-DWB flush에서는 `fileio_write()` 전에 1을 더하므로 실패한 시도도 남을 수 있다. DWB에서는 DWB 파일 쓰기 후 블록의 페이지 수를 더하고, 원위치 볼륨에 쓴 페이지 수를 별도로 더한다. 페이지 단위 누적값이며 시스템 호출 횟수나 논리 flush 횟수와 같지 않다. |
| `Num_data_page_writes` (`PSTAT_PB_FLUSH_PAGE_FLUSHED`) | `pgbuf_bcb_flush_with_wal()`의 오류 검사를 통과한 공통 성공 경로에서 증가하지만, 통계 수집과 `PB_VICTIMIZATION` 활성화가 필요하다. DWB에 넘긴 성공도 포함하므로 파일 쓰기 완료·동기화 완료·버퍼 교체를 직접 뜻하지 않는다. |
| `Num_data_page_flushed` (`PSTAT_PB_NUM_FLUSHED`) | `pgbuf_flush_victim_candidates()`가 처리한 `total_flushed_count`를 더한다. 전체 checkpoint와 개별 동기 flush를 포괄하는 지표로 해석할 수 없다. |
| `Num_data_page_ioreads` (`PSTAT_PB_NUM_IOREADS`) | 비상주 기존 페이지의 로딩 경로에서 DWB 조회와 `fileio_read()` 전에 증가한다. DWB 메모리 사본에서 읽기를 마친 경우와 이후 파일 읽기가 실패한 경우도 포함할 수 있어, 성공한 물리 읽기 수로 해석할 수 없다. |
| SHOW `Victim_candidate_pages` | BCB 전수 스캔에서 LRU zone 3이면서 dirty인 슬롯 수를 센다. 내부 `count_vict_cand`의 합을 노출하는 `Num_data_page_victim_candidate`와 같은 집합이 아니다. 내부 후보의 제외 마스크에는 dirty, flushing, direct victim 관련 상태가 포함된다. |
| SHOW `Clean_pages`, `Dirty_pages`, `Free_pages`, `Page_size` | 모든 슬롯을 먼저 clean/dirty로 분류하고 invalid 슬롯을 free로 추가 분류한다. 따라서 clean/dirty 합은 pool 크기이며 free와 중첩된다. `Page_size`는 `IO_PAGESIZE`가 아니라 제어 포인터 영역과 디버그 가드를 포함할 수 있는 `PGBUF_IOPAGE_BUFFER_SIZE`이다. |

쓰기 집계 근거는 [page buffer 분기와 실패 처리](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L10817-L10867), [공통 성공 카운터](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L10898-L10903), [DWB 파일 집계](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/double_write_buffer.cpp#L2328-L2352), [원위치 집계](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/double_write_buffer.cpp#L2085-L2150)이다. `Num_data_page_flushed`는 [victim flusher 종료부](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L4074-L4090), 읽기는 [로딩 경로](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L8453-L8484)에서 확인한다. 지표 이름과 내부 ID는 [perfmon 기본 항목](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/perf_monitor.c#L209-L222), [확장 항목](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/perf_monitor.c#L490-L502)에 정의되어 있다.

snapshot 근거는 [전수 스캔의 분류 순서](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L17299-L17339), [내부 후보 제외 마스크](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L251-L262), [내부 후보 합산](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L14766-L14769), [슬롯 크기 정의](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L110-L120)이다. 스캔은 BCB mutex 없이 진행하므로 동시 변경 중의 값은 한 시점의 원자적 snapshot으로 간주하지 않는다.

### DWB와 통계 활성화에서 구분해야 할 사항

DWB(Double Write Buffer)는 원위치 쓰기에 앞서 별도 파일에 페이지 사본을 기록하는 보호 장치이다. `double_write_buffer_size`의 기본값은 2 MiB이나, 실제 flush 경로는 DWB 생성 여부와 임시 볼륨 여부로 선택한다. 페이지 버퍼 분기에 DWB용 `PSTAT_PB_NUM_IOWRITES` 증가가 없다는 사실만 보고 전체 미집계라고 결론 내릴 수 없다. DWB 구현이 이 값을 별도로 집계한다. [기본값](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/system_parameter.c#L4352-L4363), [경로 선택](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L10692-L10697), [DWB 사용 조건](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L10747-L10770)

또한 “DWB 활성 시 논리 flush의 정확히 2배”를 지표 계약이나 검증식으로 삼을 수 없다. `dwb_add_page()`는 페이지를 DWB에 등록한 뒤 블록이 차지 않아도 성공을 반환하고, 같은 데이터의 중복 쓰기를 피하려고 슬롯을 무효화할 수 있다. 원위치 쓰기에서는 무효 VPID와 제거된 볼륨을 건너뛴다. 따라서 관측 구간, 블록 채움, 중복 처리와 오류 여부를 맞춰야 집계 차이를 해석할 수 있다. 원위치 쓰기 수의 증가에는 `SERVER_MODE` 조건도 있어 실행 모드별 검증이 필요하다. [DWB 등록과 반환](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/double_write_buffer.cpp#L2757-L2818), [원위치 제외 조건](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/double_write_buffer.cpp#L2037-L2065), [서버 모드 집계](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/double_write_buffer.cpp#L2102-L2119)

쓰기 누적 통계의 `perfmon_add_stat()` 경로는 watcher가 있어 수집 중일 때 증가한다. 여기에 `Num_data_page_writes`는 `PB_VICTIMIZATION` 활성화 조건이 추가된다. `extended_statistics_activation` 기본값에는 이 플래그가 없으므로, 기본 설정에서 이 값이 증가하지 않는 것을 flush가 없었다는 뜻으로 읽을 수 없다. 플래그를 켜는 우회 관측은 가능하지만, 수집 범위와 비용을 확인하고 운영 절차에 반영해야 한다. 상시 수집 비용이 작다는 측정 근거는 없다. [일반 수집 조건](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/perf_monitor.h#L918-L931), [watcher와 활성화 검사](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/perf_monitor.h#L1495-L1512), [기본 활성화 값](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/system_parameter.c#L4155-L4168)

`fileio`의 `compensate_flush`는 별도 개념이다. 기본 쓰기 모드에서 flush 제어 토큰과 주기적 동기화를 처리하며, DWB 쓰기는 `FILEIO_WRITE_NO_COMPENSATE_WRITE`를 사용한다. 이것을 통계 카운터의 DWB 중복분 차감으로 해석해서는 안 된다. 파일 계층의 `PSTAT_FILE_NUM_IOWRITES` 증가도 이 선택 뒤에 따로 존재한다. [flush 제어](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/file_io.c#L636-L677), [파일 쓰기 후처리](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/file_io.c#L4207-L4214)

### 왜 문제인가

예를 들어 DBA가 checkpoint 이후 `Num_data_page_flushed`만 조회하면 victim flusher 밖의 쓰기량을 설명할 수 없다. DWB를 켠 상태의 `Num_data_page_iowrites`를 논리 flush 수로 비교하면 DWB 파일과 원위치의 기록량을 함께 읽게 된다. 반대로 `Num_data_page_writes`를 사용하더라도 수집 플래그가 꺼져 있거나 DWB 파일 쓰기가 아직 끝나지 않았다면 관측값의 의미가 달라진다. 이는 코드로부터 도출한 해석 위험이며, 현재 성능 저하를 측정한 결과는 아니다.

`Victim_candidate_pages`를 바로 재사용할 후보 수로 읽는 것도 위험하다. 실제 SHOW 값은 먼저 flush가 필요한 dirty 집합을 세기 때문에 내부 후보 수와 대조할 때 다른 현상으로 오인할 수 있다. 같은 이유로 free 슬롯을 clean과 별개의 집합으로 더하면 pool 점유량을 중복 계산한다.

폐기된 SHOW hit 대신 안내되는 `Data_page_buffer_hit_ratio`도 정의를 명시해야 한다. 현재는 `fetches`에서 `ioreads`를 뺀 값을 분자로 계산한다. NEW_PAGE는 읽기 증가 경로를 거치지 않으며, DWB에서 메모리 복사로 공급된 기존 페이지는 `ioreads`에 포함될 수 있다. 이를 엄밀한 “기존 페이지를 버퍼에서 찾은 비율”이나 장치 I/O 회피율로 읽을 수 있는지는 별도 계약이 필요하다. [비율 계산](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/base/perf_monitor.c#L1881-L1886), [fetch 집계](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/page_buffer.c#L2521-L2527), [DWB 메모리 읽기](https://github.com/CUBRID/cubrid/blob/f6cac312310f39f46711693da157a08f0e725693/src/storage/double_write_buffer.cpp#L3979-L4014)

### 왜 해결해야 하는가

현재 코드를 경로별로 추적하면 통계를 해석할 수 있지만, 모니터링과 성능 비교 때마다 이 추적을 반복해야 한다. SHOW 폐기에 따라 statdump를 사용하도록 안내하는 상황에서는 대체 지표의 정의와 설정 전제가 일관되어야 한다. 정의가 다른 값을 같은 작업량으로 비교하면 page buffer 개선 효과와 DWB의 쓰기 증폭을 분리하기 어렵다.

현재 관측 경로에서 무엇을 알 수 있는지 명시하고, 필요한 논리 처리량을 구분해 볼 수 있도록 관측 공백을 해소해야 한다. 문서와 기존 활성화 설정만으로 충분한 부분과 코드 변경이 필요한 부분을 ANALYSIS에서 구분한다. 긴급도와 고객 노출 범위는 미확인이다.

## Specification Changes

논리 flush 처리, 파일에 쓴 페이지 양, 읽기 시도, 내부 victim 후보와 flush가 필요한 dirty 집합을 구분해 정의한다. 각 지표에는 단위, 집계 경로, 성공·실패 포함 여부, 수집 설정, 실행 모드, snapshot 또는 구간 누적 여부를 명시한다. flush는 페이지 교체나 영속화 완료와 동의어로 사용하지 않는다.

폐기된 9개 SHOW 컬럼의 NULL 계약과 컬럼 배치를 호환성 기준으로 삼는다. 복원, 재정의, 신규 지표 추가 여부는 실제 관측 요구와 소비자 영향을 확인한 뒤 결정한다. `Page_size`, clean/dirty/free, hit ratio의 설명도 실제 계산식과 일치시킨다. 현재 매뉴얼의 설명과 외부 모니터링 스크립트의 의존 여부는 추가 확인이 필요하다.

## Implementation

TBD - ANALYSIS 단계에서 결정한다. 기존 지표와 설정을 이용한 관측 절차, 설명 보완, 집계 지점 또는 노출 지표 변경의 필요성을 검토한다. 통계 기본 활성화 변경, 이름 변경, checkpoint 집계 확대, 별도 flush 필요량 지표 신설은 합의된 구현 방안으로 간주하지 않는다.

## Acceptance Criteria

- [ ] 대상 지표별 정의표가 작성되어 단위·완료 시점·집계 경로·실패 포함 여부·수집 조건·실행 모드를 설명한다.
- [ ] DWB 활성/비활성 및 임시 볼륨 경로에서 논리 flush 처리와 파일 기록량을 구분해 관측하는 방법을 제시하고, 값의 차이를 해당 정의로 설명한다. 고정 2배 관계를 판정 기준으로 사용하지 않는다.
- [ ] 기본 설정과 `PB_VICTIMIZATION` 활성화 상태를 구분하여, 수집하지 않은 값과 실제 작업량 0을 오인하지 않는 사용 절차를 검증한다.
- [ ] checkpoint와 victim flush를 구분한 확인 결과로 `Num_data_page_flushed`의 범위를 설명한다.
- [ ] SHOW의 NULL 컬럼, victim 관련 두 집합, clean/dirty/free 중첩, 슬롯 크기, statdump hit ratio의 의미가 코드와 사용자 설명에서 일치한다.
- [ ] 의미나 노출 방식의 변경이 필요한 항목은 호환성 결정과 필요한 회귀 검증을 기록한다. 기존 동작을 유지하는 항목은 유지 근거와 사용 제약을 기록한다.

## Definition of done

정의표와 관측 절차를 검토하고, 선택한 변경에 맞춰 소스·도움말·매뉴얼·관련 테스트의 일치를 확인한다. 검증 기록에는 전체 빌드 식별자, 실행 모드, DWB 및 통계 활성화 설정, workload, 수집 시작·종료와 DWB 배출 조건을 남긴다. 코드가 바뀌는 경우 선택한 사건의 계수와 실패 시 의미를 확인하는 집중 검증을 수행한다. 실행하지 않은 항목과 확인하지 못한 출시 버전은 구분하여 남긴다.

## Triage Request

현재 관측 경로에서 지표의 의미와 수집 조건을 혼동할 수 있는 문제를 확인하고, 작성자 측에 ANALYSIS를 배정할 것을 요청한다. 분석에서는 논리 처리량의 관측 요구, 기존 활성화 설정으로 충족 가능한 범위, 기본 수집 정책과 비용, 실행 모드 차이, 오류 시 집계 계약, 소비자 호환성을 결정한다. 최종 우선순위와 담당자는 triage에서 정한다.

성능 분석과 검증 workload의 공통 요구는 [CBRD-27423](https://jira.cubrid.org/browse/CBRD-27423)과 공유한다. 통계 정의 확인을 위한 별도 선행 완료 의무를 만들지는 않는다. 큐 정책을 변경할 때 필요한 `pgbuf_peek_stats()` 출력값 계약은 [CBRD-27267](https://jira.cubrid.org/browse/CBRD-27267)과 조율한다. 일반 죽은 코드·주석 정리는 [CBRD-27269](https://jira.cubrid.org/browse/CBRD-27269)에서 다룬다.
