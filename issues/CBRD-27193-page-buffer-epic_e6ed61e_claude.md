# [PGBUF] 페이지 버퍼 안정성·동시성·관측성 개선 EPIC

## Issue Triage

**이슈 수행 목적**: 페이지 버퍼의 안정성·운영성·성능 개선을 하나의 EPIC에서 관리하되, 확인된 정확성 결함을 우선 처리하고 구조 변경은 측정 근거가 확보된 경우에만 진행한다.

**이슈 수행 이유**:

  구분                                내용
  ----------------------------------- ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
  **AS-IS (현재 동작 / 배경)**        기존 본문은 commit `5cd4f860e` 분석의 결함 D1~D8만 반영하고 있었다. 이후 develop `e6ed61e87` 기준으로 `page_buffer.c` 전량(17,535줄)을 재분석한 결과 D1~D3가 그대로 잔존함을 재확인했고, 신규 결함 9건(N1~N9)을 추가로 확인했다. 자식 이슈는 4건뿐이며 그중 정확성 결함용은 CBRD-27194(D2) 하나로, 본문이 스크린샷 스텁 상태다.
  **TO-BE (목표 상태 / 기대 동작)**   재검증·신규 결함이 EPIC 본문에 통합되고, 자식 이슈 구성이 확정된다 — 기존 4건 재사용(CBRD-27194 범위 확장, CBRD-27252 본문 구체화 포함) + 신규 필수 9건 + 선택(장기 조사) 3건. 확정 결함은 Correct Error로 먼저 완료한다.
  **영향**                            고객 장애 가능성 — 신규 확인된 N1(dealloc 보호 카운터 조기 해제)은 vacuum이 보호 중인 페이지가 회수될 수 있는 정합성 결함이고, 기존 D1(flush 실패 후 BCB 미복구)은 대기 스레드가 깨어나지 못하는 hang으로 이어질 수 있는데, 두 결함 모두 이슈 미추적 상태다.

**이슈 수행 방안**: CBRD-27193은 page buffer 자식 이슈를 정확성·운영성·조사/설계 3범주로 묶어 완료까지 관리하는 EPIC으로 유지한다. 자식 이슈 구성은 아래 Implementation의 확정 표를 따른다. AOUT 강제 비활성(D7)은 기존 CBRD-20741과 연결되므로 중복 이슈를 만들지 않는다.

------------------------------------------------------------------------

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: `src/storage/page_buffer.c`, `page_buffer.h`, `src/storage/double_write_buffer.cpp`, `src/base/system_parameter.c`, `src/base/perf_monitor.c`, `src/parser/show_meta.c` 가 후보 범위다. EPIC 자체는 디스크 형식과 외부 공개 interface를 바꾸지 않지만, 통계 이름·정의 변경(B1)은 모니터링 호환성을 별도로 검토해야 한다. 아래 라인 번호는 별도 표기가 없으면 develop `e6ed61e87` 의 `page_buffer.c` 기준이다.

------------------------------------------------------------------------

## Description

기준 소스는 CUBRID develop commit `e6ed61e87` 이다. 이전 분석(commit `5cd4f860e`, References 참조)의 결함 D1~D8을 재검증하고, 이번에는 `page_buffer.c` 를 자료구조·fix/unfix·LRU/victim·flush/WAL·ordered fix·부가기능의 6개 축으로 전량 정독해 신규 결함 N1~N9를 추가로 확인했다.

`pgbuf` (page buffer manager — 디스크 page를 메모리 frame에 캐시하고 fix, latch, 교체, flush를 관리하는 모듈)는 page lookup과 교체뿐 아니라 WAL(Write-Ahead Logging — data page보다 log를 먼저 기록하는 규칙), DWB(Double Write Buffer — 원래 위치에 쓰기 전 별도 파일에 page 사본을 기록하는 torn-write 보호 장치), TDE(Transparent Data Encryption — data page 암호화)를 연결한다. BCB(Buffer Control Block — frame에 올라온 page의 fix 수, latch, dirty 상태를 보관하는 제어 블록)는 `latch_mode`, `waiter_exists`, `fcnt` 를 하나의 64-bit atomic word에 저장하며, READ fix/unfix의 lock-free 경로와 일반 latch 대기열이 이 word를 함께 사용한다. LRU(Least Recently Used — 최근 사용 시점 기준의 page 교체 목록)는 shared/private 영역으로 나뉘고, direct victim은 빈 frame을 찾지 못해 대기하는 스레드에 재사용 가능한 BCB를 직접 넘기는 방식이다.

