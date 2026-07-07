# [OOS] [M2] [Survey] OOS 발표자료 2종(PPT A/B) 작성

본 이슈의 산출물은 발표자료 2종이어야 한다.

| 산출물 | 대상 / 용도 |
|--------|-------------|
| PPT A | 개발팀 프로젝트 보고자료: 김박사님(데이터베이스 전문가) 대상 |
| PPT B | 사내 워크샵 발표자료 |

## Issue Triage

**이슈 수행 목적**: OOS 소개 발표자료를 PPT A 와 PPT B 두 갈래로 준비한다. 2026-07-13 월요일 PPT A 는 김박사님(데이터베이스 전문가) 대상 개발팀 프로젝트 보고자료로 기술 검토와 설계 피드백에 맞추고, 2026-07-17 금요일 PPT B 는 사내 워크샵 발표자료로 전사 구성원이 OOS 의 필요성과 효과를 이해하도록 맞춘다.

**이슈 수행 이유**:

| 구분 | 내용 |
|------|------|
| **AS-IS (현재 동작 / 배경)** | OOS M2 설명 재료는 CBRD-26583, CBRD-26582, `feat/oos` 구현 맥락, OOS 문서에 흩어져 있다. 현재 스펙은 `DB_PAGESIZE/4` record gate, `OR_OOS_INLINE_SIZE`(16B) column floor, largest-first demotion, 16B `OOS OID`, vacuum 연동, 3-Tier bestspace 를 포함한다. |
| **TO-BE (목표 상태 / 기대 동작)** | 같은 핵심 메시지를 공유하되, PPT A 에서는 설계 선택지와 불변식까지 검토하고, PPT B 에서는 "왜 필요한가 -> 어떻게 동작하는가 -> 어떤 효과가 있는가" 흐름으로 설명한다. |
| **영향** | 기술 부채 - PPT A/PPT B 메시지가 분리되지 않으면 기술 리뷰에서는 근거가 부족하고, 전사 공유에서는 구현 세부가 과해져 OOS 도입 의미가 흐려진다. |

**이슈 수행 방안**: 사용자 인용: "maybe html + css + svg". PPT A 와 PPT B 는 HTML/CSS/SVG 기반 single source 후보로 설계하고, 같은 코어 스토리에서 대상별 흐름을 분기한다. 최종 export 형식(PPTX 변환, HTML 슬라이드, PDF export)과 발표 시간은 `TBD - 합의 미확인` 으로 둔다.

---

## AI-Generated Context

> 아래는 AI 가 코드/맥락을 분석해 작성한 상세 자료다. 빠른 triage 에는 위 Issue Triage 블록만으로 충분하며, 본문은 구현/리뷰 단계에서 참고하면 된다.

### Summary

- **변경 범위 / 영향**: 코드 변경 없음. 산출물은 PPT A/PPT B 발표자료 계획, 슬라이드 구성, 시각화 방향, 리허설 일정이다. 입력 자료는 CBRD-27014, CBRD-26583, CBRD-26582, `/home/vimkim/gh/cubrid-oos-context/OOS-CONTEXT.md`, `feat/oos` 현재 스펙이다.

---

## Description

CBRD-27014 는 OOS (Out-of-row Overflow Storage - heap 의 큰 가변 컬럼을 heap file 과 1:1 로 매핑되는 외부 OOS file 에 분리해 저장하는 구조) 를 PPT A 와 PPT B 로 나누어 소개하는 발표자료 작성 태스크다. 같은 기능을 다루지만 두 발표자료의 성공 조건은 다르다.

PPT A 는 김박사님(데이터베이스 전문가) 대상 개발팀 프로젝트 보고자료다. OOS 저장 구조에 대한 설계 판단을 검증받아야 하므로, "무엇을 만들었는가" 보다 "왜 이 저장 구조가 CUBRID 에 맞는가" 와 "어떤 불변식을 지켜야 하는가" 를 앞에 둔다. record gate, OOS OID 포맷, MVCC undo, WAL, vacuum, bestspace, OOS+bigone rejection 같은 주제가 중심이 된다.

