# [PGBUF] page buffer 통계의 논리 페이지와 물리 I/O 의미를 정리한다

## Issue Triage

**이슈 수행 목적**: DWB 가 켜진 기본 설정에서도 page buffer 의 쓰기·읽기·victim 지표가 실제 동작을 반영하도록, 논리 page flush 와 물리 write 를 분리한 통계 계약을 확정하고 미집계 지점을 채운다.

**이슈 수행 이유**:

| 구분 | 내용 |
|---|---|
| **AS-IS (현재 동작 / 배경)** | DWB(Double Write Buffer — 원래 위치에 쓰기 전 별도 파일에 page 사본을 먼저 기록하는 torn-write 보호 장치)는 `double_write_buffer_size` 기본값이 2 MiB 라 기본 활성인데(`system_parameter.c:4345`), page buffer 의 쓰기 관련 카운터가 DWB 도입 전의 "page 1장 flush = 볼륨 write 1회" 전제로 배치되어 있다. 그 결과 기본 설정에서 "page buffer 가 page 를 몇 장 내보냈는가" 를 맞게 답하는 지표가 하나도 없다. 읽기 카운터, `Victim_candidate_pages`, `Num_data_page_flushed`, NEW_PAGE 의 hit 집계도 이름과 실제 집계 조건이 어긋나 있다. 지표별 집계 지점과 실측 근거는 아래 Description 의 불일치 목록에 정리했다. |
| **TO-BE (목표 상태 / 기대 동작)** | 지표를 논리 축(pgbuf 가 flush 한 page 수)과 물리 축(볼륨에 실제 발생한 write 수)으로 나누어 정의하고, 이름·도움말·집계 지점을 그 정의에 맞춘다. DWB on/off 가 값의 의미를 바꾸지 않는다. 이름과 집계 조건이 어긋난 나머지 항목도 같은 기준으로 정리한다. |
| **영향** | 설계 의도 훼손 — flush 부하 조사에 쓸 지표가 없다. DBA 가 `SHOW PAGE BUFFER STATUS` 를 보면 write 가 0 이고, `cubrid statdump` 의 `Num_data_page_iowrites` 를 보면 실제 flush 량의 약 2배라, 두 지표 중 어느 쪽도 그대로 읽으면 틀린 결론에 도달한다. |

**이슈 수행 방안**:

- `num_pages_written` 미집계(N8)는 집계 지점을 DWB/non-DWB 공통 성공 처리부로 옮겨 수정한다.
- 나머지 정의 불일치는 지표별 계약을 확정한 뒤 이름·도움말·집계 조건을 맞춘다. 아래 Implementation 의 계약 표가 후보안이다.
- 기존 `SHOW PAGE BUFFER STATUS` 컬럼을 재정의할지, 새 컬럼을 추가하고 기존 컬럼을 단계적으로 폐기할지는 `TBD - 합의 미확인`.
- SHOW 델타 컬럼의 파괴적 읽기는 이번 범위에서 동작을 바꾸지 않고 매뉴얼에 제약으로 명시하는 것까지만 한다.

------------------------------------------------------------------------

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: `src/storage/page_buffer.c`(집계 지점, `pgbuf_scan_bcb_table`, `pgbuf_start_scan`), `src/storage/double_write_buffer.cpp`(물리 write 집계), `src/base/perf_monitor.c`(지표 이름), `src/parser/show_meta.c`(SHOW 컬럼 정의), CUBRID 매뉴얼의 `SHOW PAGE BUFFER STATUS` 와 statdump 항목 설명. 디스크 형식과 클라이언트 API 는 바뀌지 않는다. 다만 컬럼 이름·의미를 바꾸면 이 컬럼을 파싱하는 외부 모니터링 스크립트와 QA 기대값이 깨지므로, 호환성 결정이 구현 범위를 좌우한다.
- 부모 EPIC 은 CBRD-27193 이고, 이 이슈가 소유하는 결함은 D6(통계 의미 불일치 4건)과 N8(DWB 경유 write 미집계)이다.