### 신규 확인 결함 (N1~N9, e6ed61e87 기준)

  ID   위치 (page_buffer.c)              내용                                                                                                                                                                                                       분류
  ---- --------------------------------- ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- ------------------------
  N1   :2311-2330, :2513-2517            lock-free fix 빠른 경로의 진입 조건에 `OLD_PAGE_PREVENT_DEALLOC` 이 포함되는데, 성공 시 dealloc 보호 카운터 등록(:2425-2428)을 건너뛰고 해제(:2513-2517)만 실행한다. 같은 비대칭이 ordered fix의 `has_dealloc_prevent_flag` 경로(:12699-12704, :12847-12852)에도 있다. 다른 스레드(vacuum 등)가 등록한 보호를 훔쳐 감소시킬 수 있다.   정합성 (High)
  N2   :8456-8461                        `pgbuf_claim_bcb_for_fix` 의 `dwb_read_page` 실패 경로가 인접 실패 경로와 달리 BCB mutex를 든 채 반환한다. release 빌드에서 해당 BCB 영구 잠금 + 같은 VPID 대기자의 무한 대기로 이어진다.                                                            가용성 (방어 경로)
  N3   :9407 → :9497, :9577, :9586      direct victim 긴급 배정 경로 2곳이 실행되지 않는다. `pgbuf_panic_assign_direct_victims_from_lru` 는 호출부가 직전에 NULL이 된 `prev_BCB` 를 전달해 항상 0을 반환하고, `pgbuf_direct_victims_maintenance` 의 두 순회는 초기 조건 모순으로 본문이 한 번도 돌지 않는다 (D3와 동일 계열).   기존 D3의 범위 확장
  N4   :11349, :11362-11363              `pgbuf_dump` 가 atomic latch/flags 개편 이전 필드(`bufptr->fcnt`, `bufptr->zone`)를 참조해 `CUBRID_DEBUG` 정의 시 컴파일이 실패한다. finalize 진단 경로가 사장된 상태다.                                                                          진단 도구
  N5   :15255, :15271                    `pgbuf_rv_dealloc_undo_compensate` 가 대입된 적 없는 지역 `VPID vpid` 를 debug TDE 로그로 출력한다 (`pgbuf_rv_dealloc_undo` :15209-15210에서 복사된 코드로 보이며 초기화 누락).                                                                     debug 한정
  N6   :5851 + :1980, :13949             `Aout_mutex` 가 초기화 실패 경로와 finalize에서 이중 `pthread_mutex_destroy` 되고(미정의 동작), quota 비활성 시 `malloc (0)` 반환값에 의존한다. D2(memset 크기 오류, :1626)와 같은 초기화/종료 위생 계열이다.                                              D2의 범위 확장
  N7   :5497-5501                        `pgbuf_is_temporary_volume` 이 `LOG_ISRESTARTED ()` 이전(복구 수행 중)에는 항상 false를 반환해, 복구 중 temp page가 WAL 면제·LRU 승격 억제·DWB 우회 등 temp 특수 처리를 전혀 받지 못한다. 의도된 보수 동작인지 판정이 필요하다.                                조사
  N8   :10828, :10833                    `Num_pages_written` 과 `PSTAT_PB_NUM_IOWRITES` 증가가 non-DWB 분기에만 있어, DWB(기본 활성) 경유 쓰기가 집계되지 않는다. `SHOW PAGE BUFFER STATUS` 의 write 지표가 사실상 0으로 보인다 (D6 통계 의미 정리와 같은 계열).                                     D6의 범위 확장
  N9   :14446, :10585, :300, :771-774, :10772   죽은 코드·낡은 주석 — `monitor.victim_rich` 는 계산되지만 소비처가 없고(:9046-9053 주석은 이를 재시도 조건으로 설명해 코드와 불일치), `pgbuf_remove_private_from_aout_list` 는 호출부가 없으며, `UINT16MAX` 매크로 미사용, "garbage LRU" 구획 주석은 현재 코드에 없는 설명, `goto copy_unflushed_lsa` 는 레이블이 바로 다음 줄이라 무의미하다.   정리

> **요지**: 이전 분석의 상위 결함(D1~D3)은 develop 최신에서도 그대로 살아 있고, 이번 재분석은 그보다 심각도가 같거나 높은 정합성 결함(N1)과 가용성 결함(N2)을 새로 찾았다. 정확성 결함 5건(D1+N2, N1, D3+N3, D2+N6, N4+N5)을 자식 이슈로 먼저 처리한다.

## Specification Changes

EPIC 자체의 실행 스펙 변경은 없다. 각 자식 이슈에서 변경 전후 동작, 호환성, 성능 기준을 확정한다.

## Implementation

