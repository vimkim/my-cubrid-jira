# [PGBUF] SX page latch 도입 조사

## Issue Triage

**이슈 수행 목적**: SX(shared-exclusive) page latch를 page buffer에 도입할지 판정할 근거 — 적용 경계, 기대 이득, 비용, 성능 기준 — 를 확보한다. 이 이슈는 조사이며 코드 변경은 후속 구현 이슈로 분리한다.

**이슈 수행 이유**:

| 구분 | 내용 |
|---|---|
| **AS-IS (현재 동작 / 배경)** | page latch가 READ/WRITE 2단계뿐이라, READ→WRITE 승격(`pgbuf_promote_read_latch`)은 교착을 피하려고 경쟁 시 `ER_PAGE_LATCH_PROMOTE_FAIL` 로 실패하는 best-effort 방식이고, flush는 I/O 동안 frame을 고정할 중간 mode가 없어 매번 `IO_PAGESIZE`(기본 16KiB) 사본을 떠서 쓴다. |
| **TO-BE (목표 상태 / 기대 동작)** | InnoDB(SX latch), PostgreSQL 20devel(SHARE_EXCLUSIVE), SQL Server(UP latch)가 채택한 SX 등가 mode의 두 이득 — 실패 없는 확정적 승격, 무복사 flush — 이 CUBRID에서도 성립하는지 측정으로 판정하고, 적용 경계(public fix latch vs flush 내부 상태)를 확정한다. |
| **영향** | 성능 저하 — 승격이 실패할 때마다 B-tree insert가 WRITE 하강으로 루트부터 재시작해 해당 index의 read 동시성이 꺾이고(`Data_page_total_promote_fail` 로 관측 가능), 모든 data page flush가 페이지당 16KiB memcpy CPU 비용을 낸다. |

**이슈 수행 방안**: 부모 EPIC CBRD-27193이 요구한 검증 항목 — 적용 경계, owner와 mode별 count 기록 구조, release/downgrade/promotion/wakeup 정책, 실제 호출자, read-heavy·write-heavy·flush-pressure 성능 기준 — 을 이 조사에서 채운다. EPIC 코멘트에 따라 TPC-H(CBRD-27188, CBRD-27191) 성능도 측정 계획에 포함한다. 구현 착수 여부와 최초 적용 대상은 `TBD - 합의 미확인`.

---

## AI-Generated Context

> 아래는 AI가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage에는 위 Issue Triage 블록만으로 충분하며, 본문은 조사/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: 조사 이슈라 이 단계의 코드 변경은 없다. 조사 대상은 `src/storage/page_buffer.c`/`.h`(latch 상태어, 대기열, flush 경로), 승격 호출자 `src/storage/btree.c` 와 `src/storage/file_manager.c`, 통계 `src/base/perf_monitor.c` 다. 후속 구현이 public latch 안으로 가면 `pgbuf_fix` 계약과 perfmon latch 집계가 함께 바뀌므로, 디스크 형식은 불변이어도 모니터링 호환성 검토가 따라온다. 기준 소스는 commit `5cd4f860e` 다.

## Description

latch는 메모리 frame에 올라온 page의 물리적 일관성을 지키는 짧은 잠금으로, 트랜잭션이 끝날 때까지 유지되는 lock과 다르다. CUBRID의 page latch mode는 `PGBUF_LATCH_READ` 와 `PGBUF_LATCH_WRITE` 둘뿐이다 (`page_buffer.h:190-197`; `PGBUF_LATCH_FLUSH` 는 flush 완료를 기다리는 pseudo block mode라 fix에 쓸 수 없다). 이 2단계 체계는 두 가지 흔한 접근 패턴과 맞지 않는다.

첫째, "오래 읽고 판단한 뒤 잠깐 고치는" 패턴이다. B-tree insert는 non-leaf를 READ로 하강하다가 split이 필요해지는 순간에만 WRITE가 필요하다. READ를 쥔 채 WRITE를 기다리면 고전적인 upgrade deadlock이 생긴다:

```
스레드 A: READ 보유 ── WRITE 승격 대기 ──┐ B의 READ 해제를 기다림
스레드 B: READ 보유 ── WRITE 승격 대기 ──┘ A의 READ 해제를 기다림
★ 둘 다 READ를 쥔 채 상대의 해제를 기다리므로 교착
```

그래서 현재의 `pgbuf_promote_read_latch` 는 교착을 "대기"가 아니라 "포기"로 회피한다:

