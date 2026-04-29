# [AI] Claude Code Max 2개월 적용 사례 — 연구개발본부 발표 (성공·실패담)

## Description

### 배경

- 2026-04-29 **CUBRID 연구개발본부 대상** 발표 진행 (40~60분, 60+ 슬라이드)
- 발표자: 김대현 (개발 2팀 & AI TFT)
- 지난 2개월간 **Claude Code Max 20x (Opus 4.7, 1M Context)** 를 CUBRID 엔진 개발 업무에 적용한 **개인 실사용 경험 공유**
- 발표 자료는 Marp 기반 마크다운(`main.md`) 단일 파일로 작성
- 본 이슈는 발표 준비/콘텐츠/Q&A 결과를 추적하는 Task — 코드 변경 없음

### 목적

- 실험 전제: **"비용 고려 없이 최대한의 개발 자동화를 맡겼을 때 어떤 결과가 나올지"**
- AI 만능 홍보, N배 생산성 주장, 타사 도구 비교가 아닌 **실험 결과·실패담 공유**
- **성공한 영역 vs 실패한 영역** 을 검증 루프 관점에서 명확히 구분
- 한계, 주의점, 초심자 진입 가이드, 팀/본부 자산화 제안까지 포함하여 회사 전체 생산성 향상에 기여

---

## Final Presentation Outline

### 1. Intro (도입 + 빠른 결론)

- 발표자 소개 (개발 2팀 & AI TFT, 2개월 매일 사용, 보조: Codex / Grok)
- 참여 스터디: Claude Code 소스 분석, 플러그인 개발, 고독한 토큰털이
- 발표 목적 — 성공 사례 / 실패 사례 + 그 이유 / 성공시키려면 무엇이 필요한가
- **빠른 결론 (Pros/Cons)**
  - Pros: 반복 업무 큰 비중 부분 자동화 가능 (jira/ppt/github/vscode 포함)
  - Cons: 사용자 경험·경력에 비례, 복잡한 TC 검증·디렉션은 사람 몫, 팀 단위 KB 필요, **Max Opus 4.7 1M 한정 (16만원 이상)**
- **한 줄 요약 — 성공 vs 실패 프레임**

| Domain | Success (검증 루프 명확) | Failure (검증 어려움) |
|--------|--------------------------|------------------------|
| Code | POC 작성, 버그 수정 | 동시성/비동기 TC 작성, 성능 높은 코드 |
| Doc | JIRA 이슈, PR description, 리뷰 보조 | (검증 신호 부재 영역) |
| 공통 | build/test 루프로 옳고 그름 판단 가능 | "통과" 가 아닌 "옳음" 학습 신호 부재 |

### 2. Claude Code 소개 (강력한 Agent Harness)

- 터미널 CLI 기반 agentic 도구 — 단순 자동완성과는 다른 카테고리
- 도구 스펙트럼: 파일 시스템(Read/Write/Edit/Glob/Grep), Bash·git·gh·jq, 백그라운드 빌드/테스트, MCP(clangd/GitHub/JIRA/DB), Skill·Slash·Plugin, Sub-agent·Team, Hook·Auto-memory
- **"강한 권한, 위험하지 않나?"** 섹션 — Permission Mode, Bash tree-sitter 파싱, Hook, Plan/Auto Mode, Sandbox/Worktree, settings.json `allow`/`deny`/`ask`
  - 보안·거버넌스만으로 별도 발표 분량 — 본 발표에서는 개요만
- **Claude Code x CUBRID** — 실제 가능한 일들: 빌드 무한 반복, DB 인스턴스 운영(start/stop, csql), SQL 시나리오 실행, clangd LSP, shell-test 디버깅, GDB attach + coredump 분석, valgrind/sanitizer 해석, `gh run view` CI 로그 분석
- **왜 Max + Opus 4.7 (1M Context) 인가** — Pro/Sonnet 대비 함수 재사용, 패턴 유지, 아키텍팅 능력, 긴 대화에서 흐름 유지

### 3. Part 1 — 코드베이스 탐색·분석 보조

- `heap_file.c` (15,000+ 줄) `heap_insert_logical` -> `heap_insert_physical` 호출 체인 자동 파악 (clangd LSP + gdb ex mode 자동 호출)
- "어디를 봐야 할지" navigational 가치 — `vector type 추가 위치`, `vacuum 수동 실행`, `varbit vs varchar 효율 비교` 등
- 에러 메시지 -> 코드 위치 추적, 다른 개발자 PR 변경 범위 요약 (리뷰 시작점)