### 자식 이슈 구성 (확정안)

    CBRD-27193 page buffer EPIC
    ├─ A. 정확성 (Correct Error) ── 5건: 기존 1건 확장 + 신규 4건
    ├─ B. 운영성 (Improve) ──────── 4건: 전부 신규
    └─ C. 조사/설계 (Survey) ────── 기존 3건 + 신규 1건 + 선택 3건

  ID   제목 (안)                                                            이슈 번호            포함 결함            비고
  ---- -------------------------------------------------------------------- -------------------- -------------------- ------------------------------------------------------------------------------------------------
  A1   `[PGBUF] flush 준비 후 TDE/DWB 오류 시 BCB 상태를 복구한다`          **신규 필요**        D1 + N2              두 early return을 기존 write 실패 정리 경로(`pgbuf_bcb_mark_was_not_flushed` + LSA 복원 + waiter 기상)로 합치고, `dwb_read_page` 실패 시 mutex 해제·정리를 추가한다. TDE·DWB 오류 주입으로 검증.
  A2   `[PGBUF] lock-free fix 경로의 dealloc 보호 카운터 비대칭을 수정한다`   **신규 필요**        N1                   빠른 경로 진입 조건에서 `OLD_PAGE_PREVENT_DEALLOC` 제외 또는 등록/해제 대칭 복원 중 택일. heap scan + vacuum 동시 수행 시나리오로 검증.
  A3   `[PGBUF] direct victim 긴급 배정 경로가 실행되지 않는 오류를 처리한다`   **신규 필요**        D3 + N3              순회 복구와 dead path 제거 중 목표 동작 선택은 `TBD - 합의 미확인`. 저활동 direct-victim workload로 검증.
  A4   `[PGBUF] 초기화/종료 경로의 위생 결함을 일괄 수정한다`               **CBRD-27194 확장**   D2 + N6              memset 대상 타입 크기 일치, mutex destroy 소유권을 finalize로 단일화, 개수 0이면 할당 생략. 초기화 중간 실패 경로 검사 포함.
  A5   `[PGBUF] debug 빌드 전용 결함 2건을 수정한다`                        **신규 필요**        N4 + N5              `pgbuf_dump` 를 현행 접근자(`get_fcnt`, `pgbuf_bcb_get_zone`)로 재작성, 미초기화 VPID는 `rcv->pgptr` 에서 채운다. `-DCUBRID_DEBUG` 빌드 통과로 검증. 영역이 달라 분리 요구 시 2건으로 나눈다.
  B1   `[PGBUF] page buffer 통계의 논리 페이지와 물리 I/O 의미를 정리한다`   **신규 필요**        D6 + N8              DWB 사용 시 논리 page flush와 물리 write를 구분하고 `Num_pages_written` 미집계를 수정. 기존 모니터링 컬럼 호환성은 별도 결정.
  B2   `[PGBUF] big private victim queue의 생산 경로를 복구하거나 제거한다`   **신규 필요**        D4                   `big_private_lrus_with_victims` 를 실제로 seed할지 미사용 2단계를 제거할지 부하 시험으로 선택.
  B3   `[PGBUF] double_write_buffer_size에 크기 단위 문법을 지원한다`        **신규 필요**        D5                   `PRM_INTEGER` 라 `2M` 입력을 거부하며 서버 시작까지 실패. `0`, byte 정수, `K/M` 입력과 32 MiB 상한을 다른 size parameter와 정합.
  B4   `[PGBUF] 죽은 코드와 낡은 주석을 정리한다`                           **신규 필요**        N9 + D8              동작 무변경 정리라 A/B 결함 수정과 분리해 revert 단위를 깨끗하게 유지한다. D8(`pgbuf_peek_stats` 헤더 인자명)을 여기에 흡수한다.
  C1   `[PGBUF] [Survey] SX page latch 도입 조사`                            **CBRD-27196 (기존)** —                    설계 논점은 해당 이슈 본문에 이관 완료.
  C2   `[PGBUF] [Survey] direct victim 대기 큐 고정값 4 검증`                **CBRD-27211 (기존)** —                    유지.
  C3   `[PGBUF] [Survey] pgbuf default / v2 병행 버전 도입`                  **CBRD-27252 (기존)** —                    본문이 placeholder 상태. 재구현 마일스톤(M0 자료구조 ~ M8 ordered fix/checkpoint)과 테스트 전략으로 구체화 예정.
  C4   `[PGBUF] [Survey] 복구 중 temp 볼륨 판정의 영향을 조사한다`           **신규 필요**        N7                   복구 중 temp 접근 존재 여부와 non-temp 취급의 안전성 판정. 결론이 "문제 없음"이라도 코드 주석으로 근거를 남기는 것까지가 완료 조건.
  C5   `[PGBUF] heap/B-tree scan prefetch와 비동기 read 경로 설계`           선택 (미생성)        —                    baseline과 목표 수치가 있는 조사로 시작, 이득 확인 시에만 구현 전환.
  C6   `[PGBUF] buffer hash 크기를 data_buffer_size에 맞게 산정`             선택 (미생성)        —                    현재 hash는 pool 크기와 무관하게 `1<<20` bucket으로 약 56 MiB 고정 비용. bucket 산정식 결정.
  C7   `[PGBUF] dirty page index와 checkpoint 비용 개선 검토`                선택 (미생성)        —                    복구 LSA 정확성, dirty 전환 비용, checkpoint latency 세 축에서 이득 확인 시에만 구현 전환.

