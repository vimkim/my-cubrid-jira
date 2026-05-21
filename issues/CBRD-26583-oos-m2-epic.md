# [OOS] [EPIC] [M2] OOS Milestone 2 — 운영 품질 확보 및 develop 머지

> **바로가기**
> - 탑 레벨 EPIC (OOS 전체): [CBRD-26357](http://jira.cubrid.org/browse/CBRD-26357)
> - M1 (완료): [CBRD-26584](http://jira.cubrid.org/browse/CBRD-26584)
> - M2 (이 이슈): [CBRD-26583](http://jira.cubrid.org/browse/CBRD-26583)

| 상태 | Assignee | Target | 소스 브랜치 | 머지 대상 |
|---|---|---|---|---|
| 구현 중 | Daehyun Kim | guava | `feat/oos` | `develop` |

## 한 줄 요약 (먼저 읽기)

OOS (Out-of-row Storage — heap 의 큰 가변 컬럼을 외부 OOS 파일로 분리해 저장하는 구조) M1 에서 빠진 운영 필수 기능을 채워 `feat/oos` 브랜치를 develop 으로 머지 가능한 품질까지 끌어올린다. 이 에픽 자체에는 코드 변경이 없으며, 13 개 구현 sub-task 가 실제 구현을 분담한다.

---

## Issue Triage

**이슈 수행 목적**: OOS M1 에서 의도적으로 미룬 운영 필수 기능을 모두 채워 `feat/oos` 브랜치를 develop 으로 머지 가능한 상태로 만든다.

**이슈 수행 이유**:

- **현재 동작 / 배경**:
  - (a) `xheap_destroy` 가 heap 파일만 회수하고 OOS 파일을 방치해, DROP TABLE 후에도 OOS 페이지가 영구히 남는다.
  - (b) `vacuum_heap_record` 가 heap record 를 정리할 때 `heap_recdes_get_oos_oids` 를 호출하지 않아, DELETE 된 heap record 에 매달린 OOS 레코드가 영구 잔존한다.
  - (c) UPDATE/DELETE 경로에서 `oos_delete` 가 없어 이전 OOS 페이로드가 회수되지 않는다.
- **영향**: 설계 의도 훼손 — 동일 테이블에 INSERT/UPDATE/DROP 을 반복하면 회수되지 못한 OOS 페이지가 단조 증가한다.

**이슈 수행 방안**:

- 공간 회수: `xheap_destroy` 에서 OOS VFID (volume file identifier — 영구 파일 식별자) 를 확인하고 `oos_file_destroy` 로 회수한다 (CBRD-26608).
- Vacuum 연동: `vacuum_heap_record` 에서 `oos_delete` 를 sysop (top system operation — 다중 페이지 변경을 원자 단위로 묶는 단위) 안에서 호출한다 (CBRD-26592).
- Bestspace 다층화: 3-Tier Bestspace 정책 (글로벌 해시 / 헤더 배열 / 동기 스캔) 으로 단일 페이지 캐시를 교체한다 (CBRD-26658).
- 테스트 및 CI: 개발자 SQL/Shell 테스트 (CBRD-26659), QA 매뉴얼 테스트 분석 (CBRD-26660), unit_tests/oos 보강 (CBRD-26665) 을 모두 처리하고 CI 전 항목 통과 후 develop 머지한다.
- In-page compaction: `spage_insert` 내부 자동 처리로 별도 구현 불필요 (CBRD-26536, 결론 확정).

---

## AI-Generated Context

> 아래 내용은 AI 가 코드/맥락을 분석해 작성한 상세 자료입니다. 빠른 triage에는 위 **Issue Triage** 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하시면 됩니다.

### Summary

- **문제 / 목적**: M1 이 의도적으로 미룬 공간 회수 / vacuum 연동 / hotspot 완화 / 이전 OOS 잔존 네 가지 공백을 메워 develop 머지 가능 품질에 도달한다.
- **원인 / 배경**: M1 은 "정확하게 동작" 단계라 운영 보조 경로(파일 회수, 매달린 OOS 정리, bestspace 다중화)가 후순위로 빠졌다.
- **제안 / 변경**: 본 에픽은 직접 코드 변경 없이 13 개 구현 sub-task 로 분담 — 5 건 완료, 2 건 진행 중, 6 건 대기.
- **영향 범위**: heap, OOS, vacuum, log recovery, 페이지 공간 정책. 사용자 SQL 시맨틱과 wire protocol 은 그대로다.

---

## Description

### 배경

M1 (CBRD-26584) 에서 OOS 의 기본 CRUD (insert/read/update/delete), WAL (Write-Ahead Logging — 디스크 페이지를 바꾸기 전에 변경 내용을 로그에 먼저 적는 방식) 로깅, recovery, HA replication 까지 끝내 핵심 동작 자체는 검증됐다. M1 은 "먼저 정확하게 동작"에 집중한 단계라, 운영 환경이 요구하는 보조 경로를 의도적으로 비워뒀다.

### 목적

현재 `feat/oos` 가 develop 에 머지 불가능한 이유는 세 가지다. 첫째, vacuum 이 OOS 와 연동되지 않아 DELETE/UPDATE 후 성숙한 죽은 OOS 레코드가 영구히 회수되지 않는다. 둘째, DROP TABLE 경로에서 OOS 파일을 회수하지 않아 테이블 삭제 후에도 OOS 페이지가 working set 을 계속 차지한다. 셋째, 개발자 SQL/Shell 테스트와 unit_tests/oos 가 없어 CI sign-off 가 불가능하다. M2 는 이 세 공백을 채우고 bestspace 를 다층화해 hotspot 을 완화한 뒤 develop 머지를 달성한다.

구체적으로는 다음 네 묶음을 처리한다.

1. OOS 파일 / 페이지 공간 회수 경로를 확보하려고 DROP TABLE 과 vacuum 연동을 구현한다.
2. 3-Tier Bestspace 정책으로 hotspot 과 fragmentation (페이지 안에서 빈 조각이 흩어져 쓸 수 없게 된 상태) 을 완화한다.
3. `oos_delete` 로 UPDATE / DELETE 시 OOS 를 물리적으로 삭제한다.
4. develop 브랜치 머지와 CI 전 통과를 달성한다.

---

## M1 현황 (AS-IS)

| 영역 | 현재 상태 | 문제점 |
|------|----------|--------|
| Best Page 캐시 | 마지막 삽입 페이지 1개만 기억 | hotspot 집중, 다른 페이지 빈 공간 낭비 |
| Drop Table | `xheap_destroy` 가 OOS 파일 미회수 | DROP TABLE 후 OOS 페이지가 영구히 남음 |
| Vacuum 연동 | 미구현 | DELETE 된 heap record 에 매달린 OOS 가 영구 잔존 |
| OOS 삭제 | `oos_delete` 미구현 | UPDATE 경로에서 이전 OOS 가 영구 잔존 |
| 에러 핸들링 | `oos_error` 매크로 (stderr, debug 빌드만) | release 빌드에서 비활성, `er_set` 미사용 |
| OOS 길이 | OOS OID(8B) 만 인라인 저장 | `oos_get_length()` 호출 시 추가 I/O |

---

## Sub-task 진행 현황

### 완료 (Resolved)

| JIRA | 제목 | 내용 |
|------|------|------|
| [CBRD-26537](http://jira.cubrid.org/browse/CBRD-26537) | `heap_recdes_get_oos_oids` API 구현 | classrepr (class representation — 컬럼 메타데이터) 없이 RECDES (record descriptor — 레코드 디스크립터) 만으로 OOS OID 추출. VOT 에 LAST_ELEMENT 정보 추가 |
| [CBRD-26609](http://jira.cubrid.org/browse/CBRD-26609) | `oos_delete` 구현 | `spage_delete` 로 OOS 슬롯 물리적 삭제, WAL 로깅 포함 |
| [CBRD-26630](http://jira.cubrid.org/browse/CBRD-26630) | OOS 길이 정보 인라인 저장 | 인라인 포맷을 16B (`OOS OID + length`) 로 변경해 추가 I/O 제거 |
| [CBRD-26637](http://jira.cubrid.org/browse/CBRD-26637) | 에러 핸들링 리팩터링 | `oos_error` 를 `er_set` + `ASSERT_ERROR` 로 치환 |
| [CBRD-26536](http://jira.cubrid.org/browse/CBRD-26536) | In-page Compaction 분석 | 결론: 별도 구현 불필요 — `spage_insert` 내부 자동 compact 확인 |

### 진행 중 (In Progress)

| JIRA | 제목 | 내용 |
|------|------|------|
| [CBRD-26658](http://jira.cubrid.org/browse/CBRD-26658) | 3-Tier Bestspace 메커니즘 | 글로벌 해시 캐시, 헤더 best[10] 배열, 동기 스캔 3단계 탐색. 삭제 공간 즉시 재활용 포함 |
| [CBRD-26608](http://jira.cubrid.org/browse/CBRD-26608) | DROP TABLE 시 OOS 회수 | `oos_file_destroy` 구현. `xheap_destroy` 에서 OOS VFID 확인 후 삭제 |

### 대기 (Pending)

| JIRA | 제목 | 담당 | 내용 |
|------|------|------|------|
| [CBRD-26592](http://jira.cubrid.org/browse/CBRD-26592) | Vacuum 과 OOS 연동 | 김희수 | vacuum 이 heap record 정리 시 `oos_delete` 호출. sysop 으로 원자적 처리 |
| [CBRD-26383](http://jira.cubrid.org/browse/CBRD-26383) | `spage_insert_multiple` API | 김대현 | 여러 데이터를 하나의 page offset 에 동시 저장하는 API |
| [CBRD-26550](http://jira.cubrid.org/browse/CBRD-26550) | `REC_OOS` 타입 도입 | 김대현 | vacuum 이 OOS record 와 heap record 를 구분하려고 추가하는 새 레코드 타입 |
| [CBRD-26659](http://jira.cubrid.org/browse/CBRD-26659) | 개발자 SQL/Shell 테스트 생성 | 김대현 | OOS 시나리오 테스트 작성 |
| [CBRD-26660](http://jira.cubrid.org/browse/CBRD-26660) | 매뉴얼 테스트 결과 분석 | 김대현 | QA 실패 케이스 분석 및 이슈화 |
| [CBRD-26665](http://jira.cubrid.org/browse/CBRD-26665) | unit_tests/oos 추가 및 개선 | 김대현 | OOS 단위 테스트 커버리지 확대 |

처리 순서 (직렬): CBRD-26659 -> CBRD-26665 -> CBRD-26550 -> CBRD-26383 -> CBRD-26660. CBRD-26592 는 김희수 완료 후 김대현 의 CBRD-26660 분석에 입력으로 사용된다.

---

## Specification Changes

사용자 SQL 시맨틱, 시스템 카탈로그, wire protocol 은 모두 변경 없음.

내부 디스크 포맷 변경은 두 가지로, 둘 다 M1 단계에서 이미 합의된 사항이다.

- 인라인 OOS 토큰: 8B (OOS OID 만) -> 16B (`OOS OID + length`). CBRD-26630 이 feat/oos 에 이미 머지됐다. develop 머지 전 시점이므로 마이그레이션 부담이 없고 신규 포맷만 지원한다. feat/oos 를 기반으로 작업한 개발용 DB 는 재초기화가 필요하다.
- (예정) `REC_OOS` 새 레코드 타입: vacuum 이 OOS 레코드를 heap 레코드와 구분하려고 도입한다 (CBRD-26550). `REC_OOS` 는 feat/oos 가 develop 에 머지되기 전에만 사용되므로, 도입 이전 페이지를 읽을 일이 없다. 기존 페이지 호환은 고려하지 않으며, CBRD-26550 은 내부 구현 전략만 결정한다. feat/oos 기반 개발용 DB 는 재초기화가 필요하다 (위와 동일).

---

## Implementation

### Story 1: 3-Tier Bestspace 정책 (CBRD-26658)

단일 페이지 캐시를 3-Tier bestspace 로 교체해 공간 재활용률을 올리고 삭제 공간을 즉시 재활용할 수 있게 한다.

```
oos_find_best_page()
+-- Tier 1: 글로벌 해시 캐시 (VFID -> entry)
+-- Tier 2: 헤더 페이지 best[10] 순환 배열
+-- Tier 3: OOS 파일 페이지 스캔 (전체의 최대 20% 또는 100개 페이지 중 작은 값)
+-- Fallback: 신규 페이지 할당
```

### Story 2: In-page Compaction (CBRD-26536)

`spage_insert` 가 `cont_free < needed && total_free >= needed` 조건에서 자동으로 `spage_compact` 를 호출하므로 별도 구현은 두지 않는다.

### Story 3: DROP TABLE 시 OOS 파일 회수 (CBRD-26608)

```
xheap_destroy()
+-- heap header 에서 OOS VFID 확인
+-- VFID 가 비어있지 않으면 oos_file_destroy() 호출
|   +-- file_destroy() -> 페이지 반환 + WAL 로깅
+-- heap 파일 삭제 (기존 경로)
```

### Story 4: Vacuum 과 OOS 연동 (CBRD-26592)

```
vacuum_heap_record()
+-- heap_recdes_contains_oos() -> OOS 플래그 확인
+-- heap_recdes_get_oos_oids() -> OOS OID 목록 추출
+-- REC_HOME + OOS: sysop 신규 생성 후 oos_delete 호출
|   +-- sysop_start -> vacuum_slot -> log -> oos_delete -> sysop_commit
+-- REC_RELOCATION + OOS: vacuum 이 이미 sysop 안에서 forwarding pointer 를 처리 중이므로 그 sysop 안에서 oos_delete 를 추가 호출
```

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
- [ ] 개발자 SQL / Shell 테스트 작성 및 통과 (CBRD-26659 deliverable)
- [ ] Crash-recovery 후 OOS 정합성을 CBRD-26659 / CBRD-26665 단위 테스트로 검증

CBRD-26582 는 개발팀 내부 공유 발표이며 구현 A/C 에 포함하지 않는다.

## Definition of done

- [ ] 위 Acceptance Criteria 전 항목 통과
- [ ] CI 파이프라인 (check, test, build) 전체 통과
- [ ] develop 브랜치에 머지 완료
- [ ] QA 매뉴얼 테스트 결과 분석 종료 (CBRD-26660)
- [ ] 버전 릴리스 노트 초안에 OOS M2 항목 추가
- [ ] M3 킥오프 트리거 — Scope 외 항목에 대한 JIRA stub 일괄 생성

---

## Scope 외 (M3 이후)

JIRA 미생성 — M3 킥오프 시 일괄 생성.

| 항목 | 사유 |
|------|------|
| Across-page compaction | 성능 최적화 영역 |
| UPDATE 시 OOS OID 재사용 | 값 비교 로직과 불변식 변경이 함께 필요 |
| PEEK 모드 지원 | 성능 최적화, 우선순위 낮음 |
| OOS 값 압축 (compression) | M1/M2 범위 외 |
| 한 레코드 읽기에 여러 OOS page fix 시 데드락 대응 | pageid 순서 ordered fix 정책이 필요하나 현재 담당 sub-task 없음 — M3 에서 JIRA 생성 |

---

## Remarks

### 리스크 및 대응

| 리스크 | 대응 |
|--------|------|
| Vacuum 연동 방식에 따른 성능 영향 | vacuum sysop 안에서 동기 `oos_delete` 호출을 채택. 비동기 큐 방식은 별도 인프라가 필요해 후순위로 미룬다. regression 측정 결과를 보고 조정 |
| Best Page 정책 변경 시 기존 OOS 파일 호환성 | bestspace 정보는 런타임 메모리에서만 관리하므로 하위 호환은 그대로 유지 |
| In-page compaction 시 lock 경합 | 별도 구현 불필요로 판정 — `spage_insert` 내부 자동 처리에 위임 |

### 선행 조건

- OOS Milestone 1 구현 완료 및 기능 검증 통과 (CBRD-26584, Resolved)

### 참고

- CBRD-26582: M1 진행 상황 및 M2 설계 공유 (개발 2팀 대상 발표, 3/5) — 구현 sub-task 가 아니라 커뮤니케이션 이벤트.

### 이슈 맵

본 에픽은 CBRD-26357 (탑 레벨 EPIC, OOS 전체) 의 M2 마일스톤이며, 13 개 구현 sub-task 로 분담된다 (위 Sub-task 진행 현황 참조). 형제 에픽으로 CBRD-26584 (M1, 완료) 가 있으며, CBRD-26517 은 M3 이후 작업이다.
