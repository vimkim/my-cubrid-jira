# [PGBUF] 페이지 버퍼 안정성·동시성·관측성 개선 EPIC

## Issue Triage

**이슈 수행 목적**: 페이지 버퍼의 안정성·운영성·성능 개선을 하나의 EPIC에서 관리하되, 확인된 정확성 결함을 우선 처리하고 구조 변경은 측정 근거가 확보된 경우에만 진행한다.

**이슈 수행 이유**:

| 구분 | 내용 |
|---|---|
| **AS-IS (현재 동작 / 배경)** | develop `e6ed61e87` 의 `page_buffer.c` 전량(17,535줄) 재분석 결과, 이전 분석(commit `5cd4f860e`)의 상위 결함 D1~D3가 그대로 잔존하고 신규 결함 9건(N1~N9)이 추가 확인됐다. 최고 심각도 N1은 요청 page 의 dealloc 보호 카운터 등록·해제가 `pgbuf_fix` 와 `pgbuf_ordered_fix` 에 흩어져 있어, 5가지 진입 상황 중 3가지에서 짝이 깨지는 비대칭이다 (lock-free 성공 시 -1, 오류 경로에서 -1 또는 +1 영구 잔존). |
| **TO-BE (목표 상태 / 기대 동작)** | 정확성 결함 5건(A1~A5)이 각각 추적 가능한 자식 이슈로 수정되고, 운영성 개선과 구조 변경은 측정 근거가 확보된 뒤에만 착수된다. 자식 이슈 구성 상세는 Implementation 표. |
| **영향** | 고객 장애 가능성 — N1은 vacuum 이 dealloc 을 막으려고 보호해 둔 페이지가 조기 회수될 수 있는 정합성 결함이고, D1(flush 실패 후 BCB 미복구)은 대기 스레드가 깨어나지 못하는 hang 으로 이어질 수 있다. |

**이슈 수행 방안**: CBRD-27193은 page buffer 자식 이슈를 정확성·운영성·조사/설계 3범주로 묶어 완료까지 관리하는 EPIC으로 유지한다. 자식 이슈 구성은 아래 Implementation의 확정 표를 따르고, 목표 동작이 미결정인 항목(A3·B1·B2)은 Open Questions 에 정리했다. EPIC 본문은 이번 재분석 결과로 갱신한다.

------------------------------------------------------------------------

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: `src/storage/page_buffer.c`, `page_buffer.h`, `src/storage/double_write_buffer.cpp`, `src/base/system_parameter.c`, `src/base/perf_monitor.c`, `src/parser/show_meta.c` 가 후보 범위다. EPIC 자체는 디스크 형식과 외부 공개 API를 바꾸지 않지만, 통계 이름·정의 변경(B1)은 모니터링 호환성을 별도로 검토해야 한다. 아래 라인 번호는 별도 표기가 없으면 develop `e6ed61e87` 의 `page_buffer.c` 기준이다.

------------------------------------------------------------------------

## Description

기준 소스는 CUBRID develop commit `e6ed61e87` 이다. 이전 분석(commit `5cd4f860e`, References 참조)의 결함 D1~D8을 재검증하고, 이번에는 `page_buffer.c` 를 자료구조·fix/unfix·LRU/victim·flush/WAL·ordered fix·부가기능의 6개 축으로 전량 정독해 신규 결함 N1~N9를 추가로 확인했다. D 번호는 이전 분석의 결함 ID다 — D1 flush 실패 복구 누락, D2 direct_victims memset 크기, D3 direct victim 유지보수 순회 미실행, D4 big private victim queue 생산 경로, D5 `double_write_buffer_size` 단위 문법, D6 통계 의미 불일치, D7 AOUT 강제 비활성, D8 `pgbuf_peek_stats` 헤더 인자명.