### 4. Part 2 — 실제 개발 작업

- **AI 개발 - POC 생성**: vector type 추가, vacuum 비동기 OOS 삭제, unit test (CS_MODE/SA_MODE/SERVER_MODE), sql/shell/isolation test
- **5시간 자율 작업 에피소드**: vector type / DDL / DML 재구현 — 발표자 2개월 작업과 유사한 산출물, 에러·예외 처리 포함
  - 단번에 성공한 것 아님 — 디버깅 강제, **"lazy" 경향 관찰** (작업 범위 자체 축소), 토큰 다량 소모 (Max 20x 월정액 아니었으면 큰 비용)
- **Coredump 디버깅 자동화 루프**: 빌드 -> 실행 -> `gdb bt` -> 가설 -> 수정 -> 반복 (사람 개입 0)
- **Git Merge Conflict 해결** — 자연어 지시 기반 hunk 단위 판단 ("develop 우선" / "특정 모듈 feature 우선"), `--ours`/`--theirs` 보다 세분화
- **CI shell-test 실패 분석**: 로그 + 스크립트 -> 근본 원인

### 5. Part 3 — 문서·커뮤니케이션

- **JIRA 이슈 / PR description 작성**: 변경 코드 -> `/cubrid-jira-issue-write` 스킬, `/jira` + `/cubrid-pr-create` 스킬
- **PR 리뷰 코멘트 응답 보조**: 코멘트 + 관련 코드 -> 응답 초안
- **JIRA REST API 양방향 자동화**: pandoc 으로 JIRA <-> 마크다운, `/jira CBRD-XXXXX` 한 줄 fetch
- **발표 자료 자체가 사례** — 본 발표 60+ 슬라이드 모두 Claude Code 와의 대화로 생성, Marp + 자동 커밋
- **다른 개발자 성공 사례 (jyj 님)** — 간헐적 재현 버그 자동 추적, CTP 대량 실패 자동 분류, 복잡한 코드 흐름 시각화 (CBRD-26666 parallel hash join)
- **Credits**: 주영진, 류형규, 김태우, 송일한 (피드백·사례 공유)

### 6. Limits — 다섯 가지 주의점

| # | 한계 | 요지 |
|---|------|------|
| 1 | 검증은 여전히 개발자 몫 | "AI 출력은 항상 초안", "모르는 코드일수록 더 의심", 빌드·테스트·리뷰 책임 |
| 2 | 자동 생성 테스트는 의심하라 | 형식만 채우는 TC, 통과만 목적 mock 테스트 — coverage / mutation testing |
| 3 | 생성 코드가 느릴 수 있음 | build/test 루프만으로는 성능 신호 없음, 비효율 자료구조 선택 |
| 4 | AI 피로도 (Brain Fry) | 대기 시간 병렬화 -> 컨텍스트 스위칭, 신체적 피로, HBR/Axios/Fortune 인용 |
| 5 | AI 동조 (Sycophancy) | 긍정·단정적 표현에 무비판 OK -> 중의적 질문 + `grill-me` 스킬 |

### 7. 작업 흐름의 변화

- **인간의 Feedback Loop 도 가속**
  - 이전: 가설 -> 조사 -> 코드 분석 -> 설계 -> 구현 -> 개발자 검증 -> TC 생성 -> 스펙 변경 ...
  - 지금: 가설 -> **AI POC** -> 설계 -> **스펙(SSOT) 작성·검증** -> unit test·TC 작성·검증 -> **AI 구현** -> **AI 리뷰** -> 코드 리뷰
- 구현 전 "이 접근법이 heap_file.c 구조에서 동작할까?" 를 Claude 와 먼저 확인하는 습관

### 8. 개발 프로세스의 변화 예상 (SDD / SSOT / TDD)