------------------------------------------------------------------------

## Description

pgbuf(page buffer manager — 디스크 page 를 메모리 frame 에 캐시하고 fix, latch, 교체, flush 를 관리하는 모듈)의 통계는 서로 독립한 세 계층에 산다.

| 계층 | 저장소 | 노출 경로 |
|---|---|---|
| `PGBUF_STATUS` (thread 별 샤드) | `pgbuf_Pool.show_status[]` (`page_buffer.c:395-404`) | `SHOW PAGE BUFFER STATUS` 의 델타 컬럼 |
| `PGBUF_STATUS_SNAPSHOT` (전수 스캔) | `pgbuf_Pool.show_status_snapshot` (`:406-416`) | `SHOW PAGE BUFFER STATUS` 의 현재값 컬럼 |
| perfmon `PSTAT_PB_*` | perf_monitor 모듈 | `SHOW EXEC STATISTICS`, `cubrid statdump` |

세 계층이 각자 자기 지점에서 카운터를 올리는데, 같은 사건을 세는 카운터들이 서로 다른 분기에 놓여 있어서 이름이 시사하는 의미와 실제 집계 조건이 어긋났다. 특히 DWB 도입 이후 "page 1장 flush" 와 "볼륨 write 1회" 가 더 이상 1:1 이 아니게 되었는데, 카운터는 그 구분을 반영하지 않았다.

### flush 경로의 카운터 위치

```
pgbuf_bcb_flush_with_wal()                                   page_buffer.c:10673
  uses_dwb = dwb_is_created () && !is_temp                              :10743
  ├ TDE 암호화 또는 memcpy 로 iopage 사본 생성                          :10749-10761
  ├ uses_dwb 면 dwb_set_data_on_next_slot 으로 DWB 슬롯에 복사           :10762-10774
  ├ BCB unlock → logpb_flush_log_for_wal (WAL 규칙 강제)                :10781-10789
  ├ if (uses_dwb) → dwb_add_page ()                                     :10811-10825
  │    ★ show_status->num_pages_written 증가 없음
  │    ★ PSTAT_PB_NUM_IOWRITES 증가 없음 (실제 write 는 DWB 가 별도 집계)
  └ else                                                                :10826-10839
       show_status->num_pages_written++                                 :10828
       perfmon_inc_stat (PSTAT_PB_NUM_IOWRITES)                         :10833  (write 시도 전)
       fileio_write ()                                                  :10834
  ...
  └ 성공 처리부
    if (perfmon_is_perf_tracking_and_active (PB_VICTIMIZATION))         :10894
      perfmon_inc_stat (PSTAT_PB_FLUSH_PAGE_FLUSHED)                    :10896
      ★ 이 게이트가 기본 off 라 논리 flush 카운터도 기본 0
```

DWB 측 집계는 `double_write_buffer.cpp` 안에 따로 있다. `dwb_flush_block` 이 DWB 파일에 블록을 쓴 뒤 `PSTAT_PB_NUM_IOWRITES` 를 `block->count_wb_pages` 만큼 더하고(`:2339`), 이어서 원위치 볼륨으로 옮겨 쓰는 `dwb_write_block` 이 다시 `count_writes` 만큼 더한다(`:2115`, `:2150`). page 1장이 DWB 를 거치면 물리 write 는 실제로 2회이므로 이 집계 자체는 물리 관점에서 맞다. 문제는 같은 카운터가 DWB off 에서는 page 당 1 이 되어 DWB 설정에 따라 배율이 달라지는 것, 그리고 이 카운터를 논리 flush 량으로 읽는 관행이다.

> **요지**: DWB 를 켜면 물리 write 카운터만 남고 논리 flush 카운터는 두 경로(SHOW 컬럼, perfmon 게이트)에서 동시에 0 이 된다. 지표 하나를 고치는 문제가 아니라 논리/물리 축을 나누는 계약 문제다.

