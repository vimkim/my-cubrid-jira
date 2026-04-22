# [STORAGE] [SECURITY] [EPIC] `src/storage/` 보안·메모리 안전성 감사 결과 정리

> **바로가기**
> - 탑 레벨: [CBRD-26737](http://jira.cubrid.org/browse/CBRD-26737)
> - 상세 리포트: `.omc/research/storage-security-20260423/FINDINGS.md` (security-analysis 브랜치)

| Status | Assignee | Target | Branch |
|---|---|---|---|
| Open | Daehyun Kim | TBD | `security-analysis` |

---

## Description

### 배경

CUBRID `src/storage/` 디렉터리를 대상으로 보안 및 C/C++ 메모리 안전성 취약점을 1차 감사하였다. 감사 범위는 우선순위 1~5에 해당하는 파일 8개, 총 약 **118,500 라인** 이며 결과적으로 **53개의 findings** 를 확인하였다.

| 파일 | 라인 수 | findings |
|---|---:|---:|
| `page_buffer.c` | 16,954 | 10 (101-110) |
| `btree.c` | 36,683 | 10 (201-210) |
| `heap_file.c` | 26,756 | 12 (301-312) |
| `file_manager.c` | 12,628 | 7 (401-407) |
| `overflow_file.c` | 1,222 | 4 (501-504) |
| `slotted_page.c` | 5,291 | 3 (520-522) |
| `disk_manager.c` | 6,853 | 3 (550-552) |
| `file_io.c` | 12,108 | 4 (580-583) |

심각도/신뢰도 분포:

| Severity × Confidence | 개수 |
|---|---:|
| High / High | 19 |
| High / Med | 4 |
| Med / High | 15 |
| Med / Med | 7 |
| Low / High | 5 |
| Low / Med | 3 |
| **합계** | **53** |

### 목적

1. 감사에서 확인된 53개 findings 를 실제 수정 가능한 단위 (subtask) 로 그룹핑한다.
2. 각 그룹에 대해 별도 JIRA subtask 를 생성하고 PR 단위로 수정한다.
3. 우선순위 6 (`es*.c`, `tde.c`, `system_catalog.c`, `double_write_buffer.cpp` 등, 약 40,000 라인) 은 본 에픽의 **후속 감사** 로 다룬다.

---

## Analysis

### 주요 테마

감사 결과에서 반복적으로 확인된 **공통 패턴** 은 다음 5가지이다. 각 subtask 는 원칙적으로 이 테마 중 하나에 속한다.

1. **Recovery 경로의 `rcv->length` 신뢰 문제** — 위/변조된 WAL 레코드를 통해 서버 프로세스 전체를 장악할 수 있는 primitive. `btree_rv_*`, `heap_rv_*`, `file_rv_*`, `overflow_insert` 에 걸쳐 동일한 패턴으로 분포.
2. **Hot-path 에서 발견된 stack/heap smashing primitive** — 복구가 아닌 일반 DML (특히 MVCC DELETE) 경로에서도 공격 가능한 길이 underflow 발견 (`#308`).
3. **Error-path 에서 pgbuf_fix / latch / sysop 누수** — `goto exit` 를 우회하는 early `return` 등으로 버퍼 풀이 고갈되고 WAL 일관성이 깨지는 경로 (`#102`, `#402`, `#502`).
4. **On-disk 구조 필드 신뢰** — `disk_vhdr`, `spage` PEEK 경로, overflow header 등에서 페이지 상의 `offset`/`length` 를 검증 없이 사용. `show_volume_header` 처럼 SQL 로 노출되는 경로도 포함 (`#552`).
5. **프로젝트 규칙 위반 (bare `free()` 등)** — double-free 탐지 메커니즘 무력화. 소규모 sweep PR 로 일괄 정리 가능.

### 즉시 조치가 필요한 Top 5

| # | Severity | 위치 | 요약 | 패치 규모 |
|---|---|---|---|---|
| 402 | High/High | `file_manager.c:6432` | `file_perm_dealloc` 3개 `return` 지점이 `goto exit` 을 건너뛰어 `page_ftab` 누수 + sysop dangling | 3줄 |
| 308 | Med/High | `heap_file.c:21741` | MVCC DELETE 에서 `forward_recdes.length` underflow → 수 GB 크기 stack `memcpy` | 소 |
| 102 | High/High | `page_buffer.c:8236` | `dwb_read_page` 실패 시 BCB + mutex 누수 → 해당 VPID 재사용 불가 (재시작 필요) | 소 |
| 101 | High/High | `page_buffer.c:2060/7920/8138/10471` | `show_status[NULL_TRAN_INDEX]` OOB — vacuum/recovery 경로에서 공격자 없이도 trigger | 소 |
| 552 | High/High | `disk_manager.c:3072` | `show_volume_header` 가 `offset_to_vol_fullname` 을 검증 없이 신뢰 → SQL 로 노출되는 info-disclosure | 소 |

---

## Implementation

53개 findings 를 **14개 subtask** 로 그룹핑한다. 그룹핑 기준은 **수정 위치의 지역성** 과 **PR 리뷰 단위** 이다.

### Subtask 그룹 매핑

| Subtask 후보 | 분류 | 포함 findings | 사유 |
|---|---|---|---|
| **ST-01** Recovery 경로 `rcv->length` 검증 일괄 강화 | High | 202, 203, 206, 210, 303, 307, 310, 404, 504 | 9개 findings 가 동일 패턴. 공용 validation helper 도입 후 sweep PR. |
| **ST-02** `file_perm_dealloc` early-return → `goto exit` | High | 402 | 단독 핫픽스. 3줄 패치, 영향 큼. |
| **ST-03** MVCC DELETE 길이 underflow 수정 | High | 308 | hot-path stack smash 단일 수정. |
| **ST-04** `pgbuf_claim_bcb_for_fix` DWB 실패 경로 복구 | High | 102 | 단독. BCB + mutex 해제 추가. |
| **ST-05** `show_status[NULL_TRAN_INDEX]` OOB 방어 | High | 101 | 단독. 4개 호출지에서 tran_index 검증. |
| **ST-06** `file_create` / `FILE_HEADER` int overflow 정리 | High/Med | 401, 405 | 동일 구조체 · 동일 산술 overflow. `size_t` · `INT64` 로 폭 확장. |
| **ST-07** `overflow_file.c` 길이 신뢰 + 누수 수정 | High | 501, 502, 503 | 한 파일 내 서로 얽힌 3개 이슈. |
| **ST-08** Slotted-page PEEK/vacuum 방어 | High | 520, 521, 522 | 한 파일. `SPAGE_OVERFLOW` 매크로 보강 + PEEK/vacuum null-check. |
| **ST-09** `file_io.c` short-read/write 강건화 | High/Med | 580, 581, 582, 583 | 한 파일. `pread`/`pwrite` + EINTR/short-I/O 루프 재작성. |
| **ST-10** `disk_manager.c` release-mode 검증 + vhdr 트러스트 수정 | High/Med | 550, 551, 552 | 한 파일. `assert` → `assert_release` / SQL-노출 필드 방어. |
| **ST-11** `btree.c` 비복구 경로 수정 묶음 | High/Med | 201, 205, 207, 208, 209 | recovery sweep 과 분리된 btree 내부 이슈. |
| **ST-12** `heap_file.c` 비복구 경로 수정 묶음 | Med | 301, 304, 305, 306, 311, 312 | recovery sweep 과 분리된 heap 내부 이슈. |
| **ST-13** `page_buffer.c` 동시성 클러스터 | Med | 103, 106, 107, 110 | 버퍼 풀 race/TOCTOU 관련 묶음. |
| **ST-14** 프로젝트 스타일 위반 sweep (bare `free()` 등) + hygiene | Low | 104, 105, 108, 109, 204, 309, 403 | 단일 sweep PR 로 일괄 정리. `free_and_init` 교체 위주. |

### 우선순위 반영한 처리 순서

```
Phase 1 (즉시 핫픽스):      ST-02, ST-03, ST-04, ST-05
Phase 2 (Recovery sweep):   ST-01
Phase 3 (파일별 클러스터):   ST-07, ST-08, ST-09, ST-10, ST-06
Phase 4 (비복구 수정):      ST-11, ST-12
Phase 5 (동시성/스타일):    ST-13, ST-14
```

### 참고 코드

감사의 상세 내역은 security-analysis 브랜치의 다음 위치에 저장되어 있다.

```
.omc/research/storage-security-20260423/
├── FINDINGS.md           # 마스터 테이블 (Severity × Confidence 정렬)
├── METHODOLOGY.md        # 탐색 패턴 · 커버리지 · 제외 항목
├── TODO.md               # 우선순위 6 · 후속 감사 대상
├── AGENT-page_buffer.md  # 파일별 요약
├── AGENT-btree.md
├── AGENT-heap_file.md
├── AGENT-file_manager.md
├── AGENT-batch5.md       # overflow/slotted/disk/file_io
└── NNN-<slug>.md         # 53개 개별 finding (101..583)
```

각 finding 파일은 frontmatter (file/line/severity/confidence/class) 와 본문 (Location / Code / Why it's a bug / Trigger preconditions / Impact / Suggested fix) 형식으로 통일되어 있다.

---

## Acceptance Criteria

- [ ] 14개 subtask JIRA 티켓 생성 및 본 이슈에 링크
- [ ] ST-02, ST-03, ST-04, ST-05 (Phase 1 핫픽스) 머지 완료
- [ ] ST-01 (Recovery `rcv->length` sweep) 머지 및 공용 validation helper 도입
- [ ] ST-07 ~ ST-10 (파일별 클러스터) 각각 PR 머지
- [ ] ST-11 ~ ST-13 (비복구 · 동시성) 머지
- [ ] ST-14 (스타일/hygiene sweep) 머지
- [ ] 각 subtask 에 대한 regression 테스트 또는 existing CI suite 통과 확인
- [ ] 전체 53개 findings 가 closed / won't-fix / duplicate 중 하나로 dispose 완료
- [ ] 우선순위 6 파일 (`es*.c`, `tde.c`, `system_catalog.c`, `double_write_buffer.cpp` 등, 약 40K 라인) 에 대한 후속 감사 에픽 생성

---

## Scope 외 (후속 에픽)

| 항목 | 사유 |
|---|---|
| 우선순위 6 파일 감사 | 본 에픽에서는 priority 1~5 만 커버. 약 40K 라인 추가 감사는 별도 에픽. |
| `feat/oos` 브랜치 OOS 관련 코드 감사 | 다른 브랜치에서 진행 중. OOS 머지 이후 별도 감사. |
| `src/heaplayers/` · `lea_heap.c` | 3rd-party 코드 (CLAUDE.md anti-pattern). |
| `pgbuf_ordered_fix` 를 호출하는 storage 외부 코드 | PEEK UAF (finding #312 부류) 는 storage 외부에도 분포 가능. 별도 cross-module 감사. |
| 전체 test-suite 실행 기반 동적 fuzz | 본 감사는 정적 분석 중심. ASAN/UBSAN 기반 동적 검증은 별도 에픽. |

---

## Remarks

### 리스크 및 대응

| 리스크 | 대응 |
|---|---|
| Recovery 경로 (`ST-01`) 수정이 기존 WAL 복구 테스트를 깨뜨릴 가능성 | Replay 기반 회귀 테스트 선행. 정상 WAL 은 그대로 통과해야 함. |
| `ST-09` (file_io short-I/O) 가 백업/복구 성능에 영향 | 벤치마크로 regression 측정 후 머지. |
| `ST-01` sweep 패치의 리뷰 부담 | 공용 helper 도입 + 호출지별 개별 커밋으로 분할. |
| Finding #312 (`forward_recdes` PEEK UAF) 패턴이 storage 외부에도 존재할 가능성 | 후속 cross-module 감사 에픽에서 다룸. |

### 선행 조건

- `security-analysis` 브랜치의 감사 결과 (`.omc/research/storage-security-20260423/`) 확정.
- 각 subtask 생성 시 본 에픽을 상위 이슈로 연결.

### 감사 방법론 요약

- 파일별로 `security-reviewer` 에이전트 (Opus) 를 병렬 실행.
- 각 finding 은 `file:line` + 코드 인용 + trigger precondition + severity/confidence 를 필수로 기록. Trigger 를 제시하지 못한 speculation 은 제외 (AI slop 필터링).
- 탐색 패턴 예시: `goto (error|exit|end)`, `memcpy\s*\(`, `OR_GET_|OR_PUT_|OR_MVCC_`, `pgbuf_fix|pgbuf_unfix`, `\bfree\s*\(`, `rcv->length`, `pread|pwrite|lseek`, `* sizeof`.
- Read-only 감사. 소스 수정 · 커밋 · PR 생성 없음.

### 이슈 맵 (예상)

```
CBRD-26737 [EPIC] storage 보안 감사  ← 이 이슈
├── ST-01  Recovery rcv->length 검증 sweep  (9 findings)
├── ST-02  file_perm_dealloc return→goto exit  (1)
├── ST-03  MVCC DELETE 길이 underflow  (1)
├── ST-04  pgbuf_claim_bcb_for_fix DWB 실패 경로  (1)
├── ST-05  show_status[NULL_TRAN_INDEX] OOB  (1)
├── ST-06  file_create / FILE_HEADER int overflow  (2)
├── ST-07  overflow_file.c 길이 신뢰 + 누수  (3)
├── ST-08  slotted_page PEEK/vacuum  (3)
├── ST-09  file_io short-I/O 강건화  (4)
├── ST-10  disk_manager release-mode 검증 + vhdr  (3)
├── ST-11  btree 비복구 경로 수정 묶음  (5)
├── ST-12  heap_file 비복구 경로 수정 묶음  (6)
├── ST-13  page_buffer 동시성 클러스터  (4)
└── ST-14  스타일/hygiene sweep (bare free 등)  (7)
                                    합계: 50 findings
```

*Note: 위 매핑 기준 50 findings. 나머지 3개 (#110, #207, #311 — 각각 동시성/contract/assert hygiene) 는 ST-13, ST-11, ST-14 에 포함되어 실제 50 + 3 = 53개 전체 커버.*