`pgbuf` (page buffer manager — 디스크 page를 메모리 frame에 캐시하고 fix, latch, 교체, flush를 관리하는 모듈)는 page lookup과 교체뿐 아니라 WAL(Write-Ahead Logging — data page보다 log를 먼저 기록하는 규칙), DWB(Double Write Buffer — 원래 위치에 쓰기 전 별도 파일에 page 사본을 기록하는 torn-write 보호 장치), TDE(Transparent Data Encryption — data page 암호화)를 연결한다. BCB(Buffer Control Block — frame에 올라온 page의 fix 수, latch, dirty 상태를 보관하는 제어 블록)는 `latch_mode`, `waiter_exists`, `fcnt` 를 하나의 64-bit atomic word에 저장하며, READ fix/unfix의 lock-free 경로와 일반 latch 대기열이 이 word를 함께 사용한다. LRU(Least Recently Used — 최근 사용 시점 기준의 page 교체 목록)는 shared/private 영역으로 나뉘고, direct victim은 빈 frame을 찾지 못해 대기하는 스레드에 재사용 가능한 BCB를 직접 넘기는 방식이다. ordered fix(`pgbuf_ordered_fix` — heap 페이지 여러 장을 데드락 없이 잡도록 전역 순서에 따라 래치를 재배열하는 fix 변형)는 heap scan 의 표준 진입로다. AOUT는 2Q 교체 정책에서 main queue에서 밀려난 page identifier의 이력을 보관하는 queue다.

### 신규 확인 결함 (N1~N9, e6ed61e87 기준)

| ID | 위치 (page_buffer.c) | 내용 | 분류 |
|---|---|---|---|
| N1 | :2425-2428, :2513-2517, :12702, :12850, :12972-12998 | 요청 page 의 dealloc 보호 카운터 등록·해제가 `pgbuf_fix` 와 `pgbuf_ordered_fix` 에 분담되어 있는데, 5가지 진입 상황 중 3가지에서 짝이 깨진다 — ① 1차 시도가 lock-free fast path 로 성공하면 등록 없이 해제(-1, 타 스레드 보호 절취), ② 등록 도달 전 실패 후 재정렬 성공이면 등록 없는 해제(-1, 드묾), ③ 재정렬 중 실패 시 exit 정리(:12972-12998)가 `has_dealloc_prevent_flag` 를 소비하지 않아 +1 영구 잔존(해당 page 는 vacuum 회수에서 영구 제외). 회계 표 전체는 아래 "2순위(A2) 오류 흐름" 절과 CBRD-27263 참조. | 정합성 (High) |
| N2 | :8456-8461 | `pgbuf_claim_bcb_for_fix` 의 `dwb_read_page` 실패 경로가 인접 실패 경로와 달리 BCB mutex를 든 채 반환한다. release 빌드에서 해당 BCB 영구 잠금 + 같은 VPID 대기자의 무한 대기로 이어진다. | 가용성 (방어 경로) |
| N3 | :9407, :9505-9508, :9577, :9586 | direct victim 긴급 배정 경로 2곳이 실행되지 않는다. `pgbuf_panic_assign_direct_victims_from_lru` 는 호출부(:9407)가 직전에 NULL이 된 `prev_BCB` 를 전달해 NULL 가드(:9505-9508)에서 즉시 0을 반환하고, `pgbuf_direct_victims_maintenance` 의 두 순회(:9577, :9586)는 초기 조건 모순으로 본문이 한 번도 돌지 않는다 (D3와 동일 계열). 관측 가능 증상: 이 경로들만 올리는 `Num_victim_assign_direct_panic` 통계가 어떤 부하에서도 0 이다. | 기존 D3의 범위 확장 |
| N4 | :11349, :11369, :11321-11338, :3284, :11444, :11468 | `CUBRID_DEBUG` 정의 시 컴파일 오류 13건 실측 — atomic latch/flags 개편 이전 필드(`bufptr->fcnt` :11349, `bufptr->zone` :11369; :11361 은 신 접근자 공존), 2017년 volume-info 제거(b634bb442) 잔재 필드 참조 7건(:11321-11338), `pgbuf_unfix_all` 오타(:3284), const 위반 2건(:11444, :11468). finalize 진단 경로가 사장된 상태다. | 진단 도구 |
| N5 | :15255, :15271 | `pgbuf_rv_dealloc_undo_compensate` 가 대입된 적 없는 지역 `VPID vpid` 를 debug TDE 로그로 출력한다 (`pgbuf_rv_dealloc_undo` :15209-15210에서 복사된 코드로 보이며 초기화 누락). | debug 한정 |
| N6 | :5851 + :1980, :13949 | `Aout_mutex` 가 초기화 실패 경로와 finalize에서 이중 `pthread_mutex_destroy` 되고(미정의 동작), quota 비활성 시 `malloc (0)` 반환값에 의존한다. D2(memset 크기 오류, :1626)와 같은 초기화/종료 위생 계열이다. | D2의 범위 확장 |
| N7 | :5497-5501 | `pgbuf_is_temporary_volume` 이 `LOG_ISRESTARTED ()` 이전(복구 수행 중)에는 항상 false를 반환해, 복구 중 temp page가 WAL 면제·LRU 승격 억제·DWB 우회 등 temp 특수 처리를 전혀 받지 못한다. 의도된 보수 동작인지 판정이 필요하다. | 조사 |
| N8 | :10828, :10833 | `show_status->num_pages_written`(:10828) 증가가 non-DWB 분기에만 있어 DWB(기본 활성) 경유 쓰기가 집계되지 않는다 — `SHOW PAGE BUFFER STATUS` 의 `Num_pages_written`/`Pages_written_rate` 가 사실상 0. 반면 `PSTAT_PB_NUM_IOWRITES`(:10833)는 DWB 가 자체 집계(double_write_buffer.cpp:2339, :2115, :2150)해 page 당 2회로 과다 집계된다 — 한 지표는 누락, 한 지표는 이중 (D6 통계 의미 정리와 같은 계열). | D6의 범위 확장 |
| N9 | :14446, :10585, :300, :771-774, :10772, page_buffer.h:320-326 | 죽은 코드·낡은 주석 — `monitor.victim_rich` 는 계산되지만 소비처가 없고(:9046-9053 주석은 이를 재시도 조건으로 설명해 코드와 불일치), `pgbuf_remove_private_from_aout_list` 는 호출부가 없으며, `UINT16MAX` 매크로 미사용, "garbage LRU" 구획 주석은 현재 코드에 없는 설명, `goto copy_unflushed_lsa`(:10772)는 레이블(:10776)까지 닫는 중괄호만 건너뛰어 fall-through 와 도달 지점이 같아 무의미하다. `pgbuf_fix_without_validation_release` 는 헤더 선언과 release 전용 매크로(page_buffer.h:320-326)만 있고 정의·호출부가 소스 어디에도 없다. | 정리 |