### 이전 분석에서 정정된 부분

부모 EPIC 의 N8 서술은 `PSTAT_PB_NUM_IOWRITES` 도 DWB 경유 쓰기를 집계하지 않는다고 적었으나, `e6ed61e87` 소스 재확인 결과 이 부분은 사실이 아니다. DWB 가 `double_write_buffer.cpp:2115`, `:2150`, `:2339` 에서 자체적으로 더하고 있으며, 오히려 page 당 2회로 과다 집계된다. 미집계가 확인된 것은 `show_status->num_pages_written` 뿐이다. 구 분석 보고서(commit `5cd4f860e`)의 D6(a) 항목은 이 이중 집계를 이미 지적하고 있었으므로, EPIC 요약 단계에서 두 사실이 섞인 것으로 보인다.

### 확인된 불일치 목록

아래는 `e6ed61e87` 소스에서 직접 대조한 결과다. 라인은 `page_buffer.c` 기준이며 다른 파일은 별도 표기했다.

| # | 지표 | 집계 지점 | 실제 의미 | 이름·도움말과의 간극 |
|---|---|---|---|---|
| 1 | SHOW `Num_pages_written`, `Pages_written_rate` | :10828 (non-DWB 분기 전용) | DWB 를 거치지 않은 write 만. temp 볼륨 page 와 DWB 비활성 구간만 남는다 | DWB 기본 활성이므로 값이 사실상 0. 이름은 전체 write 를 시사 |
| 2 | perfmon `Num_data_page_iowrites` | :10833 + `double_write_buffer.cpp:2115`, `:2150`, `:2339` | 물리 write 횟수. DWB on 이면 page 당 2회 | 물리 카운터로는 맞지만 DWB 설정에 따라 논리 page 수 대비 배율이 달라진다. `:10833` 은 `fileio_write` 실패 시에도 이미 증가한 상태 |
| 3 | perfmon `Num_data_page_writes` (`PSTAT_PB_FLUSH_PAGE_FLUSHED`) | :10896, 게이트 :10894 | pgbuf 가 성공적으로 flush 한 논리 page 수 — 사실상 유일한 논리 지표 | `extended_statistics_activation` 기본값에 `PB_VICTIMIZATION`(0x10)이 없어 기본 0. 이름도 "writes" 라 물리 지표처럼 읽힌다 |
| 4 | perfmon `Num_data_page_flushed` (`PSTAT_PB_NUM_FLUSHED`) | :4118 (`pgbuf_flush_victim_candidates` 종료 시 1회) | victim flush 데몬이 flush 한 page 수만 | checkpoint flush 와 개별 동기 flush 는 빠진다. 이름은 전체 flush 량을 시사 |
| 5 | SHOW `Victim_candidate_pages` | :17312-17315, 컬럼 값 :17451 | LRU zone 3 이면서 **dirty** 인 BCB 수 | dirty BCB 는 victim 이 될 수 없다(`PGBUF_BCB_INVALID_VICTIM_CANDIDATE_MASK`, :258-262, 주석 :254). 실제 후보 수는 각 LRU 리스트의 `count_vict_cand` 합계이고 perfmon `Num_data_page_victim_candidate` 로 별도 노출된다(:14756). 같은 이름의 두 지표가 정반대 집합을 센다 |
| 6 | SHOW `Hit_rate`, `Num_hit` | :2327, :2348, :8577 | :8577 은 NEW_PAGE 생성 경로 — 디스크 read 가 없었던 신규 page 를 hit 으로 계산 | insert 중심 부하에서 hit rate 가 과대. `num_pages_created` 도 같은 지점(:8576)에서 오르므로 중복 계산 관계가 드러나지 않는다 |
| 7 | SHOW `Num_pages_read`, perfmon `Num_data_page_ioreads` | :8444-8445 | `dwb_read_page`(:8456)와 `fileio_read`(:8466) **이전** 에 증가. DWB 버퍼에서 복사해 온 경우와 read 실패도 포함 | 물리 read 수가 아니라 read 시도 수 |
| 8 | SHOW `Clean_pages`, `Dirty_pages` | :17297-17310 | invalid zone BCB 까지 포함해 합이 항상 `Pool_size` | `Free_pages`(:17308)와 중복 계산된다. `Clean_pages` 를 "재사용 가능한 깨끗한 page" 로 읽으면 틀린다 |
| 9 | SHOW `Page_size` | :17445 | `PGBUF_IOPAGE_BUFFER_SIZE` — BCB 의 iopage 슬롯 크기(헤더와 `CUBRID_DEBUG` 가드 포함) | `IO_PAGESIZE` 로 오독된다 |
| 10 | SHOW 델타 컬럼 8개 | :17508-17513 | SHOW 실행이 `status_old` 를 갱신하는 파괴적 읽기 | 두 세션이 동시에 모니터링하면 서로의 구간 값을 갉아먹는다. `show_status_mutex`(:17386, :17518)는 이 갱신을 직렬화할 뿐 간섭 자체를 막지 못한다 |