```
pgbuf_promote_read_latch()                          page_buffer.c:2842
  ├ 단독 reader ──────────────── 제자리 승격 (:2929)
  ├ 첫 대기자가 다른 promoter ── 즉시 실패 (:2916)
  │   ★ promoter끼리 경쟁 = 교착 후보라 한쪽이 포기
  ├ ONLY_READER 조건 + 다른 reader 존재 ── 즉시 실패 (:2936)
  └ SHARED_READER 조건 ───────── 자기 fix를 전부 빼고(사실상 unfix)
                                  WRITE 첫 대기자로 재등록 (:2976)
      ★ 대기 중 page 내용이 바뀔 수 있어 승격 후 재검증 필요
```

실패하면 호출자가 뒷감당한다. B-tree insert는 `ER_PAGE_LATCH_PROMOTE_FAIL` 을 받으면 page를 unfix하고 `nonleaf_latch_mode` 를 `PGBUF_LATCH_WRITE` 로 바꿔 루트부터 재시작하며 (`btree.c:28645-28654`), 재시작 후에는 하강 경로 전체를 WRITE로 잡아 그 서브트리의 reader를 전부 막는다.

둘째, "수정하지 않지만 안정된 이미지가 필요한" 패턴이다. flush는 page를 고치지 않지만, 디스크에 쓰는 동안 frame이 변하지 않아야 한다. WRITE로 막자니 I/O 내내 reader까지 서고, 그래서 현재는 사본을 뜬다 — 이 비용이 매 flush마다 든다 (상세 흐름은 검토 항목 2).

SX는 이 두 패턴을 위한 중간 mode다. 여러 READ와 공존하지만 다른 SX 및 WRITE와는 배타인 latch로, EPIC이 권장한 호환성 행렬의 출발점은 다음과 같다:

| 보유 \ 요청 | READ | SX | WRITE |
|---|---|---|---|
| READ | 허용 | 허용 | 대기 |
| SX | 허용 | 대기 | 대기 |
| WRITE | 대기 | 대기 | 대기 |

여기서 "SX→WRITE 승격도 결국 새 READ를 막는 것 아닌가, 그러면 READ→WRITE 승격과 뭐가 다른가"라는 반론이 자연히 나온다. 최종 수정 순간에 배타가 필요한 것은 어떤 설계든 같고, 승격 대기가 시작되면 신규 READ 유입을 조절해야 하는 것도 같다. 차이는 세 가지다.

1. **교착 가능성**: SX는 SX끼리 배타이므로 페이지당 승격 후보가 최대 1명으로 직렬화된다. 남은 holder는 전부 순수 READ이고, READ는 SX를 먼저 얻지 않고는 승격할 수 없으므로, SX holder가 기다리는 대상(기존 READ들)이 거꾸로 SX holder를 기다리는 사이클이 생기지 않는다. SX→WRITE는 "기다리면 반드시 얻는" 승격이고, READ→WRITE는 "교착일 수 있어 포기해야 하는" 승격이다. 위 promotion 흐름의 실패 분기 두 개가 구조적으로 사라진다.
2. **배타 창의 길이**: 읽기·판단 구간을 SX로 지나가는 동안 reader는 계속 통과하고, 배타는 실제 frame 수정 순간으로 줄어든다. 현재는 승격 실패가 두려운 호출자가 처음부터 WRITE 하강을 택해 배타 창이 작업 전체로 늘어난다.
3. **승격이 필요 없는 사용처**: flush는 page를 수정하지 않으므로 SX만 쥔 채 write I/O를 끝내면 되고, WRITE로 올라갈 일 자체가 없다. InnoDB가 정확히 이 방식이다.

이 조사는 위 이득이 CUBRID의 실제 workload에서 비용(홀더 추적 구조, I/O 동안 writer 대기)을 넘어서는지 판정한다.

## 주요 검토 항목

### 1. 타 DBMS의 SX 등가 mode와 성능 이점

| 엔진 | mode | 호환성 | 주요 사용처 |
|---|---|---|---|
| MySQL InnoDB (5.7+) | `RW_SX_LATCH` | S와 호환, SX·X와 배타 | page flush write I/O, B-tree SMO의 `index->lock` |
| PostgreSQL 20devel (미출시 master) | `BUFFER_LOCK_SHARE_EXCLUSIVE` | SHARE와 호환, 자기·EXCLUSIVE와 배타 | buffer flush, hint bit 설정 |
| SQL Server | `UP` (buffer latch) | SH·KP와 호환, UP·EX·DT와 배타 | page를 disk에 쓰는 I/O, 할당 page 갱신 |