- **SDD (Spec Driven Development)** — 요구사항을 글로 먼저 명확히 작성
- **SSOT 가 SDD 의 핵심** — 분산되면 모순 누적, AI 출력 일관성은 입력 일관성에서
- **실제 일화 — OOS 프로젝트 stale JIRA**: 스펙 변경 후 JIRA 이슈 미업데이트 -> AI 가 옛 스펙 고집 -> SSOT 분산 위험
- **MD 가 SSOT, JIRA·PR 은 자동 생성** — JIRA/Confluence 문법은 AI 비친화적, 마크다운이 가장 AI 친화적 SSOT
- **모든 산출물 자동 동기화**: spec.md (진실) -> Code, Code Comment, Tests/TC, JIRA Ticket, PR Description, 내부 문서, 매뉴얼, --help 메시지
- **Spec-as-Code 패턴**: `git add spec.md`, PR 리뷰, `git log`/`git blame` — `.claude/skills/`, `.omc/specs/`, `AGENTS.md`, `.cursor/rules`, `.windsurf/rules`
- **TDD Revisited** — AI 시대에 TC 작성 비용이 극적으로 낮아져 다시 매력적, 검증 기준 선행으로 sycophancy/환각 방어선

### 9. AI 친화 == 사람 친화 + AI 운영 방어

- **AI 와 신규 입사자는 같은 입장** — `ctp.sh --help`, `README`, 빌드 스크립트 주석 개선이 양쪽 모두 도움
- **암묵지 -> 형식지 전환**: "서버가 갑자기 죽으면 `$CUBRID/log/server/<db>_stdout.log` 부터" 같은 트러블슈팅 문서화
- **AI 운영 3단계 방어**
  - 1단계: 환경 명시 (worktree 위치, 빌드 상태, DB 실행, coredump 위치)
  - 2단계: Fail Fast prerequisite (skill 앞단에서 branch 불일치/미빌드 즉시 중단)
  - 3단계: Timeout / Hang 방지 (timeout 짧게, "N분 경과 시 다른 방법", iteration 상한)
