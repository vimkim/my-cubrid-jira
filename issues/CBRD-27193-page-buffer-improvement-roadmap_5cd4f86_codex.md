# [PGBUF] 페이지 버퍼 안정성·동시성·관측성 개선 EPIC

## Issue Triage

**이슈 수행 목적**: 페이지 버퍼의 안정성·운영성·성능 개선을 하나의 EPIC에서 관리하되, 확인된 정확성 결함을 우선 처리하고 구조 변경은 측정 근거가 확보된 경우에만 진행한다.

**이슈 수행 이유**:

| 구분 | 내용 |
|------|------|
| **AS-IS (현재 동작 / 배경)** | CBRD-27193에는 상세 범위와 자식 이슈가 없으며, 분석에서 확인된 정확성 결함·운영 지표 불일치·장기 성능 아이디어의 근거 수준과 우선순위도 구분돼 있지 않다. |
| **TO-BE (목표 상태 / 기대 동작)** | 자식 이슈로 선정한 확정 결함은 Correct Error로 먼저 완료하고, 구조 변경은 적용 지점·정합성·성능 기준을 합의한 조사 또는 설계 이슈를 거쳐 구현 여부를 결정한다. |
| **영향** | 고객 장애 가능성 — 비정상적인 page flush 실패 뒤 메모리 page 상태와 대기 스레드가 복구되지 않는 결함이 미추적 상태라, 같은 frame을 재사용하지 못하거나 수정 내용이 디스크에 반영되지 않을 수 있다. |

**이슈 수행 방안**: CBRD-27193은 page buffer 자식 이슈를 묶어 완료까지 관리하는 EPIC으로 유지한다. 확정 결함, 운영성 개선, 구조 연구의 세 범주로 나누는 방안을 권장하며, 실제 자식 이슈 생성 범위와 순서는 `TBD - 합의 미확인` 으로 둔다.

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### 변경 범위

- **변경 범위 / 영향**: `src/storage/page_buffer.c`, `page_buffer.h`, `src/storage/double_write_buffer.cpp`, `src/base/system_parameter.c`, `src/base/perf_monitor.c`, `src/parser/show_meta.c` 가 후보 범위다. EPIC 자체는 디스크 형식과 외부 공개 interface를 바꾸지 않지만, 통계 이름·정의 변경은 모니터링 호환성을 별도로 검토해야 한다.

---

## Description

기준 소스는 CUBRID commit `5cd4f860ec5dcdae732bd340728c0fe4aa709a4d` 다. `my-cubrid-docs/pgbuf-analysis` 의 CUBRID 구조·fix/unfix, page 교체, flush 팩트시트와 PostgreSQL 20devel, InnoDB 26.7 비교 자료를 함께 검토했다.

`pgbuf` (page buffer manager — 디스크 page를 메모리 frame에 캐시하고 fix, latch, 교체, flush를 관리하는 모듈)는 page lookup과 교체뿐 아니라 WAL(Write-Ahead Logging — data page보다 log를 먼저 기록하는 규칙), DWB(Double Write Buffer — 원래 위치에 쓰기 전 별도 파일에 page 사본을 기록하는 torn-write 보호 장치), TDE(Transparent Data Encryption — data page 암호화)를 연결한다. BCB(Buffer Control Block — frame에 올라온 page의 fix 수, latch, dirty 상태를 보관하는 제어 블록)는 `latch_mode`, `waiter_exists`, `fcnt` 를 하나의 64-bit atomic word에 저장한다. READ fix/unfix의 lock-free 경로와 일반 latch 대기열도 이 word를 함께 사용한다.

LSA(Log Sequence Address — log에서 record의 위치를 나타내는 주소)는 WAL 순서를 판단하는 기준이다.

LRU(Least Recently Used — 최근 사용 시점을 기준으로 page 교체 순서를 관리하는 목록)는 private/shared 영역으로 나뉜다. direct victim은 빈 frame을 찾지 못해 대기하는 스레드에 재사용 가능한 BCB를 직접 넘기는 방식이고, big private victim queue는 큰 private LRU에서 회수할 대상을 관리하는 목록이다.

이 문서의 SX(shared-exclusive)는 여러 READ와 공존하지만 다른 SX 및 WRITE와 충돌하는 page latch 후보를 뜻한다. AIO(Asynchronous I/O)는 요청 스레드가 각 read 완료를 동기적으로 기다리지 않는 입출력 방식이다. 두 용어 모두 확정된 CUBRID 스펙이 아니라 조사할 설계 후보다.

## Specification Changes

EPIC 자체의 실행 스펙 변경은 없다. 각 자식 이슈에서 변경 전후 동작, 호환성, 성능 기준을 확정한다.

## Implementation

### 권장 자식 이슈