PPT B 는 사내 워크샵 발표자료다. 전사 구성원이 OOS 의 제품적 의미를 이해해야 하므로, heap record 전체를 읽던 구조에서 큰 가변 컬럼만 OOS file 로 분리하면 작은 컬럼 조회가 불필요한 큰 payload I/O 를 피할 수 있다는 점을 먼저 보여준다. 반대로 큰 컬럼 자체를 읽는 경우에는 `oos_read` 가 추가되므로, 효과는 workload 의 access pattern 과 함께 설명한다. 구현 세부는 필요한 만큼만 남기고, 전후 그림과 예시 SQL, 현재 진행 상태, 기대 효과를 중심으로 구성한다.

> 사용자 메시지의 PPT B 워크샵 날짜는 "July 17 Thursday" 였으나, 2026-07-17 은 금요일이다. 일정 표기에는 `2026-07-17 금요일` 을 사용한다.

## Specification Changes

N/A. 본 이슈는 발표자료 작성 계획이며 CUBRID SQL 스펙, 디스크 포맷, wire protocol 변경을 포함하지 않는다.

발표자료에서 설명할 OOS 기준은 현재 `feat/oos` 기준으로 고정한다.

| 항목 | 발표에서 사용할 기준 |
|------|----------------------|
| OOS demotion trigger | record size > `DB_PAGESIZE/4` |
| Column eligibility | variable column size > `OR_OOS_INLINE_SIZE`(16B) |
| Demotion order | largest-first, record 가 gate 이하가 되면 중단 |
| Inline token | 16B `OOS OID`(volid, pageid, slotid, full_length) |
| File mapping | heap file 과 OOS file 의 1:1 매핑 |
| OOS + bigone | demotion 후에도 bigone 이면 `ER_HEAP_OOS_OVERPASS_MAXOBJ_SIZE` 로 거부 |
| Compression | OOS layer compression 없음. 향후 type serialization layer 방향으로 검토 |

## Implementation

### 발표 전략

| 산출물 | 핵심 질문 | 말해야 할 것 | 덜어낼 것 |
|--------|-----------|--------------|-----------|
| PPT A - 개발팀 프로젝트 보고자료, 2026-07-13 월요일 | 이 설계가 DBMS 저장 구조로 타당한가 | 저장 단위, record format, MVCC/WAL/vacuum 불변식, PG TOAST-style largest-first 정책, 남은 리스크 | 전사 공유용 홍보 문구, 과한 진행 경과 |
| PPT B - 사내 워크샵 발표자료, 2026-07-17 금요일 | OOS 가 왜 좋은가 | 큰 컬럼 분리 전후 그림, I/O 감소 직관, CUBRID 에서 바뀌는 사용자 경험, M2 진행 현황 | 함수명 중심 call chain, 미해결 내부 버그의 세부 재현 |

### 공통 코어 스토리

PPT A 와 PPT B 모두 같은 네 문장 위에서 출발한다.

1. CUBRID heap record 는 한 행의 데이터를 한 덩어리로 읽는 구조라, 작은 컬럼만 필요해도 큰 가변 컬럼 payload 가 함께 따라온다.
2. OOS 는 큰 가변 컬럼을 OOS file 로 분리하고 heap 에는 16B `OOS OID` 를 남겨, 필요할 때만 원본 값을 읽게 한다.
3. 현재 정책은 `DB_PAGESIZE/4` 를 넘는 record 에서 16B 보다 큰 variable column 을 큰 순서대로 OOS 로 보낸 뒤 record 가 gate 이하가 되면 멈춘다.
4. UPDATE, DELETE, rollback, crash recovery 에서 OOS record 의 생명주기는 MVCC/WAL/vacuum 과 같이 맞물려야 한다.

### PPT A 슬라이드 흐름

