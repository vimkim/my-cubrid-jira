# [OOS] [EPIC] [M2] OOS Milestone 2 — 운영 품질 확보 및 develop 머지

> **바로가기**
> - 탑 레벨: [CBRD-26357](http://jira.cubrid.org/browse/CBRD-26357)
> - M1: [CBRD-26584](http://jira.cubrid.org/browse/CBRD-26584) | M2: [CBRD-26583](http://jira.cubrid.org/browse/CBRD-26583)

| Status | Assignee | Target | Branch |
|---|---|---|---|
| Develop | Daehyun Kim | guava | `feat/oos` |

---

## Description

### 배경

OOS Milestone 1에서 기본 CRUD(insert/read/update/delete), WAL 로깅, recovery, HA replication을 구현하여 핵심 기능이 동작하는 상태이다. 그러나 M1은 "먼저 정확하게 동작하는 것"에 집중했기 때문에 운영 환경에서 필수적인 기능이 빠져 있다.

### 목적

M1에서 구현하지 못한 필수 보완 사항을 해결하고, **develop 브랜치에 머지 가능한 품질** 로 만든다.

1. OOS 파일/페이지 공간 회수 경로 확보 (drop table, vacuum 연동)
2. 3-Tier Bestspace 정책으로 hotspot/fragmentation 완화
3. `oos_delete` 구현으로 UPDATE/DELETE 시 OOS 물리적 삭제
4. 에러 핸들링을 CUBRID 표준 시스템(`er_set`, `ASSERT_ERROR`)으로 통합
5. develop 브랜치 머지 및 CI 통과

---

## M1 현황 (AS-IS)

| 영역 | 현재 상태 | 문제점 |
|------|----------|--------|
| Best Page | 마지막 삽입 페이지 1개만 기억 | hotspot 집중, 다른 페이지 빈 공간 낭비 |
| Drop Table | OOS 페이지 미회수 | DROP TABLE 해도 OOS 파일 공간 반환 안 됨 |
| Vacuum 연동 | 미구현 | DELETE된 record의 OOS 레코드가 영구히 잔존 |
| OOS 삭제 | `oos_delete` 미구현 | UPDATE 시 이전 OOS가 영구히 잔존 |
| 에러 핸들링 | `oos_error` 매크로 (stderr, debug only) | release 빌드에서 비활성, `er_set` 미사용 |
| OOS 길이 | OOS OID(8B)만 인라인 저장 | `oos_get_length()` 호출 시 추가 I/O 발생 |

---

## Sub-task 진행 현황

### 완료 (Resolved)

| JIRA | 제목 | 내용 |
|------|------|------|
| [CBRD-26582](http://jira.cubrid.org/browse/CBRD-26582) | M1 진행 상황 및 M2 설계 공유 | 개발 2팀 대상 발표 (3/5) |
| [CBRD-26537](http://jira.cubrid.org/browse/CBRD-26537) | `heap_recdes_get_oos_oids` API 구현 | classrepr 없이 RECDES만으로 OOS OID 추출. VOT에 LAST_ELEMENT 정보 추가 |
| [CBRD-26609](http://jira.cubrid.org/browse/CBRD-26609) | `oos_delete` 구현 | `spage_delete` 로 OOS 슬롯 물리적 삭제, WAL 로깅 포함 |
| [CBRD-26630](http://jira.cubrid.org/browse/CBRD-26630) | OOS 길이 정보 인라인 저장 | OOS OID(8B) + length(8B) = 16B 인라인 포맷으로 변경. 불필요한 I/O 제거 |
| [CBRD-26637](http://jira.cubrid.org/browse/CBRD-26637) | 에러 핸들링 리팩터링 | `oos_error` → `er_set` + `ASSERT_ERROR` 로 CUBRID 표준 에러 시스템 통합 |

### 진행 중 (Develop)

| JIRA | 제목 | 내용 |
|------|------|------|
| [CBRD-26658](http://jira.cubrid.org/browse/CBRD-26658) | 3-Tier Bestspace 메커니즘 | 글로벌 해시 캐시 → best[10] → sync scan 3단계 탐색. 삭제 공간 즉시 재활용 |
| [CBRD-26608](http://jira.cubrid.org/browse/CBRD-26608) | Drop Table 시 OOS 회수 | `oos_file_destroy` 구현. `xheap_destroy` 에서 OOS VFID 확인 후 삭제 |

### 대기 (Confirmed / Open)

| JIRA | 제목 | 담당 | 내용 |
|------|------|------|------|
| [CBRD-26592](http://jira.cubrid.org/browse/CBRD-26592) | Vacuum ↔ OOS 연동 | 김희수 | vacuum이 heap record 정리 시 `oos_delete` 호출. sysop 원자적 처리 |
| [CBRD-26383](http://jira.cubrid.org/browse/CBRD-26383) | `spage_insert_multiple` API | 김대현 | 여러 데이터를 하나의 page offset에 동시 저장하는 API |
| [CBRD-26550](http://jira.cubrid.org/browse/CBRD-26550) | `REC_OOS` 타입 도입 | 김대현 | vacuum이 OOS record와 heap record를 구분하기 위한 새 레코드 타입 |
| [CBRD-26536](http://jira.cubrid.org/browse/CBRD-26536) | In-page Compaction 분석 | 김대현 | **결론: 별도 구현 불필요.** `spage_insert` 내부에서 자동 compact 수행 확인 |
| [CBRD-26659](http://jira.cubrid.org/browse/CBRD-26659) | 개발자 SQL/Shell 테스트 생성 | 김대현 | OOS 시나리오 테스트 작성 |
| [CBRD-26660](http://jira.cubrid.org/browse/CBRD-26660) | 매뉴얼 테스트 결과 분석 | 김대현 | QA 실패 케이스 분석 및 이슈화 |
| [CBRD-26665](http://jira.cubrid.org/browse/CBRD-26665) | unit_tests/oos 추가 및 개선 | 김대현 | OOS 단위 테스트 커버리지 확대 |

---

## Implementation

### Story 1: 3-Tier Bestspace 정책 (CBRD-26658)

단일 페이지 캐시 → 3-tier bestspace로 교체하여 공간 재활용률을 극대화한다.

```
oos_find_best_page()
├─ Tier 1: 글로벌 해시 캐시 (VFID → entry)
├─ Tier 2: 헤더 페이지 best[10] 순환 배열
├─ Tier 3: OOS 파일 페이지 스캔 (최대 20%, 100개 제한)
└─ Fallback: 신규 페이지 할당
```

### Story 2: In-page Compaction (CBRD-26536)

분석 결과, `spage_insert` 가 `cont_free < needed && total_free >= needed` 조건에서 자동으로 `spage_compact` 를 호출하므로 **별도 구현이 불필요** 하다.

### Story 3: DROP TABLE 시 OOS 파일 회수 (CBRD-26608)

```
xheap_destroy()
├─ heap header에서 OOS VFID 확인
├─ VFID_ISNULL이 아니면 oos_file_destroy() 호출
│   └─ file_destroy() → 페이지 반환 + WAL 로깅
└─ heap 파일 삭제 (기존 경로)
```

### Story 4: Vacuum ↔ OOS 연동 (CBRD-26592)

```
vacuum_heap_record()
├─ heap_recdes_contains_oos() → OOS 플래그 확인
├─ heap_recdes_get_oos_oids() → OOS OID 목록 추출
├─ REC_HOME + OOS: sysop 경로 (다중 페이지 원자적 처리)
│   └─ sysop_start → vacuum_slot → log → oos_delete → sysop_commit
└─ REC_RELOCATION + OOS: 기존 sysop 내에서 oos_delete 호출
```

### 보조 태스크

| 태스크 | 내용 |
|--------|------|
| `oos_delete` (CBRD-26609, 완료) | `spage_delete` 기반 물리적 삭제 + REDO 로깅 |
| OOS OID 추출 API (CBRD-26537, 완료) | `heap_recdes_get_oos_oids()` — classrepr 없이 RECDES만으로 추출 |
| OOS 길이 인라인 (CBRD-26630, 완료) | 16B 인라인 포맷 `[OOS OID(8B) + length(8B)]` |
| 에러 핸들링 (CBRD-26637, 완료) | `er_set` + `ASSERT_ERROR` 통합 |

---

## Acceptance Criteria

- [x] `oos_delete` 로 OOS 레코드 물리적 삭제 (UPDATE/DELETE 경로)
- [x] `heap_recdes_get_oos_oids` 로 classrepr 없이 OOS OID 추출
- [x] OOS 인라인 포맷 16B (`OOS OID + length`) 로 불필요한 I/O 제거
- [x] 에러 핸들링을 `er_set` / `ASSERT_ERROR` 로 통합
- [x] In-page compaction: `spage_insert` 내부 자동 처리 확인 (별도 구현 불필요)
- [ ] 3-Tier Bestspace로 페이지 공간 재활용 (진행 중)
- [ ] DROP TABLE 시 OOS 파일 회수 (진행 중)
- [ ] Vacuum이 heap record 정리 시 OOS 레코드 함께 삭제
- [ ] 동일 워크로드에서 OOS 페이지 할당 수가 M1 대비 감소 확인
- [ ] Vacuum 중 crash → recovery 후 OOS 정합성 유지
- [ ] 개발자 SQL/Shell 테스트 작성 및 통과
- [ ] 단위 테스트 커버리지 확대
- [ ] CI 파이프라인 (check, test, build) 전체 통과
- [ ] develop 브랜치에 머지 완료

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
| Vacuum 연동 방식에 따른 성능 영향 | 방식 A(동기적 `oos_delete`) 채택 — 단순, 구현 비용 낮음. 성능 regression 측정 후 판단 |
| Best Page 정책 변경 시 기존 OOS 파일 호환성 | bestspace 정보는 런타임 메모리에서 관리, 하위 호환 유지 |
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
└── CBRD-26583 [M2] ← 이 이슈
    ├── CBRD-26582 M1 공유 발표 (완료)
    ├── CBRD-26537 OOS OID 추출 API (완료)
    ├── CBRD-26609 oos_delete 구현 (완료)
    ├── CBRD-26630 OOS 길이 인라인 (완료)
    ├── CBRD-26637 에러 핸들링 리팩터링 (완료)
    ├── CBRD-26536 In-page compaction 분석 (완료, 별도 구현 불필요)
    ├── CBRD-26658 3-Tier Bestspace (진행 중)
    ├── CBRD-26608 Drop Table OOS 회수 (진행 중)
    ├── CBRD-26592 Vacuum ↔ OOS 연동 (대기)
    ├── CBRD-26550 REC_OOS 타입 도입 (대기)
    ├── CBRD-26383 spage_insert_multiple (대기)
    ├── CBRD-26659 개발자 테스트 (대기)
    ├── CBRD-26660 매뉴얼 테스트 분석 (대기)
    └── CBRD-26665 unit_tests 개선 (대기)
```

Legend: (완료) | (진행 중) | (대기)