```
CBRD-27193 page buffer
├─ 정확성: 상태 누수, 실행 불가 경로, 초기화 오류
├─ 운영성: 통계 의미, 설정 문법, 사문화 경로 정리
└─ 설계/성능: SX latch, scan prefetch/AIO, hash·dirty 추적 구조
```

| 순위 | 권장 유형 | 후보 제목 | 근거와 권장 범위 |
|------|-----------|-----------|------------------|
| 1 | Correct Error | `[PGBUF] flush 준비 후 TDE/DWB 오류 시 BCB 상태를 복구한다` | 확정 결함 D1. 두 early return을 기존 write 실패 정리 경로로 합치고 TDE·DWB 오류를 각각 주입해 상태 복구를 검증한다. |
| 2 | Correct Error | `[PGBUF] direct victim 유지보수 순회가 실행되지 않는 오류를 처리한다` | 확정 결함 D3. private/shared 순회 본문이 한 번도 실행되지 않는다. 의도대로 순회를 복구할지 dead path를 제거할지는 `TBD - 합의 미확인` 이며, 선택한 동작을 저활동 direct-victim workload로 검증한다. |
| 3 | Correct Error | `[PGBUF] direct_victims 초기화 크기를 실제 타입과 일치시킨다` | 확정 결함 D2. 대상 표현식을 기준으로 전체 구조체를 초기화하고 초기화 중간 실패 정리 경로를 검사한다. |
| 4 | Improve Function/Performance | `[PGBUF] page buffer 통계의 논리 페이지와 물리 I/O 의미를 정리한다` | 확정된 의미 불일치 D6을 한 계약 이슈로 묶는다. DWB 사용 시 논리 page flush와 DWB/home 물리 write를 구분하고, `Num_data_page_flushed`, `Victim_candidate_pages`, `NEW_PAGE` hit의 정의를 이름·도움말·집계 지점에 맞춘다. 기존 모니터링 컬럼 호환성은 별도 결정이 필요하다. |
| 5 | Improve Function/Performance | `[PGBUF] big private victim queue의 생산 경로를 복구하거나 제거한다` | 결함 D4의 현상은 확정됐지만 목표 설계는 미확정이다. `big_private_lrus_with_victims` 를 실제로 seed해 over-quota 세션이 큰 private LRU부터 회수하게 할지, 사용되지 않는 2단계를 제거할지 부하 시험으로 선택한다. |
| 6 | Improve Function/Performance | `[PGBUF] double_write_buffer_size에 크기 단위 문법을 지원한다` | 실측 D5. `PRM_INTEGER` 라 `2M` 을 거부하면서 서버 시작까지 실패하지만 `data_buffer_size=16M` 은 허용한다. `0`, byte 정수, `K/M` 입력과 32 MiB 상한의 동작을 다른 size parameter와 맞춘다. |
| 7 | Development Subject | `[PGBUF] SX page latch의 적용 지점과 성능 효과를 검증한다` | 구조 개선 후보. 바로 enum을 추가하지 않고 public fix latch와 내부 writeback 상태 중 어느 경계가 필요한지 먼저 정한다. plain page 경로의 copy 감소 가능성, TDE/DWB 출력 사본의 필요성, writer 대기, I/O 중 frame 안정성을 함께 측정한다. |
| 8 | Development Subject | `[PGBUF] heap/B-tree scan prefetch와 비동기 read 경로를 설계한다` | 비교 분석에서 도출한 성능 후보. 다음 page identifier 기반 prefetch가 operating-system readahead보다 이득인 조건, private quota에 미치는 pollution, parallel scan과의 중복을 먼저 측정한다. 단일 `pgbuf_fix` 의 동기 동작은 유지하고 scan 단위 read stream을 별도 검토한다. |
| 9 | Improve Function/Performance | `[PGBUF] buffer hash 크기를 data_buffer_size에 맞게 산정한다` | 구조 개선 후보. 현재 hash는 pool 크기와 무관하게 `1<<20` bucket과 mutex를 만들며 분석상 약 56 MiB 고정 비용이 든다. 작은 pool의 메모리·초기화 비용과 큰 pool의 chain 길이를 측정해 bucket 산정식을 정한다. |
| 10 | Development Subject | `[PGBUF] dirty page index와 checkpoint 비용 개선 가능성을 검토한다` | 장기 조사 후보. 현재 flush/checkpoint가 LRU 또는 BCB를 스캔하는 구조와 dirty 전용 index를 비교한다. 복구 LSA 정확성, dirty 전환 비용, checkpoint latency의 세 축에서 이득이 확인될 때만 구현 이슈로 전환한다. |

### 1순위 오류 흐름