### 라인 대조에서 확인된 문서 오차

기존 상세 분석서(`pgbuf_docs/06-misc-observability.md` §6.4)는 SHOW 컬럼 값 생성 라인을 17425-17501 로, 파괴적 읽기를 17506-17511 로 적었다. `e6ed61e87` 실측은 각각 17421-17502, 17508-17513 이다. 컬럼 순서와 대응 관계는 동일하고 라인만 3 정도 밀려 있다. 이 이슈 본문의 라인은 실측값을 따랐다.

## Specification Changes

지표 계약을 아래와 같이 확정하는 것을 전제로 한다. 컬럼 이름 확정과 기존 컬럼 처리 방식은 Open Questions 를 해소한 뒤 정한다.

| 축 | 정의 | 세는 사건 | DWB on 에서의 기대 |
|---|---|---|---|
| 논리 flush | pgbuf 가 page 를 buffer 밖으로 내보낸 횟수 | `pgbuf_bcb_flush_with_wal` 성공 1회 = 1 | DWB off 와 같은 값 |
| 물리 write | 볼륨 파일에 발생한 write 횟수 | `fileio_write` 계열 호출 1회 = 1 | 논리 flush 의 약 2배 (DWB 파일 + 원위치) |
| victim 후보 | 지금 victim 으로 뽑을 수 있는 BCB 수 | zone 3 이면서 `PGBUF_BCB_INVALID_VICTIM_CANDIDATE_MASK` 에 걸리지 않는 BCB | flush 대기 중인 dirty 는 제외 |
| flush 필요량 | victim 이 되려면 flush 가 먼저 필요한 BCB 수 | zone 3 이면서 dirty | 현행 `Victim_candidate_pages` 가 실제로 세던 값 |

문서 갱신 대상:

- `SHOW PAGE BUFFER STATUS` 의 델타 컬럼 8개가 "마지막 SHOW 이후" 를 의미하며 SHOW 자체가 카운터를 리셋한다는 제약을 매뉴얼에 명시한다. 동시 모니터링 시 값이 서로 간섭한다는 경고를 포함한다.
- `Clean_pages` + `Dirty_pages` = `Pool_size` 이고 `Free_pages` 와 중복된다는 점, `Page_size` 가 `IO_PAGESIZE` 가 아니라는 점을 컬럼 설명에 반영한다.
- statdump 항목 설명에 논리/물리 축 구분을 넣고, DWB 활성 시 `Num_data_page_iowrites` 가 page 당 2회임을 명시한다.

## Implementation

### 1단계 — 미집계 수정 (N8)