**InnoDB** — MySQL 5.7이 WL#6363으로 rw_lock에 SX mode를 추가했고, 두 곳에 적용했다. (1) buffer page flush: `buf_flush_page()` 가 write I/O 동안 `block->lock` 을 SX로 쥐고(`buf0flu.cc:1096-1147`), I/O 완료 시 해제한다(`buf0buf.cc:5971-5973`). frame이 I/O 내내 안정되므로 사본 없이 frame에서 직접 쓰고, reader는 그동안 계속 읽는다. flush-list flush는 SX nowait 실패 시 doublewrite buffer를 강제 flush해 latch holder를 풀어준 뒤 blocking SX로 재시도하고, LRU flush는 그냥 그 page를 포기한다 — SX 획득 실패를 workload별로 다르게 흡수하는 좋은 참고 사례다. (2) B-tree SMO(structure modification operation — split/merge 같은 트리 구조 변경): WL#6326이 SMO 동안 index 전체를 X로 잠그던 것을 `index->lock` SX + 개별 block latch로 바꿔, SMO가 진행되는 동안에도 다른 스레드의 검색이 트리를 통과하게 했다. write-heavy workload의 index 확장성 개선이 5.7의 대표 성과로 꼽힌다.

**PostgreSQL** — 출시 버전(18 이하)은 content lock이 SHARE/EXCLUSIVE 2단계라 CUBRID와 같은 처지였고, 같은 방식으로 풀었다: `FlushBuffer` 가 SHARE만 쥐고 쓰되, SHARE 아래에서도 바뀔 수 있는 hint bit(튜플 가시성 캐시 비트) 때문에 checksum이 깨질 수 있어 page 사본(`PageSetChecksumCopy`)을 만들고, I/O 중 재수정은 `BM_JUST_DIRTIED` 플래그로 추적했다. 20devel master가 이 구조를 갈아엎었다: content lock을 buffer 상태어 내장 구현으로 재작성하고(commit `fcb9c977aa5`), `SHARE_EXCLUSIVE` mode를 추가해 flush와 hint bit 설정 양쪽에 요구했다(commit `82467f627bd` "Require share-exclusive lock to set hint bits and to flush"). 그 결과 "쓰는 동안 page가 바뀔 수 없음이 증명"되어 사본과 `BM_JUST_DIRTIED` 가 모두 사라졌고, 커밋 메시지가 이를 direct I/O와 AIO write의 전제조건으로 명시한다 — kernel이 syscall 반환 후에도 buffer 메모리를 읽을 수 있으므로 frame 안정성이 필수라는 논리다.

**SQL Server** — buffer latch가 KP/SH/UP/EX/DT 5단계이고, UP(update)는 SH와 호환·UP/EX와 배타로 SX와 같은 행렬이다. page를 disk에 쓰는 I/O 동안 UP latch를 보유해 reader(SH)는 통과시키고 writer(EX)만 막으며, PFS 같은 할당 page의 소규모 갱신에도 UP를 써서 갱신 중 조회를 허용한다. 같은 원리가 lock 계층에도 U(update) lock으로 존재해 read-then-update 패턴의 변환 교착을 막는다 — SX 계열 mode가 latch와 lock 양쪽에서 검증된 표준 기법임을 보여준다.

> **요지**: 세 엔진 모두 "flush 동안 reader는 통과, writer만 차단"과 "승격 후보의 직렬화"를 SX 등가 mode로 해결했다. 특히 CUBRID의 현재 flush(사본 + 재더티 추적)는 PostgreSQL 출시 버전 방식과 동형인데, 그 PostgreSQL이 AIO를 계기로 SX 방향으로 이동 중이라는 점이 방향성 판단에 유효하다.

### 2. CUBRID 적용 후보 지점

**(a) flush write path — 최우선 후보.** 현재 흐름:

```
pgbuf_bcb_flush_with_wal()                         page_buffer.c:10670
  ├ pgbuf_bcb_mark_is_flushing()                   :10801
  │    FLUSHING_TO_DISK 설정, DIRTY 해제 (재더티 추적 준비)
  ├ TDE page → tde_encrypt_data_page(암호화 출력 사본)  :10811
  ├ plain page → memcpy로 16KiB 사본                :10820  ★ 제거 후보
  ├ BCB mutex 해제                                  :10841
  │    ★ 이후 writer는 frame을 자유롭게 수정 (사본이 있어 안전)
  ├ logpb_flush_log_for_wal()                       :10848  WAL 선행 규칙
  └ 사본을 DWB/디스크에 write
```

SX 직접 flush와의 트레이드오프:

| 축 | AS-IS (사본 flush) | SX 직접 flush |
|---|---|---|
| flush CPU | 페이지당 16KiB memcpy | plain page는 무복사 |
| I/O 동안 writer | 자유 (재더티로 추적) | SX 해제까지 대기 |
| I/O 동안 reader | 자유 | 자유 (동일) |
| TDE | 암호화 출력 사본 필요 | 여전히 필요 |
| DWB | 사본을 slot에 다시 보관 | slot 보관 방식에 따라 사본 수 감소 가능 (검토 필요) |
| AIO/direct write 확장 | frame 불안정이라 사본 강제 | frame 안정 → 가능 (PostgreSQL 사례) |

핵심 쟁점은 둘째 줄이다. 현재 설계는 느린 I/O 동안 writer를 막지 않는 대신 매 flush에 복사 비용을 내는 선택인데, InnoDB와 PostgreSQL 20devel은 반대 선택으로 수렴했다. 어느 쪽이 CUBRID workload에 맞는지가 측정 대상이다(검토 항목 4). EPIC의 scan prefetch/AIO 후보(권장 자식 이슈 8)와 TPC-H 개선(CBRD-27188, CBRD-27191)이 진행되면 write 쪽 AIO의 전제조건으로서 SX의 가치가 더 커진다.