## Specification Changes

EPIC 자체의 실행 스펙 변경은 없다. 각 자식 이슈에서 변경 전후 동작, 호환성, 성능 기준을 확정한다.

## Implementation

### 자식 이슈 구성 (확정안)

    CBRD-27193 page buffer EPIC
    ├─ A. 정확성 (Correct Error) ── 5건: 기존 1건 확장 + 신규 4건
    ├─ B. 운영성 (Improve) ──────── 4건: 전부 신규
    └─ C. 조사/설계 (Survey) ────── 기존 3건 + 신규 1건 + 선택 3건

| ID | 제목 (안) | 이슈 번호 | 포함 결함 | 비고 |
|---|---|---|---|---|
| A1 | [PGBUF] flush 준비 후 TDE/DWB 오류 시 BCB 상태를 복구한다 | 신규 필요 | D1 + N2 | 두 early return을 기존 write 실패 정리 경로(`pgbuf_bcb_mark_was_not_flushed` + LSA 복원 + waiter 기상)로 합치고, `dwb_read_page` 실패 시 mutex 해제·정리를 추가한다. TDE·DWB 오류 주입으로 검증. |
| A2 | [PGBUF] ordered fix 경로의 dealloc 보호 카운터 비대칭을 수정한다 | 신규 필요 | N1 | heap scan + vacuum 동시 수행 시나리오로 검증. 수정 후보 3안 비교와 선택은 Open Questions 참조. |
| A3 | [PGBUF] direct victim 긴급 배정 경로가 실행되지 않는 오류를 처리한다 | 신규 필요 | D3 + N3 | 저활동 direct-victim workload로 검증. 목표 동작 선택은 Open Questions 참조. |
| A4 | [PGBUF] 초기화/종료 경로의 위생 결함을 일괄 수정한다 | CBRD-27194 확장 | D2 + N6 | memset 대상 타입 크기 일치, mutex destroy 소유권을 finalize로 단일화, 개수 0이면 할당 생략. 초기화 중간 실패 경로 검사 포함. |
| A5 | [PGBUF] debug 빌드 전용 결함 2건을 수정한다 | 신규 필요 | N4 + N5 | `pgbuf_dump` 를 현행 접근자(`get_fcnt`, `pgbuf_bcb_get_zone`)로 재작성 — 함수가 `#if defined(CUBRID_DEBUG)`(:11219) 안에 있고 :11361 은 이미 신 접근자를 쓰는 점이 범위 판단 근거. 미초기화 VPID는 `rcv->pgptr` 에서 채운다. CUBRID_DEBUG 정의 빌드 통과로 검증. 영역이 달라 분리 요구 시 2건으로 나눈다. |
| B1 | [PGBUF] page buffer 통계의 논리 페이지와 물리 I/O 의미를 정리한다 | 신규 필요 | D6 + N8 | DWB 사용 시 논리 page flush 와 물리 write 를 구분하고 `Num_pages_written` 미집계를 수정. |
| B2 | [PGBUF] big private victim queue의 생산 경로를 복구하거나 제거한다 | 신규 필요 | D4 | `big_private_lrus_with_victims` 의 생산/소비 지점 확정이 선행 작업. |
| B3 | [PGBUF] double_write_buffer_size에 크기 단위 문법을 지원한다 | 신규 필요 | D5 | `PRM_INTEGER` 라 `2M` 입력을 거부하며 서버 시작까지 실패. `0`, byte 정수, `K/M` 입력과 32 MiB 상한을 다른 size parameter와 정합. |
| B4 | [PGBUF] 죽은 코드와 낡은 주석을 정리한다 | 신규 필요 | N9 + D8 | 동작 무변경 정리라 A/B 결함 수정과 분리해 revert 단위를 깨끗하게 유지한다. |
| C1 | [PGBUF] [Survey] SX page latch 도입 조사 | CBRD-27196 (기존) | — | 설계 논점은 해당 이슈 본문에 이관 완료. |
| C2 | [PGBUF] [Survey] direct victim 대기 큐 고정값 4 검증 | CBRD-27211 (기존) | — | 유지. |
| C3 | [PGBUF] [Survey] pgbuf default / v2 병행 버전 도입 | CBRD-27252 (기존) | — | 본문이 placeholder 상태. 재구현 마일스톤(M0 자료구조 ~ M8 ordered fix/checkpoint)과 테스트 전략으로 구체화 예정. |
| C4 | [PGBUF] [Survey] 복구 중 temp 볼륨 판정의 영향을 조사한다 | 신규 필요 | N7 | 복구 중 temp 접근 존재 여부와 non-temp 취급의 안전성 판정. 결론이 "문제 없음"이라도 코드 주석으로 근거를 남기는 것까지가 완료 조건. |
| C5 | [PGBUF] heap/B-tree scan prefetch와 비동기 read 경로 설계 | 선택 (미생성) | — | baseline과 목표 수치가 있는 조사로 시작, 이득 확인 시에만 구현 전환. |
| C6 | [PGBUF] buffer hash 크기를 data_buffer_size에 맞게 산정 | 선택 (미생성) | — | 현재 hash는 pool 크기와 무관하게 `1<<20` bucket으로 약 56 MiB 고정 비용. bucket 산정식 결정. |
| C7 | [PGBUF] dirty page index와 checkpoint 비용 개선 검토 | 선택 (미생성) | — | 복구 LSA 정확성, dirty 전환 비용, checkpoint latency 세 축에서 이득 확인 시에만 구현 전환. |

