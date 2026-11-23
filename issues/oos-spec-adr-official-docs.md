# [OOS] 개인 저장소에 있는 OOS 규범 명세(Spec)와 ADR을 회사 공식 문서로 명문화

**한 줄 요약**: [PR #7990](https://github.com/CUBRID/cubrid/pull/7990) ([CBRD-26357](https://jira.cubrid.org/browse/CBRD-26357))으로 OOS가 `develop` 에 병합된 상태에서, 리뷰어와 개발자가 참조하는 규범 명세(`OOS-CONTEXT.md`)와 아키텍처 결정 기록(`ADR-0001~0010`)이 개인 저장소(`vimkim/cubrid-oos-context`)에만 남아 있어 팀 공식 문서로 편입·유지보수할 방안을 결정하고 이관하는 작업이다.

## Issue Triage

**이슈 수행 목적**: OOS의 규범 명세, 확정 ADR, 참고 문서를 팀 누구나 접근하고 코드 변경과 함께 검토·갱신할 수 있는 회사 공식 문서로 명문화한다.

**이슈 수행 이유**: OOS 엔진 구현이 `CUBRID/cubrid#7990`(커밋 `68a9c7766f`, 2026-11-19)으로 `develop` 에 병합되었고, 기존 15건의 CBRD 이슈와 PR #7990 외부 리뷰(2026-11-19 `CBRD-26357` 댓글)가 개인 저장소 [vimkim/cubrid-oos-context](https://github.com/vimkim/cubrid-oos-context) 의 명세와 ADR을 기준으로 정합성을 판정하고 있다. 반면 공식 저장소 `CUBRID/cubrid` 의 `src/storage/AGENTS.md` 및 `src/storage/docs/`(7개 파일)에는 OOS 설명이 전혀 없다.

**영향**: 개발자·리뷰어·QA·에이전트가 OOS 동작 계약(demotion target, `STORAGE` 정책, 32B 청크 헤더, postpone/redo-only 회수, 빈 페이지 회수 불변식, 11.5 CDC 유예 범위 등)을 확인할 때 개인 저장소에 의존해야 하며, 저장소 소유자 변경·링크 유실·엔진 코드와의 괴리 위험이 있다. 또한 현재 문서에는 개인 로컬 경로·비공개 작업 ID(`WorkNNN`) 등 조직 공유에 부적합한 참조가 40곳 섞여 있다.

**이슈 수행 방안**: TBD - ANALYSIS 단계에서 해결 방안과 구현 범위를 결정한다.

---

## AI-Generated Context

## Description

이 이슈는 [CBRD-26978](https://jira.cubrid.org/browse/CBRD-26978) (OOS TODO Epic)의 후속이며 [CBRD-26357](https://jira.cubrid.org/browse/CBRD-26357) (OOS 도입 Epic)과 연계된다. 2026-11-19 [PR #7990](https://github.com/CUBRID/cubrid/pull/7990) 병합으로 OOS 코드가 `CUBRID/cubrid` `develop` 에 포함되었고, `CBRD-26357` 외부 코드 리뷰(2026-11-19 댓글)에서도 `cubrid-oos-context` 명세를 구현 정합성 비교의 기준선으로 직접 인용했다. 그러나 해당 명세와 결정 기록은 아직 개인 GitHub 저장소에만 있어, 공식 리뷰 프로세스와 코드 변경 이력에 묶여 관리되지 않고 있다.

### 현재 문서 자산 현황

현재 [vimkim/cubrid-oos-context](https://github.com/vimkim/cubrid-oos-context) 에 보관된 문서 구성은 다음과 같다.

| 문서 / 경로 | 규모·최종 갱신 | 상태 | 내용 요약 |
| --- | --- | --- | --- |
| `OOS-CONTEXT.md` | 327줄, 약 41 KB (2026-11-19) | 규범 명세 | §1 트리거·`STORAGE` 정책·`bigone` 거부, §2 레코드/청크 레이아웃·신원 스탬프·bestspace, §3 CRUD·Expand/Resolve·UPDATE 체인 재사용, §4 복구·HA·vacuum·빈 페이지 회수, §5 파일 생명주기·TDE·11.5 CDC 유예·부트 포맷 검사, 용어집 및 작성 규약 |
| `CONTEXT.md` | 17줄 | 규범 보조 용어 | CDC/flashback 이력 이미지 관련 용어 정의 (`Before image`, `After image`, `Supported/Legacy OOS history`) |
| `docs/adr/0001`~`0010` | 10편 (약 64 KB) | `accepted` | 0001: non-numerable 페이지 열거, 0002: LOB locator 자격 유지, 0003: opt-in Expand, 0004: CDC 보강 이미지(0005로 일부 대체), 0005: 11.5 CDC 유예(0006 개정·0007 일부 대체), 0006: 부트 storage-format 스탬프 검사(0008 개정), 0007: 지연 CDC 회귀 QA 전용 실행, 0008: 확정 후 postpone/redo-only 회수, 0009: idle이 아닌 성장 전 빈 페이지 회수, 0010: emptied-page set 기반 성장 게이트 |
| `docs/adr/0011` | 1편, 59줄 (2026-11-11) | `proposed` | 빈 OOS 페이지 제자리 재사용(dealloc 제거·vacuum fast path 제거). [CBRD-28281](https://jira.cubrid.org/browse/CBRD-28281) 에서 채택 여부를 별도 심사 중이므로 1차 공식 규범에 확정 규칙으로 편입하면 안 됨 |
| `docs/reference/design-history.md` | 145줄, 약 17 KB (2026-11-05) | 비규범 참고 | M1 규칙, PG TOAST/MySQL 비교, ADR-0008 이전 회수 규칙, 유예된 최적화·설계 논의 이력 |
| `docs/reference/implementation-observations.md` | 201줄, 약 33 KB (2026-11-19) | 비규범 참고 | 이슈별 구현 관측 스냅샷(`CBRD-26950`, `27230`, `27237`, `26786`, `28062`, `27259`, `ADR-0008` 등) |
| `docs/reference/test-recipes.md` | 147줄, 약 10 KB (2026-10-27) | 비규범 참고 | VARBIT 테스트 패턴, demotion 계산 예시, 카테고리별 시나리오 |

### 이관 전 정비가 필요한 확인 사항

1. **개인 경로·비공개 참조 정리(9개 파일 40건)**: 문서 안에 개인 환경의 로컬 스킬 경로, 개인 문서/이슈/메모 저장소(`my-cubrid-docs`, `my-cubrid-jira`, `cubrid-oos-vault`, `temp/`)를 가리키는 상대 경로, 비공개 작업 ID(`Work742`~`Work878`)가 포함되어 있다. 공식 문서로 옮길 때는 공개 GitHub/JIRA 링크 또는 본문 내 요약 근거로 치환해야 한다.
2. **스냅샷 노후화 및 일부 문구 보정**: `implementation-observations.md` 의 상당수 항목은 `PR #7990` 병합 이전 커밋(`dcbf09e4f`, `d52b1889e` 등) 기준 관측이다. 또한 `test-recipes.md` 9.6절에는 "A non-OOS bigone ... still succeeds"라는 문구가 남아 있어, 2026-11-09 개정된 비시스템 클래스 `REC_BIGONE` 전면 거부 규칙(`OOS-CONTEXT.md` §1)과 어긋난다. 이관 시 규범과 어긋난 예시 문구를 대조·수정해야 한다.
3. **기존 공식 저장소 문서 체계와의 관계**: `CUBRID/cubrid` `develop` 에는 [CBRD-26974](https://jira.cubrid.org/browse/CBRD-26974) 와 [CBRD-28038](https://jira.cubrid.org/browse/CBRD-28038) 을 통해 구축된 `src/storage/AGENTS.md` 및 `src/storage/docs/*.md`(7개 분석서)가 존재하지만 OOS 항목은 비어 있다. 반면 과거 JIRA 본문에 직접 스펙 비교표를 올렸던 [CBRD-26592](https://jira.cubrid.org/browse/CBRD-26592) 는 M1 규칙(`DB_PAGESIZE/8`, 512B, 16B 스터브) 상태로 방치된 뒤 `Closed (Won't Fix)` 로 종료되었다.

## Options for Analysis

아래 방안은 ANALYSIS 단계 검토용 후보이며 최종 선택은 ANALYSIS에서 확정한다.

| 후보 방안 | 기대 효과와 장점 | 한계·단점과 실패 조건 | 비용·위험·호환성 | 근거와 ANALYSIS 확인 사항 |
| --- | --- | --- | --- | --- |
| 현재 상태 유지 (기준선: 개인 저장소 단독 관리) | 추가 이관·정비 비용이 즉시 들지 않음 | 공식 리뷰·코드 변경과 분리되어 소유권, 접근성, 최신성 보장 불가; 비공개 로컬 경로가 그대로 남음 | 저장소 소유자 변경·링크 단절 위험; 공식 문서 부재 지속 | `CBRD-26357` 외부 리뷰가 이미 개인 저장소에 의존한 사례가 확인됨 |
| 방안 A (잠정 권장 후보): `CUBRID/cubrid` 공식 저장소 내 문서 편입 + JIRA 추적 병행 | 코드·PR 리뷰와 같은 워크플로에서 Spec/ADR을 함께 심사·갱신 가능; Git 이력으로 개정 추적 가능 | 저장소 내 위치(`src/storage/docs/` vs 루트 `docs/`)와 언어 정책 합의 필요; PR 승인·정비 공수 발생 | 개인 경로 40건 정비 및 `test-recipes.md` §9.6 등 불일치 보정 필요; 코드 동작 변경 없음 | `CBRD-26974`/`CBRD-28038` (`src/storage/docs/*.md`) 선례 존재; 위치(A-1 `src/storage/docs/` vs A-2 루트 `docs/`), 언어, `reference/` 포함 범위 확인 필요 |
| 방안 B: JIRA 이슈 본문(단일 또는 ADR별 하위 이슈)으로 Spec/ADR 직접 등재 | 별도 PR 없이 JIRA만으로 문서 확인 가능; 티켓 체계와 바로 결합 | 대용량 Spec(41 KB)·ADR 11편의 diff/PR 리뷰·상호 링크 유지보수가 어려움; 코드 변경과 동기화가 끊기기 쉬움 | jira wiki 변환 시 표·코드블록 가독성 저하 및 갱신 누락으로 문서 노후화 위험 | `CBRD-26592` 가 JIRA 본문 스펙 유지 실패 후 `Closed (Won't Fix)` 된 선례 확인됨 |
| 방안 C: 별도 조직 저장소·사내 개발 포털(`dev.cubrid.org`) 또는 매뉴얼(`CUBRIDMAN`) 이관 | 개발자 외 독자 접근성 확보; 매뉴얼은 사용자 관점 기능 안내에 적합 | 내부 엔진 계약·ADR을 매뉴얼에 넣으면 범위 불일치; 코드 PR과 저장소가 분리되어 동기화 비용 증가 | 포털/별도 저장소 운영 권한 및 동기화 절차 추가 필요 | 사용자용 DDL/파라미터/에러(`STORAGE`, `oos_trigger_threshold` 등)만 `CUBRIDMAN` 별도 이슈로 분리하는 방안 검토 필요 |

### 후보 비교 및 판별 기준

- **코드-문서 동기화와 리뷰 가능성**을 중시하면 방안 A가 가장 유리하다. 엔진 코드를 바꾸는 PR에서 규범 명세와 ADR 개정을 같은 PR 또는 연계 PR로 리뷰할 수 있고, `src/storage/AGENTS.md` 및 `src/storage/docs/` 선례([CBRD-26974](https://jira.cubrid.org/browse/CBRD-26974), [CBRD-28038](https://jira.cubrid.org/browse/CBRD-28038))를 그대로 활용할 수 있다.
- **저장소 PR 절차 없이 빠른 사내 공유**만 필요하거나 조직 표준이 위키/포털 중심이라면 방안 B 또는 방안 C가 유리하지만, 방안 B는 `CBRD-26592` 선례처럼 코드가 변할 때 본문이 쉽게 낡는 한계가 있다.
- 따라서 ANALYSIS에서는 (1) `CUBRID/cubrid` 저장소 안에 OOS Spec/ADR을 두는 것에 대한 팀 합의 여부, (2) 배치 위치(A-1 `src/storage/docs/` 하위 vs A-2 루트 `docs/`), (3) `implementation-observations.md` 같은 시점별 관측 문서를 저장소에 남길지 JIRA로 넘길지를 우선 판별하면 방안을 확정할 수 있다.

## Open Questions for Analysis

1. **문서 저장 위치**: 기존 storage 분석서(`src/storage/docs/*.md`)의 확장으로 둘지(A-1), 아니면 프로젝트 루트 `docs/` 아래에 공식 스펙/ADR 디렉터리(예: `docs/oos/`, `docs/adr/`)를 신설할지(A-2).
2. **문서 언어 정책**: 기존 `OOS-CONTEXT.md`·`ADR-0001~0010`·`src/storage/docs/` 와 같이 영문으로 유지할지, 한국어 번역/요약을 병기할지.
3. **`docs/reference/*` 포함 범위**: `implementation-observations.md` 는 PR 병합 전 스냅샷이 많으므로 저장소 이관 대상에서 빼고 JIRA/PR 이력으로만 남길지, `design-history.md` 및 보정된 `test-recipes.md` 는 함께 편입할지.
4. **`ADR-0011` (`proposed`) 처리**: [CBRD-28281](https://jira.cubrid.org/browse/CBRD-28281) 결론 전까지 공식 문서에서 제외할지, `proposed` 상태로 함께 등재하되 미채택 경계를 명시할지.
5. **상위 Epic 배치 및 기존 저장소 정리**: 이 작업을 `CBRD-26978` 하위에 둘지 `CBRD-26357` 직접 하위에 둘지, 그리고 이관 완료 후 개인 저장소(`vimkim/cubrid-oos-context`)를 아카이브/포인터 안내 전용으로 전환할지.
6. **사용자 매뉴얼(`CUBRIDMAN`) 범위 분리**: `STORAGE` 컬럼 옵션, `oos_trigger_threshold`, `ER_HEAP_OOS_OVERPASS_MAXOBJ_SIZE`, `ER_BO_INCOMPATIBLE_STORAGE_FORMAT` 등 사용자·운영자 안내를 별도 `CUBRIDMAN` 문서 이슈로 분리할지.

## Acceptance Criteria

- 공식 문서 저장 위치, 언어, 포함 범위(`OOS-CONTEXT.md`, `CONTEXT.md`, `ADR-0001~0010`, `ADR-0011` 및 `docs/reference/*` 처리 방침)가 팀 리뷰를 거쳐 확정된다.
- 채택된 공식 위치에 개인 로컬 경로·비공개 작업 ID가 제거되고 규범 불일치(`test-recipes.md` §9.6 등)가 정리된 문서가 게시된다.
- `ADR-0001~0010` 의 상태(accepted/amended/superseded)와 `ADR-0011` (`proposed`, [CBRD-28281](https://jira.cubrid.org/browse/CBRD-28281) 연동)의 경계가 명확히 구분된다.
- [CBRD-26357](https://jira.cubrid.org/browse/CBRD-26357) 및 공식 저장소 진입점(`src/storage/AGENTS.md` 등)에서 새 공식 문서로 연결된다.
- 이관 완료 후 기존 개인 저장소(`vimkim/cubrid-oos-context`)에는 공식 문서 이관 안내와 canonical 링크가 남는다.

## Related Work

- [CBRD-26357](https://jira.cubrid.org/browse/CBRD-26357): OOS 도입 Epic (`PR #7990` 병합 완료, 외부 리뷰에서 `cubrid-oos-context` 참조)
- [CBRD-26978](https://jira.cubrid.org/browse/CBRD-26978): OOS TODO Epic (권장 부모 이슈)
- [CBRD-28281](https://jira.cubrid.org/browse/CBRD-28281): ADR-0011(빈 페이지 제자리 재사용, `proposed`) 채택 여부 결정 이슈
- [CBRD-26592](https://jira.cubrid.org/browse/CBRD-26592): 과거 M1 시점 PG TOAST vs OOS 스펙 비교표 (`Closed / Won't Fix`, JIRA 단독 문서 노후화 선례)
- [CBRD-27537](https://jira.cubrid.org/browse/CBRD-27537), [CBRD-26974](https://jira.cubrid.org/browse/CBRD-26974), [CBRD-28038](https://jira.cubrid.org/browse/CBRD-28038): `CUBRID/cubrid` 저장소 내 `src/storage/AGENTS.md` 및 `src/storage/docs/` 공식 문서화·갱신 선례