```
pgbuf_bcb_flush_with_wal()
  └ pgbuf_bcb_mark_is_flushing()
       ├ FLUSHING_TO_DISK 설정
       └ DIRTY 해제
       ├ tde_encrypt_data_page() 실패 ──────────────┐
       └ dwb_set_data_on_next_slot() 실패 ─────────┤
                                                    ★ 현재: 즉시 return
                                                      누락: dirty/LSA/flag/waiter 복구
```

정상적인 write 실패 분기는 `pgbuf_bcb_mark_was_not_flushed`, `oldest_unflush_lsa` 복원, `pgbuf_wake_flush_waiters` 를 수행한다. 두 early return도 같은 정리 경로를 사용해야 분기별 상태 전이가 달라지지 않는다.

### SX latch 후보의 경계

여기서 권장 용어는 `SX` (shared-exclusive — 여러 READ와 공존하지만 SX끼리 및 WRITE와 충돌하는 page latch)다. `SIX` 는 보통 다중 단위 lock 계층의 shared-with-intention-exclusive를 뜻하므로, CUBRID page latch에 그대로 쓰면 transaction lock과 혼동하기 쉽다.

첫 결정은 SX를 `pgbuf_fix` 호출자가 요청하는 public content latch로 추가할지, flush/writeback 내부에서만 사용하는 배타 상태로 둘지다. public latch라면 모든 fix·unfix 및 대기 경로의 계약이 바뀌고, 내부 상태라면 실제 writeback 호출자와 보호 대상에 맞춘 더 좁은 변경이 가능하다.

권장 compatibility matrix는 서로 다른 holder 사이의 설계 검증 출발점일 뿐 확정 스펙은 아니다. 같은 holder의 재귀 획득과 READ→SX→WRITE promotion은 별도 정책으로 정해야 한다.

| 보유 mode / 요청 mode | READ | SX | WRITE |
|------------------------|------|----|-------|
| READ | 허용 | 허용 | 대기 |
| SX | 허용 | 대기 | 대기 |
| WRITE | 대기 | 대기 | 대기 |

현재 `PGBUF_LATCH_FLUSH` 는 page를 fix할 때 얻는 content latch가 아니라 flush 완료를 기다리는 queue mode다. 새 SX는 이를 이름만 바꾸는 작업이 아니다. public latch로 선택할 경우 최소한 다음 경로가 함께 바뀐다.

```
PGBUF_LATCH_MODE
  ├ pgbuf_fix 입력 검증
  ├ pgbuf_latch_bcb_upon_fix 호환성·재귀·promotion
  ├ pgbuf_block_bcb 대기열 등록
  ├ pgbuf_wakeup_reader_writer 묶음 wakeup
  ├ lock-free READ fix/unfix 허용 조건
  └ holder/perfmon latch mode 집계
```

현재 BCB의 64-bit atomic word는 aggregate `latch_mode`, `waiter_exists`, `fcnt` 만 보관하고 holder에는 획득 mode가 남지 않는다. READ와 SX가 공존하면 unfix 시 해제되는 holder의 mode, 남은 READ/SX 수, 마지막 SX 해제 뒤 READ로의 downgrade를 식별할 수 있어야 한다. 설계 이슈에서 다음 상태·소유권 규칙을 먼저 확정한다.

1. SX를 public fix latch로 노출할지 writeback 내부 상태로 제한할지
2. SX owner와 READ/SX별 획득 수를 어느 구조에 기록할지
3. unfix, downgrade, recursion, READ→SX→WRITE promotion을 어떻게 처리할지
4. page holder가 아닌 flusher가 SX를 소유할 수 있는지와 wakeup 순서를 어떻게 정의할지

`pgbuf_bcb_flush_with_wal` 은 현재 16 KiB page의 snapshot을 만든 뒤 BCB mutex를 풀고 WAL flush와 data write를 진행한다. 암호화하지 않는 plain page는 `memcpy` 로 snapshot을 만들지만, TDE 경로에는 암호화 출력 buffer가 필요하고 DWB도 별도 slot에 write image를 보관한다. 따라서 SX가 plain page의 frame 직접 쓰기를 가능하게 하더라도 모든 copy를 제거할 수 있다고 전제하면 안 된다. 또한 느린 I/O 동안 WRITE를 막는 비용이 생긴다. 다음 검증이 없는 "SX mode 추가"는 완료로 보지 않는다.

1. 실제 CUBRID 호출자와 보호할 data 및 public/internal 경계
2. 기존 snapshot-copy 대비 정합성 증명과 TDE/DWB별 data flow
3. read-heavy, write-heavy, flush-pressure workload의 성능 비교

### 별도 이슈를 권하지 않는 항목

AOUT는 2Q 교체 정책에서 main queue에서 밀려난 page identifier의 이력을 보관하는 queue다.