| 순서 | 제목 후보 | 내용 |
|------|-----------|------|
| 1 | OOS 문제 정의 | heap overflow 와 OOS 가 해결하는 문제를 구분한다. 전체 record overflow 가 아니라 column-level 분리 문제로 잡는다. |
| 2 | 현재 저장 모델 | heap record, VOT, MVCC header, variable area, OOS file 의 관계를 한 그림에 둔다. |
| 3 | Demotion 정책 | `DB_PAGESIZE/4`, `OR_OOS_INLINE_SIZE`(16B), largest-first, early stop 을 예시 record 로 설명한다. |
| 4 | Read path | record-level Expand 와 column-level Resolve 를 구분한다. raw recdes 소비 경로만 Expand 가 필요하다는 선택 기준을 제시한다. |
| 5 | UPDATE / DELETE 생명주기 | UPDATE 는 새 OOS OID 를 만들고, 옛 OOS OID 는 undo/MVCC 독자를 위해 vacuum 전까지 유지한다. |
| 6 | WAL / Recovery / Replication | OOS insert/delete 로그와 crash recovery, slave OOS OID 불일치 가능성, value equality 기준을 설명한다. |
| 7 | Vacuum 연동 | dead heap version 정리 시 OOS record 를 같이 삭제해야 하는 이유와 forward-walk 불변식을 설명한다. |
| 8 | Bestspace / 공간 재활용 | 3-Tier bestspace 가 단일 page hotspot 과 삭제 공간 재활용 문제를 어떻게 줄이는지 설명한다. |
| 9 | 주요 리스크와 질문 | CBRD-26950 slot reuse data loss, CBRD-26830 TDE plaintext leak, OOS page attribution 등 남은 질문을 기술 피드백 안건으로 둔다. |
| 10 | 피드백 요청 | 저장 단위, vacuum ownership, 관측 도구, future compression 위치에 대해 김박사님 의견을 요청한다. |

### PPT B 슬라이드 흐름

| 순서 | 제목 후보 | 내용 |
|------|-----------|------|
| 1 | 왜 OOS 인가 | 작은 컬럼 조회가 큰 payload I/O 를 끌고 오는 문제를 사용자 관점 그림으로 보여준다. |
| 2 | 한 장 그림 | AS-IS heap record 와 TO-BE heap record + OOS file 을 나란히 보여준다. |
| 3 | 간단한 예시 | `id`, `name`, `big_text`, `big_blob` record 를 사용해 OOS 전후 record 크기와 읽기 흐름을 설명한다. |
| 4 | 동작 원리 | record 가 `DB_PAGESIZE/4` 를 넘으면 큰 variable column 부터 밖으로 보내는 흐름을 간단한 애니메이션 또는 단계 그림으로 보여준다. |
| 5 | 읽기 성능 직관 | 자주 읽는 작은 컬럼과 가끔 읽는 큰 컬럼의 access pattern 이 분리되는 효과를 설명한다. full payload read 에서는 추가 OOS read 가 생긴다는 tradeoff 도 같이 둔다. |
| 6 | 안정성 포인트 | UPDATE, rollback, crash recovery, replication 이 같이 맞아야 release 가능한 기능이라는 점을 사례 수준으로만 말한다. |
| 7 | 현재 위치 | M1 완료, M2 진행, 완료된 항목과 남은 항목을 한 화면에 정리한다. |
| 8 | 기대 효과 | I/O 절감, 공간 재활용 개선, 큰 variable data 를 가진 workload 에 대한 기반 확보를 말한다. |
| 9 | 데모 또는 시각화 | SQL 한 개와 OOS 전후 그림을 연결한다. 실제 라이브 데모 여부는 `TBD - 합의 미확인` 이다. |
| 10 | 마무리 | OOS 를 CUBRID 저장 구조 개선의 한 단계로 정리하고, 이후 compression/monitoring/observability 과제로 이어간다. |

### 시각화 방향

HTML/CSS/SVG 기반으로 작성하면 PPT A/PPT B 의 공통 그림을 재사용하기 쉽다. 특히 다음 그림은 SVG 로 만들 가치가 있다.

```
AS-IS heap record
[ id | name | big_text 4.5KB | big_blob 4.5KB ]

TO-BE heap record
[ id | name | OOS OID 16B | OOS OID 16B ]
              |              |
              v              v
          OOS file        OOS file
        [big_text]       [big_blob]
```

추가 SVG 후보:

| 그림 | 사용 위치 | 의도 |
|------|-----------|------|
| largest-first demotion | PPT A/PPT B 공통 | 큰 variable column 부터 밖으로 보내고 gate 이하에서 멈추는 정책을 직관화 |
| UPDATE 생명주기 | PPT A | old OOS OID 가 undo/MVCC 독자 때문에 vacuum 전까지 살아야 하는 이유 설명 |
| 3-Tier bestspace | PPT A | cache, header best[], sync bestspace 의 역할 분리 |
| access pattern 별 효과 | PPT B | 작은 컬럼 중심 read 와 큰 payload read 의 이득/비용을 나란히 표시 |
| 전체 진행 로드맵 | PPT B | M1 완료와 M2 진행 상태를 한눈에 표시 |

