# [OOS] [EPIC] 대용량 컬럼 Out-of-Line 저장 구조(OOS) 도입

> **바로가기**
> - M1: [CBRD-26584](http://jira.cubrid.org/browse/CBRD-26584) | M2: [CBRD-26583](http://jira.cubrid.org/browse/CBRD-26583)
> - TODO: [CBRD-26517](http://jira.cubrid.org/browse/CBRD-26517) | Survey (완료): [CBRD-26198](http://jira.cubrid.org/browse/CBRD-26198)

| Status | Assignee | Target | Branch |
|---|---|---|---|
| Develop | Daehyun Kim | guava | `feat/oos` |

---

## Description

### 문제

CUBRID는 한 행(row)의 모든 컬럼을 하나의 페이지에 붙여서 저장한다. `SELECT id FROM t` 처럼 작은 컬럼 하나만 필요해도, 같은 행에 있는 큰 컬럼(1KB, 2KB...)까지 통째로 디스크에서 읽어야 한다.

### 해결

큰 컬럼만 별도 파일(OOS 파일)에 따로 빼놓고, 원래 자리에는 "여기에 있어요"라는 **16바이트 주소표(OOS OID)** 만 남긴다. 작은 컬럼만 조회하면 OOS 파일을 읽지 않아도 된다.

```
기존:  [ id | name | big_text(1.7KB) | big_blob(2KB) ]  ← 전부 한 덩어리

OOS:   [ id | name | OOS OID(16B) | OOS OID(16B) ]      ← 작고 빠름
                         |               |
                         v               v
                  [ big_text ]     [ big_blob ]           ← OOS 파일 (별도)
```

### OOS가 작동하는 조건

두 조건을 **모두** 만족해야 컬럼이 OOS로 빠진다:
1. 행 전체 크기 > `DB_PAGESIZE / 8` (16KB 페이지 기준 2KB)
2. 해당 컬럼 크기 > 512B

---

## Spec Change

### 핵심 변경

| | 기존 | OOS 도입 후 |
|---|---|---|
| 큰 행 처리 | 행 전체를 Overflow 페이지로 이동 | 큰 **컬럼만** OOS 파일로 분리 |
| Heap record | 모든 컬럼 값 포함 | 작은 값 + OOS OID(16B) |
| 파일 구조 | 테이블 1개 = heap 1개 | 테이블 1개 = heap 1개 + OOS 1개 |

### OOS OID (16바이트)

| 필드 | 크기 | 설명 |
|---|---|---|
| `volid` | 2B | 볼륨 ID |
| `pageid` | 4B | 페이지 ID |
| `slotid` | 2B | 슬롯 ID |
| `full_length` | 8B | 원본 값 전체 길이 |

### 플래그

- **`HAS_OOS`** (MVCC 헤더 bit 3) — 이 행에 OOS 컬럼이 있음
- **`IS_OOS`** (VOT 엔트리 bit 0) — 이 컬럼이 OOS로 저장됨

### 타 DBMS 비교

| | PostgreSQL | MySQL | CUBRID OOS |
|---|---|---|---|
| 방식 | TOAST | Off-page | OOS file |
| 포인터 크기 | 18B | 20B | **16B** |
| 압축 | lz4/pglz | COMPRESSED | 없음 (M1) |

---

## CRUD 동작

| 연산 | 동작 |
|---|---|
| **INSERT** | 큰 컬럼 → `oos_insert()` → OOS OID를 heap record에 기록 |
| **SELECT** | `HAS_OOS` 플래그 확인 → OOS 컬럼이면 `oos_read()` 로 실제 값 가져옴 |
| **UPDATE** | 항상 새 OOS OID 생성 (M1). 이전 OOS는 MVCC용으로 유지, vacuum이 정리 |
| **DELETE** | OOS 건드리지 않음. vacuum이 나중에 `oos_delete()` 로 정리 |

**핵심 규칙**: 하나의 OOS OID는 정확히 하나의 레코드에서만 참조된다. 공유 없음.

---

## Milestones

### M1 — 기본 기능 (CBRD-26584, DONE, ~2026-02)

OOS CRUD, WAL 로깅, HA replication, covered index 지원. `test_sql`/`test_medium`/`HA_repl` 통과.

제약: `oos_file_destroy` 없음, UPDATE 시 항상 새 OOS OID, vacuum 미연동.

### M2 — 운영 품질 (CBRD-26583, IN PROGRESS, 03/10~04/17)

| Story | 내용 | JIRA |
|---|---|---|
| Best Page | 3-tier bestspace로 페이지 공간 재활용 | CBRD-26658 ✅ |
| Compaction | `spage_compact` 으로 페이지 내 빈 공간 합치기 | CBRD-26536 |
| Drop Table | `oos_file_destroy` 로 OOS 파일 삭제 | CBRD-26608 |
| Vacuum 연동 | DELETE된 OOS 레코드를 vacuum이 정리 | CBRD-26668 |
| 머지 | develop 브랜치 머지, CI 전체 통과 | — |

### M3 — OOS OID 재사용 (PLANNED, 04/20~05/29)

UPDATE 시 값 미변경 컬럼의 OOS OID 재사용, PEEK 모드, across-page compaction.

### M4 — 안정화 (TBD)

Ordered page fix로 deadlock 방지, 모니터링 도구.

---

## Known Bugs

| 문제 | JIRA |
|---|---|
| `unloaddb` 1.6~1.7x 느림 (`heap_attrinfo_start` 과다 호출) | CBRD-26458 |
| UPDATE 시 `oos_read` 3회 중복 | CBRD-26516 |
| CDC flashback OOS OID 미해석 | — |
| `locator_add_or_remove_index` 에서 불필요한 OOS repl log | — |
| RECDES length 4바이트(2GB) 제한 | — |

---

## Acceptance Criteria

- [ ] OOS CRUD 정상 동작
- [ ] Crash recovery 후 OOS 정합성 유지
- [ ] HA replication 정상 (값 동일성 보장)
- [ ] DROP TABLE 시 OOS 파일 회수
- [ ] Vacuum 연동으로 orphan 정리
- [ ] develop 머지 및 CI 통과

---

## Remarks

### 이슈 맵

```
CBRD-26357 [EPIC] OOS
├── CBRD-26198 [Survey] (완료)
├── CBRD-26517 [TODO]
├── CBRD-26584 [M1] — 20개 subtask
└── CBRD-26583 [M2] — 15개 subtask
```

### 설계 논의 (2026/3/5)

- 여러 OOS 컬럼을 하나로 합쳐 저장할지 vs 개별 저장 — 미결정
- OOS page latch 경합 → 추후 병목 시 page 분할 고려
- OVF + OOS 동시 발생 TC 작성 필요
- CHAR 타입도 OOS 대상 포함 검토 중