| 항목 | 처리 권장 |
|------|-----------|
| AOUT 강제 비활성 D7 | 근본 원인은 기존 `CBRD-20741` 과 연결돼 있으므로 중복 이슈를 만들지 않는다. 설정을 0으로 덮어쓸 때 경고할지와 오래된 "LRU + Aout of 2Q" 주석을 고칠지는 해당 이슈 또는 문서 정리 범위에서 결정한다. |
| `pgbuf_peek_stats` 헤더 인자명 D8 | 외부 binary interface와 동작에는 영향이 없는 stale parameter name이다. 인접한 page-buffer cleanup 변경에 포함하고 단독 JIRA는 만들지 않는다. |

## Acceptance Criteria

- [ ] 우선순위 협의에서 선정된 순위 1~3의 결함은 각각 독립 자식 이슈로 만들고 재현 또는 오류 주입 방법과 기대 상태를 적는다. 순위 2를 선정하면 순회 복구와 dead path 제거 중 선택한 목표 동작을 명시한다.
- [ ] 순위 4~6은 사용자 동작·호환성 또는 대안 선택을 먼저 확정한 뒤 구현 범위를 정한다.
- [ ] SX latch 자식 이슈는 public latch와 내부 상태 중 경계, owner와 mode별 count, release/downgrade, compatibility matrix, 실제 호출자, promotion/wakeup 정책, 성능 기준을 명시한다.
- [ ] prefetch, hash sizing, dirty index 후보는 baseline과 목표 수치가 있는 조사 이슈로 시작하며, 이득이 확인된 경우에만 구현 이슈로 전환한다.
- [ ] AOUT 항목은 `CBRD-20741` 의 범위와 상태를 확인해 중복 티켓을 만들지 않는다.

## Definition of done

- [ ] 위 Acceptance Criteria를 충족하는 독립 자식 이슈와 담당 범위가 정해진다.
- [ ] 선정된 자식 이슈의 검증 통과 기준과 회귀 성능 측정 항목이 정의된다.
- [ ] 선정된 자식 이슈가 완료되고 EPIC 링크와 상태가 최신으로 유지된다.
- [ ] 통계 또는 설정 변경 시 운영 문서와 매뉴얼이 반영된다.

## Open Questions

### latch mode 명칭과 최초 적용 대상

page latch 명칭을 `SX` 로 정할지 `SIX` semantics가 실제로 필요한지, 그리고 flush write path를 최초 대상으로 삼을지는 `TBD - 합의 미확인` 이다. 다중 단위 intent semantics가 없다면 `SX` 를 권장한다.

### big private queue의 목표 상태

queue 생산자를 복구할지, 현재 동작에 맞춰 queue와 2단계 탐색을 제거할지는 `TBD - 합의 미확인` 이다. over-quota 경쟁 workload로 두 안의 victim 탐색 비용과 shared LRU 침범량을 비교해야 한다.

### 통계 호환성

기존 `SHOW PAGE BUFFER STATUS` 컬럼을 바로 재정의할지, 새 컬럼을 추가하고 기존 컬럼을 단계적으로 폐기할지는 `TBD - 합의 미확인` 이다.

## References

- [page buffer 결함 보고서](https://github.com/vimkim/my-cubrid-docs/blob/343ecc9c8e246cb15c19de0cb6c34117950955e6/pgbuf-analysis/pgbuf-defects-report_5cd4f860e_claude.md)
- [CUBRID 구조·fix/unfix 분석](https://github.com/vimkim/my-cubrid-docs/blob/343ecc9c8e246cb15c19de0cb6c34117950955e6/pgbuf-analysis/research/cubrid-structs-fix.md)
- [CUBRID LRU·victim 분석](https://github.com/vimkim/my-cubrid-docs/blob/343ecc9c8e246cb15c19de0cb6c34117950955e6/pgbuf-analysis/research/cubrid-lru-victim.md)
- [CUBRID flush·WAL·DWB 분석](https://github.com/vimkim/my-cubrid-docs/blob/343ecc9c8e246cb15c19de0cb6c34117950955e6/pgbuf-analysis/research/cubrid-flush-wal-dwb.md)
- [PostgreSQL buffer manager 비교](https://github.com/vimkim/my-cubrid-docs/blob/343ecc9c8e246cb15c19de0cb6c34117950955e6/pgbuf-analysis/research/postgres-bufmgr.md)
- [InnoDB buffer pool 비교](https://github.com/vimkim/my-cubrid-docs/blob/343ecc9c8e246cb15c19de0cb6c34117950955e6/pgbuf-analysis/research/innodb-bufpool.md)
- 기준 소스: [`page_buffer.c`](https://github.com/CUBRID/cubrid/blob/5cd4f860ec5dcdae732bd340728c0fe4aa709a4d/src/storage/page_buffer.c), [`page_buffer.h`](https://github.com/CUBRID/cubrid/blob/5cd4f860ec5dcdae732bd340728c0fe4aa709a4d/src/storage/page_buffer.h)