> **요지**: 신규 필요 9건은 이 표의 포함 결함·비고를 그대로 각 자식 이슈 본문의 골격으로 쓸 수 있다. 착수 우선순위는 A1 → A2 → A3 → A4 → A5 순의 정확성 결함 우선이다.

### 1순위(A1) 오류 흐름

    pgbuf_bcb_flush_with_wal()                                :10673
      └ pgbuf_bcb_mark_is_flushing()                          :10741
           ├ FLUSHING_TO_DISK 설정
           └ DIRTY 해제
           ├ tde_encrypt_data_page() 실패 ──────────────┐     :10755
           └ dwb_set_data_on_next_slot() 실패 ─────────┤     :10767
                                                        ★ 현재: 즉시 return
                                                          누락: dirty/LSA/flag/waiter 복구

정상적인 write 실패 분기(:10848-10863)는 `pgbuf_bcb_mark_was_not_flushed`, `oldest_unflush_lsa` 복원, `pgbuf_wake_flush_waiters` 를 수행한다. 두 early return도 같은 정리 경로를 사용해야 분기별 상태 전이가 달라지지 않는다. 방치된 BCB는 victim 후보 마스크에 걸려 영구 회수 불가가 되고, 그 page에 대한 동기 flush 요청(`PGBUF_LATCH_FLUSH` 대기)은 타임아웃이 없어(:7050) 깨워줄 주체 없는 무한 대기가 된다.