> **요지**: 신규 생성이 필요한 자식 이슈는 필수 9건(A1, A2, A3, A5, B1, B2, B3, B4, C4)이고, 기존 4건(CBRD-27194 범위 확장, CBRD-27196, CBRD-27211, CBRD-27252 본문 구체화)을 재사용한다. 장기 조사 3건(C5~C7)은 선택이다. 착수 우선순위는 A1 → A2 → A3 → A4 → A5 순의 정확성 결함 우선.

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

### 2순위(A2) 오류 흐름

    pgbuf_fix (OLD_PAGE_PREVENT_DEALLOC, READ, UNCONDITIONAL)
      ├ 빠른 경로: pgbuf_lockfree_fix_ro() 성공               :2311-2330
      │    ★ 등록 지점(:2425-2428)을 goto fast_path 로 건너뜀
      │      → avoid-dealloc 카운터 등록 없음
      └ fast_path 합류 후: 해제 지점은 무조건 실행            :2513-2517
           → 카운터가 0이면 0-방어(:16241-16251)로 무해하나,
             다른 스레드가 등록한 보호 카운트가 있으면 그것을 감소

`OLD_PAGE_PREVENT_DEALLOC` + READ + UNCONDITIONAL 조합은 `heap_file.c` 의 상시 heap scan 경로(7572, 7726, 9375, 14366, 14780, 18923, 19022)에서 쓰이므로 노출 빈도가 높다.

### 별도 이슈를 권하지 않는 항목

AOUT는 2Q 교체 정책에서 main queue에서 밀려난 page identifier의 이력을 보관하는 queue다.

  항목                  처리 권장
  --------------------- -------------------------------------------------------------------------------------------------------------------------
  AOUT 강제 비활성 D7   근본 원인은 기존 `CBRD-20741` 과 연결돼 있으므로 중복 이슈를 만들지 않는다. 낡은 "LRU + Aout of 2Q" 주석 정리는 B4 범위에서 처리한다.
  `pgbuf_peek_stats` 헤더 인자명 D8   외부 binary interface와 동작에 영향이 없는 stale parameter name이라 단독 JIRA를 만들지 않고 B4에 포함한다.

## Acceptance Criteria

- [ ] 정확성 A1~A5는 각각 독립 자식 이슈로 만들고(A4는 CBRD-27194 범위 확장) 재현 또는 오류 주입 방법과 기대 상태를 적는다. A3는 순회 복구와 dead path 제거 중 선택한 목표 동작을 명시한다.

- [ ] 운영성 B1~B4는 사용자 동작·호환성 또는 대안 선택을 먼저 확정한 뒤 구현 범위를 정한다. 특히 B1은 기존 `SHOW PAGE BUFFER STATUS` 컬럼 호환성 결정을 포함한다.

- [ ] C3(CBRD-27252)는 병행 구현의 마일스톤, 테스트 전략, 기존 코드와의 대조 기준을 본문으로 확정한다.

- [ ] C4~C7 조사 이슈는 baseline과 목표 수치를 명시하고, 이득이 확인된 경우에만 구현 이슈로 전환한다.

- [ ] AOUT 항목은 `CBRD-20741` 의 범위와 상태를 확인해 중복 티켓을 만들지 않는다.

## Definition of done

- [ ] 위 Acceptance Criteria를 충족하는 독립 자식 이슈와 담당 범위가 정해진다.

- [ ] 선정된 자식 이슈의 검증 통과 기준과 회귀 성능 측정 항목이 정의된다.

- [ ] 선정된 자식 이슈가 완료되고 EPIC 링크와 상태가 최신으로 유지된다.

- [ ] 통계 또는 설정 변경 시 운영 문서와 매뉴얼이 반영된다.

## Open Questions

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