- **모듈 분석서 (개발 4팀 송일한 님 사례)** — Obsidian graph view 양방향 링크, AI 가 그래프 노드를 따라가며 컨텍스트 절약 (<https://xmilex-git.github.io/claude-obsidian/>)

### 10. 시작 가이드 + Skill / Plugin 전략

- **바로 적용 세 가지**: 낯선 코드 탐색, 디버깅 첫 걸음, 문서 초안
- **꿀팁** — "X 하고 싶다, 사용 가능한 skill/명령어 조합으로 가장 좋은 프롬프트 추천해줘"
- **CLAUDE.md** (프로젝트 컨벤션), **/compact** (컨텍스트 압축)
- **All-in-one 플러그인** — `oh-my-claudecode` (50+ skill), `superpowers`, `serena` (LSP MCP)
- **Skill — "가장 개인적인 것이 가장 창의적이다"** — 범용 skill 은 누군가 만든다, 진짜 가치는 팀·개인 워크플로 특화
- **`vimkim/my-cubrid-skills`** 실제 사례 — `/jira CBRD-12345`, `/cubrid-pr-create`
- **자동화 자동화 4단계**: 첫 시도 -> Skill (`/learner` -> `/skill-creator`) -> Script (결정론적, AI 호출 0) -> Plugin (개인 -> 팀 -> 본부)
- **장기 제안** — 플러그인 운영 자체를 공식 업무로 추가

### 11. 결론 — 마차에서 자율주행까지

- **두 가지 자세**: 지금 가능한 것은 최대한 자동화, 불편한 영역은 곧 풀린다 (시간·노력 투입 시 자동화 영역으로 편입)
- 익명 rhg 님 인용: *"마차에서 자동차로 변화했듯이, 개발자에게는 Claude Code Max 가 역사적인 전환입니다. 말을 끌고 다니다가 한 번에 자율주행까지 도달한 느낌입니다."*

---

## Actual Presentation Highlights (2026-04-29 발표 결과)

발표 후 회의록 (`actual-presentation-summary.md`) 기준 정리:

### 발표에서 강조된 메시지

- **반복 업무(JIRA 이슈, PR 리뷰)는 95% 이상 자동화 가능**
- **True/False 검증 가능 작업** 에서 자동화 효과 두드러짐
- **고품질 TC, 성능 향상** 등 검증 기준 모호 영역은 한계
- **벡터 타입 추가 사례** — 발표자 2개월 작업이 5시간 자율 PoC 로 재현됨, 수십 개 코어덤프 분석
- 팀 단위 자동화: 환경 구성, 플러그인/스킬 활용, 분석서, 자산화

### 청중 Q&A 주요 항목 (FAQ 보강 필요)

| 분류 | 질문 요지 | 발표자 답변 요약 |
|------|------------|-------------------|
| HA / 비동기 TC | HA 테스트, 비동기 TC 작성 자동화 가능? | 자체 검증 어려움, 단일 프로세스 성능 검증은 가능. 네트워크 IO 등 복잡 환경은 한계. 벡터 프로젝트 자동 성능 분석 도움 사례 공유 |
| 컨테이너 환경 | build/test/report 컨테이너 분리 가능? | 분리해도 활용 가능, docker compose 연동, 단 syscall trace 등은 환경 제약 |
| 요금제 / 계정 | Max 가격? 계정 운영 팁? | 16만~33만원, 계정 여러 개 병렬 사용 효율적, 팀 단위 API 토큰 활용 방안 논의 |
| Cursor 연동 | Cursor 탭 컴플리션 vs Opus 4.7? | Cursor 탭은 자체 LLM, Opus 4.7 연동 시 최적화 환경 아니라 성능 하락 |
| 경쟁 AI 리뷰 | 다른 AI 와 상호 리뷰? | Codex 등 경쟁 AI 활용해 상호 리뷰, 분석서/스킬 체계적 문서화로 품질 향상 |

---

## Acceptance Criteria

- [x] 60+ 슬라이드 구성 확정 (`main.md` 단일 파일, 약 1,272줄)
- [x] Pros/Cons 빠른 결론 슬라이드 추가
- [x] 성공/실패 영역 한 줄 요약 슬라이드 추가
- [x] 보안 우려 대응 슬라이드 추가 (`강한 권한, 위험하지 않나?`)
- [x] 한계 5가지 정리 (Sycophancy 추가)
- [x] Credits 슬라이드 추가 (주영진, 류형규, 김태우, 송일한)
- [x] Module 분석서 사례 (송일한 님 Obsidian) 반영
- [x] Spec-as-Code / SSOT / SDD / TDD 섹션 정리
- [x] AI 운영 방어 3단계 (환경/Fail Fast/Timeout) 정리
- [x] 결론 — rhg 님 인용 반영
- [x] 2026-04-29 연구개발본부 발표 진행 완료
- [ ] 발표 Q&A 결과 반영 — HA 테스트 / 컨테이너 / 요금제 / Cursor 항목 메모화
- [ ] 에피소드별 JIRA / PR 번호 사후 기입
- [ ] `main.md` Marp 빌드 최종 확인 (16:9, `bookk` 테마)
- [ ] 민감 코드/비밀키 노출 없음 — 보안 검토

---

## Follow-up Proposals

발표 결과 청중 피드백을 바탕으로 별도 이슈 검토 대상:

- **개발 2팀 / 연구개발본부 Claude Code Plugin 레포지토리 신설** — Skill -> Script -> Plugin 4단계 자산화 흐름의 본부 단위 구현
- **모듈 분석서 작성 가이드 표준화** — 송일한 님 Obsidian graph view 사례 확장, 신규 입사자 온보딩 + AI 컨텍스트 동시 해결
- **표준 prerequisite 라이브러리** — Fail Fast / 환경 명시 / Timeout 방어를 팀·본부 차원에서 공유
- **AI 친화 스크립트 정비** — `ctp.sh --help`, 빌드 스크립트 주석, README 보강 (사람 온보딩 + AI 효율 동시 개선)
- **JIRA SSOT 운영 가이드** — MD SSOT 채택, JIRA/PR 자동 생성 흐름, stale 방지 (OOS 일화 교훈)
- **회사 차원 API 토큰 / 공통 스킬 자산화** — 팀 단위 API 토큰 운영, 공통 skill 저장소

---

## Remarks

- 발표 자료는 Marp 기반 `main.md` 단일 파일 (개인 작업본, 외부 공개 저장소 없음)
- 회의록은 별도 마크다운으로 정리 (`actual-presentation-summary.md`)
- 본 이슈는 **발표 준비·콘텐츠·결과 추적용 Task** — 실제 코드 변경 없음
- 발표자료 자체가 Claude Code 사용 사례 — `git log` 가 발표 자료 변천사
- 본 이슈는 발표 메인 메시지("실험 결과 공유, 한계 포함")를 따라 과장 없이 작성