### 작업 일정

| 날짜 | 산출물 | 목적 |
|------|--------|------|
| 2026-07-02 목요일 | PPT A/PPT B 목적과 대상 분기 확정 | CBRD-27014 계획 고정 |
| 2026-07-06 월요일 | PPT A/PPT B 공통 코어 스토리와 핵심 그림 1차 작성 | 두 발표자료가 같은 메시지에서 출발하도록 맞춤 |
| 2026-07-08 수요일 | PPT A 기술 슬라이드 초안 | 설계 질문과 피드백 요청 항목 정리 |
| 2026-07-10 금요일 | PPT B 쉬운 설명 슬라이드 초안 | 전사 공유용 흐름과 시각화 정리 |
| 2026-07-13 월요일 | PPT A 검토 | 기술 피드백 수집 |
| 2026-07-14 화요일 | PPT A 피드백 반영 | PPT B 에서 말할 수 있는 결론과 말하지 않을 세부 조정 |
| 2026-07-16 목요일 | PPT B 최종 리허설 | 발표 시간, 그림 크기, 민감 내용 제거 확인 |
| 2026-07-17 금요일 | PPT B 발표 | 전사 공유 |

### Open Questions

| 질문 | 현재 상태 |
|------|-----------|
| 발표 시간 | `TBD - 합의 미확인` |
| PPT A/PPT B 최종 export 형식 | HTML/CSS/SVG, PPTX, PDF 중 `TBD - 합의 미확인` |
| 라이브 데모 포함 여부 | `TBD - 합의 미확인` |
| PPT B 에서 미해결 리스크를 어디까지 공개할지 | `TBD - 합의 미확인` |
| PPT A/PPT B 저장 위치와 첨부 방식 | `TBD - 합의 미확인` |

## Acceptance Criteria

- [ ] PPT A 기술 슬라이드 초안 작성
- [ ] PPT B 전사 공유 슬라이드 초안 작성
- [ ] OOS 핵심 그림 3개 이상 작성: AS-IS/TO-BE, largest-first demotion, UPDATE/vacuum 생명주기
- [ ] CBRD-26583 이후 변경된 현재 스펙 반영: `DB_PAGESIZE/4`, `OR_OOS_INLINE_SIZE`(16B), 16B `OOS OID`, OOS+bigone rejection
- [ ] 작은 컬럼 중심 read 의 이득과 full payload read 의 추가 비용을 모두 설명
- [ ] 2026-07-13 PPT A 검토 진행 및 피드백 기록
- [ ] 2026-07-17 PPT B 발표자료 최종본 준비
- [ ] PPT A/PPT B 에서 미구현 기능을 구현 완료처럼 설명하지 않음

## Definition of done

- [ ] 위 A/C 충족
- [ ] PPT A/PPT B 최종본 또는 export 파일을 CBRD-27014 에 첨부
- [ ] PPT A 피드백 중 후속 개발 이슈가 필요한 항목을 별도 JIRA 후보로 정리
- [ ] PPT B 발표 후 질문과 답변을 본 이슈 또는 별도 회고 문서에 기록

## Remarks

### 참고 자료

| 자료 | 용도 |
|------|------|
| CBRD-27014 | 본 PPT A/PPT B 발표자료 작성 sub-task |
| CBRD-26583 | OOS M2 parent epic |
| CBRD-26582 | 이전 M1/M2 공유 발표 이슈 |
| `/home/vimkim/gh/cubrid-oos-context/OOS-CONTEXT.md` | 현재 OOS 스펙과 용어 기준 |
| `src/storage/oos_file.cpp`, `src/storage/heap_file.c`, `src/object/object_representation.h` | 기술 슬라이드의 코드 근거 확인용 |

### 주의할 표현

- OOS 는 현재 OOS layer compression 을 제공하지 않는다. compression 은 향후 과제로 말한다.
- UPDATE 시 동일 값의 OOS OID reuse 는 현재 구현이 아니다. future improvement 로만 말한다.
- OOS OID 는 공유된다고 표현하지 않는다. 하나의 OOS OID 는 정확히 하나의 record 에서 참조된다는 불변식을 유지한다.
- old `DB_PAGESIZE/8` / 512B 정책을 현재 정책처럼 말하지 않는다.