`show_status->num_pages_written` 증가를 `if (uses_dwb)` / `else` 양쪽이 아니라 flush 성공이 확정되는 공통 지점으로 옮긴다. 후보 위치는 `:10848` 의 오류 검사 직후이며, 이 지점은 DWB 경로와 non-DWB 경로가 합류한 뒤이고 실패 경로가 이미 걸러진 곳이다. 같은 지점에 이미 `PSTAT_PB_FLUSH_PAGE_FLUSHED` 가 있으므로(`:10894-10897`) 두 카운터의 의미가 자연스럽게 맞는다.

`PSTAT_PB_NUM_IOWRITES` 는 물리 카운터로 두고 `:10833` 위치를 유지한다. 단 `fileio_write` 실패 시에도 증가하는 문제는 write 성공 확인 이후로 옮겨 해소한다.

### 2단계 — 논리 지표를 기본 노출 (D6-b)

`PSTAT_PB_FLUSH_PAGE_FLUSHED` 의 `PERFMON_ACTIVATION_FLAG_PB_VICTIMIZATION` 게이트(`:10894`)를 제거하거나, 이 카운터만 게이트 밖으로 빼서 기본 수집 대상으로 만든다. flush 성공 1회당 원자 증가 1회라 fix/unfix 급 hot path 가 아니므로 상시 수집 비용은 작다.

`PSTAT_PB_NUM_FLUSHED`(`:4118`)는 victim flusher 전용이라는 사실이 이름에 드러나지 않으므로, 이름을 경로가 드러나게 바꾸거나 checkpoint flush 경로에도 같은 카운터를 추가해 이름대로 만든다. 둘 중 어느 쪽인지는 컬럼 호환성 결정과 함께 정한다.

### 3단계 — snapshot 정의 정합 (D6-c)

`pgbuf_scan_bcb_table`(`:17279-17354`)에서 zone 3 판정 뒤의 조건을 두 개로 나눈다.

| 항목 | 조건 | 대응 컬럼 |
|---|---|---|
| victim 후보 | zone 3 && `(flags & PGBUF_BCB_INVALID_VICTIM_CANDIDATE_MASK) == 0` | victim 후보 수 |
| flush 필요량 | zone 3 && `(flags & PGBUF_BCB_DIRTY_FLAG) != 0` | 현행 `Victim_candidate_pages` 가 세던 값 |

`clean_pages` / `dirty_pages` 는 invalid zone 을 제외할지 현행을 유지하고 문서로만 설명할지 함께 결정한다. 이 스캔은 BCB mutex 없이 돌면서 `flags` 를 지역 변수에 한 번만 읽는 방식(`:17295`)에 의존하므로, 조건을 추가하더라도 같은 지역 변수를 재사용해 읽기 횟수를 늘리지 않아야 한다.

### 4단계 — NEW_PAGE hit 처리 (D6-d)

`:8576-8577` 의 `num_pages_created++` 와 `num_hit++` 중 후자를 어떻게 볼지 정한다. NEW_PAGE 는 디스크 read 를 하지 않으므로 "buffer 에서 찾았다" 는 hit 정의와는 다르지만, "요청을 I/O 없이 처리했다" 는 정의로는 hit 에 가깝다. 정의를 문서로 고정하는 선택도 유효하다. 어느 쪽이든 `Hit_rate` 의 분자 정의가 매뉴얼에 명시되어야 한다.

## Acceptance Criteria

- [ ] DWB 활성 기본 설정에서 쓰기 부하를 준 뒤 `SHOW PAGE BUFFER STATUS` 의 write 지표가 0 이 아니고, 같은 구간의 논리 flush 수와 일치한다.
- [ ] DWB 비활성 설정에서 같은 부하를 주었을 때 논리 flush 지표가 DWB 활성 설정과 같은 규모로 나온다 (물리 write 지표는 약 절반이 되는 것이 정상).
- [ ] victim 후보 지표가 각 LRU 리스트의 `count_vict_cand` 합계와 같은 집합을 세고, flush 필요량 지표가 별도로 조회된다.
- [ ] `extended_statistics_activation` 을 기본값으로 둔 상태에서 논리 flush 지표가 수집된다.
- [ ] 기존 컬럼 호환성 결정(재정의 또는 신규 컬럼 추가)이 본문에 기록되고 구현이 그 결정을 따른다.
- [ ] SHOW 델타 컬럼의 파괴적 읽기 제약이 매뉴얼에 기술된다.

