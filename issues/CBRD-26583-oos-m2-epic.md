# [OOS] [EPIC] [M2] OOS Milestone 2 — 운영 품질 확보 및 develop 머지

> **바로가기**
> - 탑 레벨 에픽: [CBRD-26357](http://jira.cubrid.org/browse/CBRD-26357)
> - M1 (완료): [CBRD-26584](http://jira.cubrid.org/browse/CBRD-26584)
> - M2 (이 이슈): [CBRD-26583](http://jira.cubrid.org/browse/CBRD-26583)

| Status | Assignee | Target | Branch |
|---|---|---|---|
| Develop | Daehyun Kim | guava | `feat/oos` |

## 한 줄 요약 (먼저 읽기)

OOS(Out-of-row Storage — heap 레코드의 큰 가변 컬럼을 별도 OOS 파일로 빼서 저장하는 새 저장 구조)의 M1에서 빠진 운영 필수 기능을 채워 develop 머지 가능한 품질로 만든다. 이 티켓 자체에는 코드 변경이 없고, 아래 sub-task들이 실제 구현을 맡는다.

---

## Issue Triage

**이슈 수행 목적**: OOS Milestone 1에서 미구현으로 남긴 운영 필수 기능을 모두 채워, `feat/oos` 브랜치를 develop 으로 머지 가능한 상태로 만든다.

**이슈 수행 이유**:

- **현재 동작 / 배경**: M1 (CBRD-26584, Resolved) 은 "정확하게 동작"을 우선해 기본 CRUD + WAL (Write-Ahead Logging — 디스크 페이지 변경 전 로그부터 기록) + recovery + HA replication 만 구현했다. 그 결과 (a) `DROP TABLE` 해도 OOS 파일이 회수되지 않고, (b) vacuum (MVCC 정리 작업) 이 heap record 를 정리할 때 연결된 OOS 레코드가 그대로 남으며, (c) UPDATE / DELETE 시 이전 OOS 가 영구히 잔존하고, (d) bestspace (heap 이 새 데이터를 넣을 빈 공간 많은 페이지 캐시) 가 단일 페이지만 기억해 hotspot (한 페이지에 갱신 집중) 이 발생한다.
- **영향**: 운영 환경 적용 불가 — 위 네 가지가 모두 디스크 공간 누수 또는 lock 경합 으로 이어지며, 이 상태로는 develop 브랜치에 머지할 수 없다.

**이슈 수행 방안**:

- 공간 회수 경로 확보: `xheap_destroy` 에서 OOS VFID (volume file identifier — 영구 파일 식별자) 를 확인해 `oos_file_destroy` 로 회수 (CBRD-26608).
- Vacuum 연동: `vacuum_heap_record` 가 heap record 정리 시 `heap_recdes_get_oos_oids` 로 OOS OID 목록을 뽑아 sysop (top system operation — 다중 페이지 변경을 원자 단위로 묶는 단위) 안에서 `oos_delete` 호출 (CBRD-26592).
- Bestspace 정책: 단일 페이지 캐시를 3-Tier (글로벌 해시 캐시 -> 헤더 best[10] 배열 -> 파일 스캔) 로 교체 (CBRD-26658).
- OOS 물리적 삭제: `oos_delete` 가 `spage_delete` 로 슬롯을 물리적으로 지우고 WAL 까지 남김 (CBRD-26609, 완료).
- 인라인 길이 저장: OOS 인라인 포맷을 `[OOS OID(8B) + length(8B)] = 16B` 로 확장해 `oos_get_length()` I/O 제거 (CBRD-26630, 완료).
- 에러 핸들링 통합: `oos_error` 매크로를 CUBRID 표준 `er_set` + `ASSERT_ERROR` 로 치환 (CBRD-26637, 완료).
- In-page compaction: `spage_insert` 내부에서 자동 수행됨이 확인되어 별도 구현 없음 (CBRD-26536, 완료).
- 테스트 / CI: 개발자 SQL/Shell 테스트 추가 (CBRD-26659), QA 실패 매뉴얼 테스트 분석 (CBRD-26660), unit_tests/oos 보강 (CBRD-26665).
- 머지 조건: 위 sub-task 모두 종료 + check / test / build CI 전 통과.

---

## AI-Generated Context

> 아래 내용은 AI 가 코드/맥락을 분석해 작성한 상세 자료입니다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하시면 됩니다.

### Summary

- **문제 / 목적**: OOS M1 의 운영 공백(DROP TABLE / vacuum / hotspot / 이전 OOS 잔존)을 메워 develop 머지 가능 품질을 달성.
- **원인 / 배경**: M1 은 "정확하게 동작" 단계라 공간 회수 / 정리 / hotspot 완화는 의도적으로 후순위였다.
- **제안 / 변경**: 본 에픽은 직접 코드 변경 없음. 9개 sub-task 가 위 공백을 분담.
- **영향 범위**: heap / OOS / vacuum / log recovery / 페이지 공간 정책. 사용자 SQL 시맨틱 변경은 없음.

---

## Description

### 배경

OOS Milestone 1에서 기본 CRUD(insert/read/update/delete), WAL 로깅, recovery, HA replication 까지 구현해 핵심 기능은 동작하는 상태다. 단, M1 은 "먼저 정확하게 동작하는 것" 에 집중했기 때문에 운영 환경에서 필요한 보조 기능이 의도적으로 빠져 있다.

### 목적

M1 에 빠져 있던 보완 사항을 모두 처리하고, **develop 브랜치에 머지할 수 있는 품질** 까지 끌어올린다.

1. OOS 파일 / 페이지 공간 회수 경로 확보 (DROP TABLE, vacuum 연동)
2. 3-Tier Bestspace 정책으로 hotspot / fragmentation (페이지 안 빈 조각이 흩어져 못 쓰는 상태) 완화
3. `oos_delete` 구현으로 UPDATE / DELETE 시 OOS 를 물리적으로 삭제
4. 에러 핸들링을 CUBRID 표준 (`er_set`, `ASSERT_ERROR`) 으로 통합
5. develop 브랜치 머지 및 CI 통과

### 새로 합류한 사람을 위한 OOS 개요 (30초)

- **OOS 가 풀려는 문제**: heap 레코드 안에 큰 가변 컬럼(`varchar(20000)` 같은 것) 이 들어가면 heap 페이지가 빠르게 가득 차 fragmentation 이 심해진다. PostgreSQL 의 TOAST 와 같은 발상으로, 큰 값은 별도 파일에 떼어 저장한다.
- **저장 위치**: heap record 안에는 OOS OID (8B) + length (8B) = 16B 인라인 토큰만 남기고, 실제 페이로드는 OOS 파일에 둔다.
- **읽기 경로**: heap 에서 OOS OID 를 뽑아 (`heap_recdes_get_oos_oids`) OOS 파일에서 페이로드를 가져온다.
- **유지보수 경로**: heap record 가 삭제 / 갱신되면 OOS 측도 함께 정리해야 한다. M1 까지는 이 정리가 없었다 — M2 가 그 빈자리를 채운다.

---

## M1 현황 (AS-IS)

| 영역 | 현재 상태 | 문제점 |
|------|----------|--------|
| Best Page 캐시 | 마지막 삽입 페이지 1개만 기억 | hotspot 집중, 다른 페이지 빈 공간 낭비 |
| Drop Table | OOS 페이지 미회수 | DROP TABLE 해도 OOS 파일이 그대로 남음 |
| Vacuum 연동 | 미구현 | DELETE 된 record 에 매달린 OOS 가 영구 잔존 |
| OOS 삭제 | `oos_delete` 미구현 | UPDATE 시 이전 OOS 가 영구 잔존 |
| 에러 핸들링 | `oos_error` 매크로 (stderr, debug 빌드만) | release 빌드에서 비활성, `er_set` 미사용 |
| OOS 길이 | OOS OID(8B) 만 인라인 저장 | `oos_get_length()` 호출 시 추가 I/O |

---

## Sub-task 진행 현황

### 완료 (Resolved)

| JIRA | 제목 | 내용 |
|------|------|------|
| [CBRD-26582](http://jira.cubrid.org/browse/CBRD-26582) | M1 진행 상황 및 M2 설계 공유 | 개발 2팀 대상 발표 (3/5) |
| [CBRD-26537](http://jira.cubrid.org/browse/CBRD-26537) | `heap_recdes_get_oos_oids` API 구현 | classrepr (class representation — 컬럼 메타데이터) 없이 RECDES (record descriptor — 레코드 디스크립터) 만으로 OOS OID 추출. VOT 에 LAST_ELEMENT 정보 추가 |
| [CBRD-26609](http://jira.cubrid.org/browse/CBRD-26609) | `oos_delete` 구현 | `spage_delete` 로 OOS 슬롯 물리적 삭제, WAL 로깅 포함 |
| [CBRD-26630](http://jira.cubrid.org/browse/CBRD-26630) | OOS 길이 정보 인라인 저장 | 인라인 포맷을 16B (`OOS OID + length`) 로 변경. 추가 I/O 제거 |
| [CBRD-26637](http://jira.cubrid.org/browse/CBRD-26637) | 에러 핸들링 리팩터링 | `oos_error` 를 `er_set` + `ASSERT_ERROR` 로 치환 |

### 진행 중 (Develop)

| JIRA | 제목 | 내용 |
|------|------|------|
| [CBRD-26658](http://jira.cubrid.org/browse/CBRD-26658) | 3-Tier Bestspace 메커니즘 | 글로벌 해시 캐시, 헤더 best[10] 배열, 동기 스캔 3단계 탐색. 삭제 공간 즉시 재활용 |
| [CBRD-26608](http://jira.cubrid.org/browse/CBRD-26608) | DROP TABLE 시 OOS 회수 | `oos_file_destroy` 구현. `xheap_destroy` 에서 OOS VFID 확인 후 삭제 |

### 대기 (Confirmed / Open)

| JIRA | 제목 | 담당 | 내용 |
|------|------|------|------|
| [CBRD-26592](http://jira.cubrid.org/browse/CBRD-26592) | Vacuum 과 OOS 연동 | 김희수 | vacuum 이 heap record 정리 시 `oos_delete` 호출. sysop 으로 원자적 처리 |
| [CBRD-26383](http://jira.cubrid.org/browse/CBRD-26383) | `spage_insert_multiple` API | 김대현 | 여러 데이터를 하나의 page offset 에 동시 저장하는 API |
| [CBRD-26550](http://jira.cubrid.org/browse/CBRD-26550) | `REC_OOS` 타입 도입 | 김대현 | vacuum 이 OOS record 와 heap record 를 구분하기 위한 새 레코드 타입 |
| [CBRD-26536](http://jira.cubrid.org/browse/CBRD-26536) | In-page Compaction 분석 | 김대현 | **결론: 별도 구현 불필요.** `spage_insert` 내부에서 자동 compact 수행 확인 |
| [CBRD-26659](http://jira.cubrid.org/browse/CBRD-26659) | 개발자 SQL/Shell 테스트 생성 | 김대현 | OOS 시나리오 테스트 작성 |
| [CBRD-26660](http://jira.cubrid.org/browse/CBRD-26660) | 매뉴얼 테스트 결과 분석 | 김대현 | QA 실패 케이스 분석 및 이슈화 |
| [CBRD-26665](http://jira.cubrid.org/browse/CBRD-26665) | unit_tests/oos 추가 및 개선 | 김대현 | OOS 단위 테스트 커버리지 확대 |

---

## Specification Changes

사용자 SQL 시맨틱 / 시스템 카탈로그 / wire protocol 모두 변경 없음.

내부 디스크 포맷 변경은 두 가지로, 모두 M1 에서 이미 합의된 사항이다.

- 인라인 OOS 토큰: 8B (OOS OID 만) -> 16B (`OOS OID + length`). 마이그레이션 부담은 M2 시점에서 develop 머지 전이므로 신규 포맷만 지원.
- (예정) `REC_OOS` 새 레코드 타입: vacuum 이 OOS 레코드를 heap 레코드와 구분하기 위함 (CBRD-26550). 기존 페이지 호환은 sub-task 에서 결정.

---

## Implementation

### Story 1: 3-Tier Bestspace 정책 (CBRD-26658)

단일 페이지 캐시를 3-tier bestspace 로 교체해 공간 재활용률을 높인다.

```
oos_find_best_page()
├─ Tier 1: 글로벌 해시 캐시 (VFID -> entry)
├─ Tier 2: 헤더 페이지 best[10] 순환 배열
├─ Tier 3: OOS 파일 페이지 스캔 (최대 20%, 100개 제한)
└─ Fallback: 신규 페이지 할당
```

### Story 2: In-page Compaction (CBRD-26536)

분석 결과, `spage_insert` 가 `cont_free < needed && total_free >= needed` 조건에서 자동으로 `spage_compact` 를 호출하므로 **별도 구현이 불필요** 하다.

### Story 3: DROP TABLE 시 OOS 파일 회수 (CBRD-26608)

```
xheap_destroy()
├─ heap header 에서 OOS VFID 확인
├─ VFID 가 비어있지 않으면 oos_file_destroy() 호출
│   └─ file_destroy() -> 페이지 반환 + WAL 로깅
└─ heap 파일 삭제 (기존 경로)
```

### Story 4: Vacuum 과 OOS 연동 (CBRD-26592)

```
vacuum_heap_record()
├─ heap_recdes_contains_oos() -> OOS 플래그 확인
├─ heap_recdes_get_oos_oids() -> OOS OID 목록 추출
├─ REC_HOME + OOS: sysop 경로 (다중 페이지 원자적 처리)
│   └─ sysop_start -> vacuum_slot -> log -> oos_delete -> sysop_commit
└─ REC_RELOCATION + OOS: 기존 sysop 안에서 oos_delete 호출
```

> `REC_HOME` = heap 레코드가 단일 페이지에 fit 한 경우의 타입. `REC_RELOCATION` = heap 레코드가 너무 커서 다른 페이지로 이동되었음을 나타내는 forwarding pointer 타입.

### 보조 태스크

| 태스크 | 내용 |
|--------|------|
| `oos_delete` (CBRD-26609, 완료) | `spage_delete` 기반 물리적 삭제 + REDO 로깅 |
| OOS OID 추출 API (CBRD-26537, 완료) | `heap_recdes_get_oos_oids()` — classrepr 없이 RECDES 만으로 추출 |
| OOS 길이 인라인 (CBRD-26630, 완료) | 16B 인라인 포맷 `[OOS OID(8B) + length(8B)]` |
| 에러 핸들링 (CBRD-26637, 완료) | `er_set` + `ASSERT_ERROR` 통합 |

---

## Acceptance Criteria

- [x] `oos_delete` 로 OOS 레코드 물리적 삭제 (UPDATE/DELETE 경로)
- [x] `heap_recdes_get_oos_oids` 로 classrepr 없이 OOS OID 추출
- [x] OOS 인라인 포맷 16B (`OOS OID + length`) 로 불필요한 I/O 제거
- [x] 에러 핸들링을 `er_set` / `ASSERT_ERROR` 로 통합
- [x] In-page compaction: `spage_insert` 내부 자동 처리 확인 (별도 구현 불필요)
- [ ] 3-Tier Bestspace 로 페이지 공간 재활용 (진행 중)
- [ ] DROP TABLE 시 OOS 파일 회수 (진행 중)
- [ ] Vacuum 이 heap record 정리 시 OOS 레코드 함께 삭제
- [ ] 동일 워크로드에서 OOS 페이지 할당 수가 M1 대비 감소 확인
- [ ] Vacuum 중 crash 후 recovery 거쳐도 OOS 정합성 유지
- [ ] 개발자 SQL / Shell 테스트 작성 및 통과
- [ ] 단위 테스트 커버리지 확대
- [ ] CI 파이프라인 (check, test, build) 전체 통과
- [ ] develop 브랜치에 머지 완료

## Definition of done

- [ ] 위 Acceptance Criteria 전 항목 통과
- [ ] QA 매뉴얼 테스트 결과 분석 종료 (CBRD-26660)
- [ ] develop 브랜치 머지 PR 승인 및 머지 완료

---

## Scope 외 (M3 이후)

| 항목 | 사유 |
|------|------|
| Across-page compaction | 성능 최적화 영역 |
| UPDATE 시 OOS OID 재사용 | 값 비교 로직 + 불변식 변경 필요 |
| PEEK 모드 지원 | 성능 최적화, 우선순위 낮음 |
| OOS 값 압축 (compression) | M1/M2 범위 외 |

---

## Remarks

### 리스크 및 대응

| 리스크 | 대응 |
|--------|------|
| Vacuum 연동 방식에 따른 성능 영향 | 방식 A(동기 `oos_delete`) 채택 — 단순, 구현 비용 낮음. 성능 regression 측정 후 판단 |
| Best Page 정책 변경 시 기존 OOS 파일 호환성 | bestspace 정보는 런타임 메모리에서만 관리, 하위 호환 유지 |
| In-page compaction 시 lock 경합 | 별도 구현 불필요로 판정 — `spage_insert` 내부 자동 처리 |
| 한 레코드 읽기에 여러 OOS page fix 시 데드락 | ordered fix 정책 검토 필요 (pageid 순서로 fix) |

### 선행 조건

- OOS Milestone 1 구현 완료 및 기능 검증 통과 (CBRD-26584, Resolved)

### 이슈 맵

```
CBRD-26357 [EPIC] OOS
├── CBRD-26198 [Survey] (완료)
├── CBRD-26517 [TODO]
├── CBRD-26584 [M1] (완료)
└── CBRD-26583 [M2] <- 이 이슈
    ├── CBRD-26582 M1 공유 발표 (완료)
    ├── CBRD-26537 OOS OID 추출 API (완료)
    ├── CBRD-26609 oos_delete 구현 (완료)
    ├── CBRD-26630 OOS 길이 인라인 (완료)
    ├── CBRD-26637 에러 핸들링 리팩터링 (완료)
    ├── CBRD-26536 In-page compaction 분석 (완료, 별도 구현 불필요)
    ├── CBRD-26658 3-Tier Bestspace (진행 중)
    ├── CBRD-26608 Drop Table OOS 회수 (진행 중)
    ├── CBRD-26592 Vacuum 과 OOS 연동 (대기)
    ├── CBRD-26550 REC_OOS 타입 도입 (대기)
    ├── CBRD-26383 spage_insert_multiple (대기)
    ├── CBRD-26659 개발자 테스트 (대기)
    ├── CBRD-26660 매뉴얼 테스트 분석 (대기)
    └── CBRD-26665 unit_tests 개선 (대기)
```

Legend: (완료) | (진행 중) | (대기)