### 2순위(A2) 오류 흐름 — 등록/해제 회계

요청 page 의 보호 카운터는 `pgbuf_fix`(등록 :2425-2428, 해제 :2513-2517)와 `pgbuf_ordered_fix`(해제 :12702, :12850)가 나눠 맡는다. 진입 상황별 순증감:

| 진입 상황 | 등록 | 해제 | 순증감 |
|---|---|---|---|
| 1차 시도(:12291-12296)가 lock-free fast path(:2311-2313)로 성공 | 건너뜀 | :2516 | **-1 결함** (타 스레드 보호 절취) |
| 1차 시도가 일반 경로로 성공 | +1 | :2516 | 0 |
| 1차 시도가 조건부 latch 충돌로 실패 → 재정렬 후 재 fix 성공 | +1 | :12702/:12850 | 0 (의도된 handshake) |
| 1차 시도가 등록 도달 전 실패(read/BCB 오류) 후 재정렬 성공 | 없음 | :12702/:12850 | **-1 결함** (드묾, 0-방어 주석 :16232-16244 의 감수 범위) |
| 재정렬 중 실패 → exit 정리(:12972-12998) | +1 | 없음 | **+1 결함** (page 가 vacuum 회수에서 영구 제외) |

lock-free 행이 가장 위험하다: 스캔의 통상 상태(보유 page 없음)에서 latch 조건이 UNCONDITIONAL(:12280-12284)이 되어 일상적으로 도달하며, 0-방어(:16226-16250)는 자기 마커가 사라진 0 케이스만 방어하고 타 스레드(vacuum 등)가 등록한 카운트는 그대로 감소된다. `OLD_PAGE_PREVENT_DEALLOC` 의 외부 호출부 10곳(`heap_file.c` 9곳과 `locator_sr.c:12788`)은 전부 `pgbuf_ordered_fix` 경유이고 `pgbuf_fix` 직접 호출은 0건이다 (`heap_file.c:17478` 은 WRITE latch 라 fast path 대상 아님). 계측·재현 절차는 CBRD-27263 본문이 정본이다.

### 별도 이슈를 권하지 않는 항목

| 항목 | 처리 권장 |
|---|---|
| AOUT 강제 비활성 D7 | 근본 원인은 기존 CBRD-20741 과 연결돼 있으므로 중복 이슈를 만들지 않는다. 낡은 "LRU + Aout of 2Q" 주석 정리는 B4 범위에서 처리한다. |
| `pgbuf_peek_stats` 헤더 인자명 D8 | 외부 binary interface와 동작에 영향이 없는 stale parameter name이라 단독 JIRA를 만들지 않고 B4에 포함한다. |

## Acceptance Criteria

- [ ] 정확성 A1~A5는 각각 독립 자식 이슈로 만들고(A4는 CBRD-27194 범위 확장) 재현 또는 오류 주입 방법과 기대 상태를 적는다.

- [ ] 운영성 B1~B4는 사용자 동작·호환성 또는 대안 선택을 먼저 확정한 뒤 구현 범위를 정한다.

- [ ] C3(CBRD-27252)는 병행 구현의 마일스톤, 테스트 전략, 기존 코드와의 대조 기준을 본문으로 확정한다.

- [ ] C4~C7 조사 이슈는 baseline과 목표 수치를 명시하고, 이득이 확인된 경우에만 구현 이슈로 전환한다.

## Definition of done

- [ ] 위 Acceptance Criteria를 충족하는 독립 자식 이슈와 담당 범위가 정해진다.

- [ ] 선정된 자식 이슈의 검증 통과 기준과 회귀 성능 측정 항목이 정의된다.