## Definition of done

- [ ] 위 Acceptance Criteria 충족
- [ ] QA 통과 (`SHOW PAGE BUFFER STATUS` 컬럼을 사용하는 기존 shell/SQL 테스트 기대값 갱신 포함)
- [ ] 매뉴얼의 `SHOW PAGE BUFFER STATUS` 컬럼 설명과 statdump 항목 설명 반영
- [ ] 컬럼 이름 또는 의미가 바뀐 경우 운영 문서에 이관 안내 추가

## Open Questions

### 기존 컬럼 호환성

`Num_pages_written` 과 `Victim_candidate_pages` 를 그 자리에서 재정의할지, 정의가 맞는 새 컬럼을 추가하고 기존 컬럼은 유지한 뒤 단계적으로 폐기할지는 `TBD - 합의 미확인` 이다. `SHOW PAGE BUFFER STATUS` 는 `only_for_dba` 이고(`show_meta.c:720`) 컬럼 순서가 고정 배열이라(`show_meta.c:693-713`) 컬럼 추가는 순서 뒤쪽에만 안전하다. 외부 모니터링 스크립트가 컬럼 위치에 의존하는 사례가 있는지 확인이 필요하다.

### `Num_data_page_flushed` 의 목표 정의

victim flusher 전용임을 이름에 드러낼지, checkpoint flush 경로까지 집계해 이름대로 만들지는 `TBD - 합의 미확인` 이다. 후자는 checkpoint 성능 지표와 의미가 겹칠 수 있어 log manager 쪽 지표와 함께 봐야 한다.

### NEW_PAGE 의 hit 집계 유지 여부

`Hit_rate` 분자에서 NEW_PAGE 생성을 제외할지, 현행 정의를 문서로 고정할지는 `TBD - 합의 미확인` 이다. 제외하면 기존에 기록된 hit rate 추이와 값이 불연속이 된다.

## 참고 코드

- `src/storage/page_buffer.c:10673-10900` — `pgbuf_bcb_flush_with_wal`, 쓰기 카운터 집계 지점
- `src/storage/page_buffer.c:17279-17354` — `pgbuf_scan_bcb_table`, snapshot 분류
- `src/storage/page_buffer.c:17367-17535` — `pgbuf_start_scan`, 델타 계산과 `status_old` 갱신
- `src/storage/double_write_buffer.cpp:2115`, `:2150`, `:2339` — DWB 측 물리 write 집계
- `src/base/perf_monitor.c:209-222`, `:485` — pgbuf 관련 perfmon 지표 이름
- `src/base/system_parameter.c:4143-4156` — `extended_statistics_activation` 기본값
- `src/parser/show_meta.c:691-724` — `SHOW PAGE BUFFER STATUS` 컬럼 정의

## Remarks

- 부모 EPIC: CBRD-27193
- 죽은 코드·낡은 주석 정리는 B4 로 분리되어 있어 이 이슈에서 다루지 않는다.
- `pgbuf_peek_stats`(`page_buffer.c:14686-14782`)가 lock-free 큐가 NULL 일 때 `lfcq_big_prv_num` / `lfcq_prv_num` 출력 인자를 대입하지 않는 문제(`:14771-14779`, 진입부 초기화 목록 `:14697-14705` 에도 없음)도 통계 신뢰성 결함이지만, 이 이슈가 아니라 big private victim queue 이슈(CBRD-27267)가 소유한다. 동작이 있는 결함이라 정리 성격의 B4 범위도 아니다.