**(b) B-tree 승격 경로 대체.** `pgbuf_promote_read_latch` 호출자는 `btree.c`(root 승격 `:28079`, insert 하강 `:28372`, `:28645`, `:28675`)와 `file_manager.c` 뿐이다. SX 하강(InnoDB WL#6326 방식) 또는 확정적 SX→WRITE 승격으로 바꾸면 promote 실패와 루트 재시작이 사라진다. 실제 이득 크기는 현재 promote 실패 빈도에 비례하므로 baseline 측정이 선행돼야 한다.

**(c) 비후보.** 순수 READ/WRITE로 충분한 일반 fix 경로와, flush 완료 대기 전용인 `PGBUF_LATCH_FLUSH` pseudo-mode는 SX와 무관하게 유지된다. SX는 `PGBUF_LATCH_FLUSH` 의 개명이 아니다.

### 3. 설계 스케치 — 상태 표현과 경로별 변경점

BCB(buffer control block — frame에 올라온 page의 fix 수, latch, dirty 상태를 보관하는 제어 블록)는 latch 상태를 64-bit atomic word 하나에 담는다 (`page_buffer.c:499-508`):

```
union pgbuf_atomic_latch_impl {
  uint64_t raw;
  struct {
    PGBUF_LATCH_MODE latch_mode;   // enum:uint16_t — 집계 mode만 저장
    uint16_t waiter_exists;
    int32_t fcnt;                  // 전체 fix 수 (mode 구분 없음)
  } impl;
};
```

holder별 획득 mode가 남지 않으므로, READ와 SX가 공존하는 순간 "unfix되는 holder가 어느 mode였나"를 식별할 구조가 필요하다. 표현 방식 후보:

| 순위 | 안 | 권장 이유 / 고려사항 |
|---|---|---|
| 1 | SX를 별도 bit + owner로 분리: `waiter_exists` 옆에 sx bit, BCB에 `sx_owner` 스레드 기록 | SX holder는 페이지당 최대 1명이라 owner 하나로 충분하다. `latch_mode` 는 READ/WRITE 집계 그대로 두므로 lock-free READ 경로 변경이 최소화되고, 재귀 SX는 `sx_owner == self` 비교로, downgrade는 bit clear로 자연 처리된다. |
| 2 | `latch_mode` 에 `PGBUF_LATCH_SX` 값 추가 | enum이 `uint16_t` 라 공간은 있으나, READ+SX 공존 상태를 집계값 하나로 표현할 수 없어 결국 별도 bit가 필요해진다 — 사실상 1안으로 수렴한다. |

경로별 변경점:

- **lock-free READ fix**: 현재 무대기 grant CAS는 `latch_mode` 가 `PGBUF_NO_LATCH`/`PGBUF_LATCH_READ` 이고 `waiter_exists == false` 일 때 성립한다 (`page_buffer.c:6322-6344`). SX 도입 목적상 sx bit는 READ grant를 막지 않아야 하므로 READ 조건에서는 bit를 무시하고, WRITE 요청과 SX 요청만 bit를 검사한다. SX 획득/해제 자체는 저빈도 연산이라 BCB mutex 경유로 충분하다.
- **대기열과 wakeup**: `pgbuf_block_bcb` 대기 등록과 `pgbuf_wakeup_reader_writer` 묶음 wakeup에 SX 클래스를 추가한다. READ 묶음 + SX 1명은 함께 깨울 수 있고, WRITE는 단독으로 깨운다. `PGBUF_LATCH_FLUSH` 대기자 전용 wakeup(`pgbuf_wake_flush_waiters`)과의 구분은 유지한다.
- **승격**: SX→WRITE는 "fcnt가 자기 fix 수와 같아질 때까지 대기"로 단순해지고, 경쟁 promoter가 불가능하므로 `pgbuf_promote_read_latch` 의 실패 분기가 필요 없다. 승격 대기 중 신규 READ 유입 정책은 Open Questions 3.
- **flusher 소유권**: flusher는 page를 fix하지 않아 holder entry가 없다. `sx_owner` 를 스레드로 직접 기록하면 holder 목록과 독립적으로 소유를 표현할 수 있다(InnoDB가 `io_fix` 상태로 같은 문제를 푼다). 기존 `FLUSHING_TO_DISK` 플래그와 sx bit를 통합할지 병존시킬지는 Open Questions 4.
- **단계적 도입**: 1단계는 flush 내부 상태로 한정해 `pgbuf_fix` 공개 계약을 건드리지 않고 무복사 flush 효과만 측정한다. 이득이 확인되면 2단계로 `pgbuf_fix` 입력에 SX를 노출해 B-tree 하강에 적용한다 — 이때 watcher, holder, perfmon latch 집계 계약이 함께 바뀐다.

### 4. 성능 검증 계획

baseline은 기준 소스(5cd4f86)로 프로토타입 이전에 수집할 수 있고, 이 수치 자체가 조사 산출물이다:

| workload | 확인 목적 | 지표 |
|---|---|---|
| read-heavy (hot page 반복 SELECT) | SX 도입이 lock-free READ 경로를 해치지 않는지 | fix/unfix 처리량, `Num_data_page_fix_ext` |
| write-heavy (hot row 반복 UPDATE) | flush I/O 동안 WRITE 대기 비용이 허용 범위인지 | WRITE latch 대기시간, tps |
| flush-pressure (작은 `data_buffer_size` + checkpoint 반복) | 무복사 flush의 이득 | flush 처리량, flush 경로 CPU(memcpy 비중), checkpoint 소요시간 |
| B-tree 경합 (동시 insert, 좁은 key 범위) | 승격 실패 제거의 이득 | `Data_page_total_promote_success`/`_fail`/`_time_msec`, `Num_data_page_promote_ext` |
| TPC-H (EPIC 코멘트) | scan 성능 회귀가 없는지 | 쿼리별 응답시간 |

판정 기준: read-heavy와 TPC-H에서 회귀 없음(오차 범위 내)을 전제로, flush-pressure 또는 B-tree 경합에서 유의미한 개선이 확인될 때만 구현 이슈로 전환한다. write-heavy에서 WRITE 대기 악화가 관찰되면 InnoDB처럼 SX nowait + 포기/우회 정책으로 완충 가능한지를 함께 평가한다.

## Specification Changes

N/A — 조사 이슈. 후속 구현 이슈에서 확정한다.

## Acceptance Criteria

- [ ] InnoDB/PostgreSQL/SQL Server 비교 분석이 문서화되고, 각 이점이 CUBRID에 해당하는지 여부가 판정된다.
- [ ] 적용 경계(public fix latch vs flush 내부 상태)와 최초 적용 대상 권고가 근거와 함께 제시된다.
- [ ] 상태어·holder·wakeup 설계 스케치가 EPIC의 4개 결정사항(경계, owner/count 기록, unfix/downgrade/recursion/promotion, flusher 소유권과 wakeup 순서)에 답한다.
- [ ] baseline 수치(promote 실패 빈도, flush 경로 memcpy CPU 비중)가 기준 소스에서 수집된다.
- [ ] go/no-go 권고와, go일 경우 후속 구현 이슈의 범위 초안이 정의된다.

## Definition of done

- [ ] 위 Acceptance Criteria 충족.
- [ ] 조사 결론이 EPIC CBRD-27193에 링크되고 자식 이슈 상태가 갱신된다.
- [ ] 구현 진행 결정 시 후속 이슈가 생성되고 성능 기준이 승계된다.

## Open Questions

1. **명칭** — 다중 단위 intent semantics가 없으므로 EPIC은 `SIX` 대신 `SX` 를 권장한다. transaction lock의 SIX와 혼동을 피하는 확정 명칭 합의가 필요하다.
2. **최초 적용 대상** — flush 내부 상태(1단계)부터인지, B-tree 승격까지 한 번에인지. `TBD - 합의 미확인`.
3. **승격 대기 중 신규 READ 정책** — SX 승격 대기 시작 후 신규 READ를 계속 받으면 승격이 기아에 빠지고, 즉시 차단하면 reader 지연이 커진다. READ→WRITE 대기에도 같은 문제가 있으므로 기존 `waiter_exists` fairness 정책과 일관되게 정해야 한다.
4. **`FLUSHING_TO_DISK` 플래그와 SX 상태의 관계** — 통합(플래그가 곧 SX)인지 병존인지. 통합 시 기존 재더티 추적(`pgbuf_bcb_mark_is_flushing` 의 DIRTY 해제)이 불필요해지는지 검증이 필요하다.
5. **DWB 경로의 사본 수** — `dwb_set_data_on_next_slot` 이 slot에 이미지를 보관하는 방식에 따라 SX 직접 flush에서도 사본 한 번이 남는지가 갈린다. DWB 코드 확인 후 판정.
6. **재귀 SX와 downgrade** — 같은 스레드의 중복 SX 획득 허용 여부, SX→READ downgrade 제공 여부.

## 참고 코드

- `src/storage/page_buffer.h:190-197` — `PGBUF_LATCH_MODE` enum (`enum:uint16_t`)
- `src/storage/page_buffer.c:499-508` — BCB atomic latch word 레이아웃
- `src/storage/page_buffer.c:2842-3045` — `pgbuf_promote_read_latch` (실패 기반 승격)
- `src/storage/page_buffer.c:6322-6344` — lock-free READ grant CAS 조건
- `src/storage/page_buffer.c:10670-10898` — `pgbuf_bcb_flush_with_wal` (사본 flush 흐름)
- `src/storage/btree.c:28079, 28372, 28645, 28675` — 승격 호출과 실패 fallback
- `src/base/perf_monitor.c:446-448, 572-575` — promote 성공/실패/시간 통계

## References

- 부모 EPIC: [CBRD-27193](http://jira.cubrid.org/browse/CBRD-27193) — SX latch 후보의 경계, 권장 호환성 행렬, 검증 요구사항
- [CUBRID flush·WAL·DWB 분석](https://github.com/vimkim/my-cubrid-docs/blob/343ecc9c8e246cb15c19de0cb6c34117950955e6/pgbuf-analysis/research/cubrid-flush-wal-dwb.md)
- [InnoDB buffer pool 비교](https://github.com/vimkim/my-cubrid-docs/blob/343ecc9c8e246cb15c19de0cb6c34117950955e6/pgbuf-analysis/research/innodb-bufpool.md)
- [PostgreSQL buffer manager 비교](https://github.com/vimkim/my-cubrid-docs/blob/343ecc9c8e246cb15c19de0cb6c34117950955e6/pgbuf-analysis/research/postgres-bufmgr.md)
- MySQL [WL#6363: InnoDB: implement SX-lock for rw_lock](https://dev.mysql.com/worklog/task/?id=6363), [WL#6326: InnoDB: fix index->lock contention](https://dev.mysql.com/worklog/task/?id=6326), [MySQL 5.7.2 Milestone Release](https://dev.mysql.com/blog-archive/the-mysql-5-7-2-milestone-release/)
- PostgreSQL master commits: `82467f627bd` "Require share-exclusive lock to set hint bits and to flush", `fcb9c977aa5` (content lock 재구현)
- [Microsoft Learn — Diagnose and resolve latch contention (latch mode 호환성, UP latch)](https://learn.microsoft.com/en-us/sql/relational-databases/diagnose-resolve-latch-contention)