- [ ] 선정된 자식 이슈가 완료되고 EPIC 링크와 상태가 최신으로 유지된다.

- [ ] 통계 또는 설정 변경 시 운영 문서와 매뉴얼이 반영된다.

## Open Questions

### A2의 수정 방식

수정 후보 3안 중 선택은 `TBD - 합의 미확인` 이다: ① 요청 page 보호의 등록·해제를 `pgbuf_ordered_fix` 가 전담하도록 이관(5가지 진입 상황이 한 함수에서 정리됨 — 권장 후보), ② 현행 분담을 유지하되 깨지는 3곳을 개별로 메우고 두 함수 간 계약을 주석으로 명시, ③ fast path 진입 조건(:2311-2313)에서 `OLD_PAGE_PREVENT_DEALLOC` 제외(-1 결함 1행만 해결되므로 단독으로는 불충분). vacuum 의 보호 기간 요구와 겹치는 쪽이 없는지 확인 후 결정한다.

### A3의 목표 동작

direct victim 긴급 배정 순회를 의도대로 복구할지, 현재 동작(미실행)에 맞춰 dead path를 제거할지는 `TBD - 합의 미확인` 이다. 저활동 direct-victim workload에서 대기 시간 분포를 비교해 결정한다.

### big private queue의 목표 상태 (B2)

queue 생산자를 복구할지, 현재 동작에 맞춰 queue와 2단계 탐색을 제거할지는 `TBD - 합의 미확인` 이다. over-quota 경쟁 workload로 두 안의 victim 탐색 비용과 shared LRU 침범량을 비교해야 한다.

### 통계 호환성 (B1)

기존 `SHOW PAGE BUFFER STATUS` 컬럼을 바로 재정의할지, 새 컬럼을 추가하고 기존 컬럼을 단계적으로 폐기할지는 `TBD - 합의 미확인` 이다.

## References

- 이전 분석 (commit `5cd4f860e` 기준):
  - [page buffer 결함 보고서](https://github.com/vimkim/my-cubrid-docs/blob/343ecc9c8e246cb15c19de0cb6c34117950955e6/pgbuf-analysis/pgbuf-defects-report_5cd4f860e_claude.md)
  - [CUBRID 구조·fix/unfix 분석](https://github.com/vimkim/my-cubrid-docs/blob/343ecc9c8e246cb15c19de0cb6c34117950955e6/pgbuf-analysis/research/cubrid-structs-fix.md)
  - [CUBRID LRU·victim 분석](https://github.com/vimkim/my-cubrid-docs/blob/343ecc9c8e246cb15c19de0cb6c34117950955e6/pgbuf-analysis/research/cubrid-lru-victim.md)
  - [CUBRID flush·WAL·DWB 분석](https://github.com/vimkim/my-cubrid-docs/blob/343ecc9c8e246cb15c19de0cb6c34117950955e6/pgbuf-analysis/research/cubrid-flush-wal-dwb.md)
  - [PostgreSQL buffer manager 비교](https://github.com/vimkim/my-cubrid-docs/blob/343ecc9c8e246cb15c19de0cb6c34117950955e6/pgbuf-analysis/research/postgres-bufmgr.md)
  - [InnoDB buffer pool 비교](https://github.com/vimkim/my-cubrid-docs/blob/343ecc9c8e246cb15c19de0cb6c34117950955e6/pgbuf-analysis/research/innodb-bufpool.md)
- 신규 분석 (commit `e6ed61e87` 기준): `page_buffer.c` 전량 정독 분석서 세트(총론 + 자료구조 / fix·unfix / LRU·victim·quota / flush·WAL·데몬 / ordered fix·dealloc / 관측성, 문답집·재구현 계획 포함 10편). my-cubrid-docs 게시 후 링크를 본 이슈에 추가한다.
- 기준 소스: [`page_buffer.c`](https://github.com/CUBRID/cubrid/blob/e6ed61e87d68baf1c38cee83ddd3bb4b2fa71b2e/src/storage/page_buffer.c), [`page_buffer.h`](https://github.com/CUBRID/cubrid/blob/e6ed61e87d68baf1c38cee83ddd3bb4b2fa71b2e/src/storage/page_buffer.h)
