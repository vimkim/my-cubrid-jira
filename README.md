# my-cubrid-jira

Personal CUBRID Jira issue notes in Markdown format.

Issue files live in the `issues/` directory, one file per Jira issue, named
`CBRD-<number>[-slug].md`. See [`CLAUDE.md`](CLAUDE.md) for the full workflow.

## Reviewed issue batches

- [CBRD-27193 and all 19 subtasks, 2026-10-21](reviews/CBRD-27193-rewrite/README.md):
  current-skill rewrites against CUBRID `f6cac312`, with per-issue review,
  original-claim accounting, shared scope and description-publication status.

## Reviewed issue updates

- [PR #8350 OOS 파일 조회 실패 후속 초안, 2026-11-04](issues/vacuum-oos-vfid-lookup-error.md):
  실제 조회 실패를 성공으로 처리하여 OOS 회수를 생략할 수 있는 기존 결함을 별도로 다룬다. 번호 없는 로컬 초안이며 JIRA 등록과 GitHub 답글 게시 전이다. [중복 확인·등록 준비](reviews/pr8350-vfid-lookup/README.md)와 [원댓글 답글 초안](reviews/pr8350-vfid-lookup/reply-draft.md)을 함께 보존한다. PR #8350은 open으로 유지한다.
- [CBRD-26659 세션 인계와 후속 TODO, 2026-11-04](reviews/CBRD-26659-session-wrapup.md):
  OOS TODO CBRD-26978 아래에 [CBRD-27924 SA compact 수리](issues/CBRD-27924-sa-compact-layout.md)와 [CBRD-27925 유예 빈 페이지 회수 후속](issues/CBRD-27925-deferred-empty-page-reclaim.md)을 생성했다. 생성 본문·부모·유형·관련 링크를 live 재조회로 확인했다. 원래 FAIL·TIMEOUT, 기존 수리 이슈, runner·커버리지·QA·TC 리뷰 잔여 범위와 다음 재개 순서를 보존한다.
  CBRD-27924의 20KB 초과 추가 검사에서 SA compact의 24052B 직렬화 입력과 heap overflow 저장을 관측했다. 같은 논리 값의 일반 UPDATE·CS compact는 OOS를 사용했으며 전체 값은 보존됐다. [재현 자료와 관측 결과](reviews/CBRD-27924-compact-20k/README.md)를 함께 보존한다.
- [CBRD-27785 OOS 통합 후 CRUD 성능 저하 보고서, 2026-11-03](issues/CBRD-27785-oos-performance-report_4c3c8d7_claude.md):
  보고·재현·원인·결과 순서의 JIRA 본문이다. 11-03에 모든 수치를 좋아지면 +, 나빠지면 −로 바꾸고, 명령어 수·cycles·실행 시간을 수치마다 표시했다. 최종 head `4c3c8d791`의 develop 대비 일반 테이블 측정(CBRD-27816)을 더했다. JIRA 설명에 반영하고 재조회로 확인했다.
- [CBRD-27881 리팩토링 Sub-task 7개, 2026-11-03](issues/CBRD-27882-oos-dead-stats-bridge-code_3972085_claude.md):
  CBRD-27881 야간 조사에서 만든 draft PR 7개(#8367~#8373)마다 Sub-task를 하나씩 발급하고, 각 파일을 생성 시 설명으로 올렸다. 파일은 [CBRD-27882](issues/CBRD-27882-oos-dead-stats-bridge-code_3972085_claude.md), [CBRD-27883](issues/CBRD-27883-oos-test-helper-header_9f7e5c1_claude.md), [CBRD-27884](issues/CBRD-27884-oos-lob-copy-helper_02d915e_claude.md), [CBRD-27885](issues/CBRD-27885-oos-hdr-dirty-helper_0368ef0_claude.md), [CBRD-27886](issues/CBRD-27886-oos-heap-destroy-helper_7dd7b73_claude.md), [CBRD-27887](issues/CBRD-27887-oos-attr-flag-helper_eab2962_claude.md), [CBRD-27888](issues/CBRD-27888-oos-false-comments_97e538d_claude.md)이다. 조사 보고서와 결정 문서는 my-cubrid-docs의 `cbrd-27881/`에 있다.
- [CBRD-27872 OOS 성장 게이트 sweep의 할당당 검사 비용, 2026-11-02](issues/CBRD-27872-oos-growth-sweep-cost_dcbf09e_claude.md):
  PR 7990의 hornetmj 리뷰 R3를 사용자가 CBRD-26583(M2)의 Sub-task로 발급했고, 비어 있던 설명을 triage 본문으로 다시 썼다. sweep 발동 조건과 할당당 검사 상한, OOS 명세 §4 불변식의 변경 필요, CBRD-27213과의 범위 경계를 기록한다. 리뷰어 수치는 재현하지 않았다. 2026-11-02 JIRA 설명과 제목에 반영하고, 재조회한 본문의 절 순서가 같음을 확인했다. CBRD-26786, CBRD-27213과 Relates로 연결했다.
- [CBRD-27213 재시작 뒤 OOS 빈 공간 재사용과 bestspace 공통 모듈 전환, 2026-11-02](issues/CBRD-27213-oos-bestspace-shared-module_dcbf09e_claude.md):
  PR 7990 R4를 새 이슈 없이 추적하도록 `725a32c` 판을 `dcbf09e` 기준으로 다시 썼다. 운영 경로에서 3단계 sync가 실행되지 않는 원인, CBRD-27761 기준의 재검토 표시, CBRD-26950 뒤 `owner_vfid` 위치 재검토, 재시작 재사용 완료 조건을 더했다. 2026-11-02 JIRA 설명과 제목에 반영하고, 재조회한 본문의 절 순서와 코드 블록이 온전함을 확인했다. CBRD-27761, CBRD-26824, CBRD-27872와 Relates로 연결했다.
- [CBRD-27860 OOS vacuum과 새 힙 페이지 할당의 래치 순환, 2026-10-31](issues/CBRD-27860-oos-vacuum-heap-header-wait_dcbf09e_claude.md):
  PR 7990의 hornetmj 리뷰 R2를 중복 검색 뒤 CBRD-26583의 Sub-task로 발급했다. 이 파일을 생성 시 설명으로 올렸고, 재조회한 본문이 변환 결과와 같으며 테스트 diff 코드 블록이 온전함을 확인했다. 실제 vacuum worker를 쓰는 단위 테스트의 수정 전 실패, 약 316초의 할당 대기, 로컬 후보의 검증과 미검증 범위를 보존한다.
- [CUBRIDQA-1693 CTP 중첩 SQL 범주의 결과 집계 누락, 2026-10-31](issues/CUBRIDQA-1693-nested-sql-summary_4f720bd_codex.md):
  독립 Task로 발급하고 CBRD-27841과 Relates로 연결했다. 생성 본문의 문서 링크 두 개를 공개 고정 URL로 보정하고 JIRA 본문과의 일치를 확인했다. 수정 전후 보고서 재생과 호환성 검증을 마치고 [회사 draft PR 793](https://github.com/CUBRID/cubrid-testtools/pull/793)을 게시했다. 런타임 반영과 새 회사 CI 검증은 남아 있다.
- [CBRD-27858 relocation 행 vacuum 취소의 forward 슬롯 덮어쓰기, 2026-10-30](issues/CBRD-27858-oos-relocation-forward-slot-undo_dcbf09e_claude.md):
  PR 7990의 hornetmj 리뷰 R5를 중복 검색 뒤 CBRD-26583의 Sub-task로 발급했다. 이 파일을 생성 시 설명으로 올렸고, 재조회한 본문이 변환 결과와 같으며 계측과 드라이버 코드 블록이 온전함을 확인했다. 수정 전 debug·release의 abort·crash 재현, 재현 전용 계측과 드라이버 원문, 로컬 후보의 검증과 미검증 범위를 보존한다.
- [CBRD-27841 OOS 미사용 복구 인덱스 제거, 2026-10-30](issues/CBRD-27841-oos-recovery-index-cleanup_eac70c7_codex.md):
  PR 7990 R6을 OOS M2의 Sub-task로 발급했다. 번호 정리, 저장 형식 2, 수정 전후 집중 CTest와 데이터 보존 검증, HA·MVCC 경로의 미검증 범위를 기록한다.
- [CBRD-27827 OOS 동시 INSERT 중 파일 헤더 경합 실패, 2026-10-29](issues/CBRD-27827-oos-concurrent-insert-header-wait_dcbf09e_codex.md):
  PR 7990의 hornetmj 리뷰 R1을 Correct Error로 발급했다. debug 재현, 7줄 삭제 후보의 10회 검증, 원본 재현 스크립트와 release·혼합 부하의 미검증 범위를 보존한다.
- [CBRD-27724 페이지 버퍼 부하 실험의 설계·해석과 결론, 2026-10-29](issues/CBRD-27724-pgbuf-benchmark-conclusion_17b50f2_codex.md):
  처음 읽는 독자를 위한 논문형 실험 보고서이다. 세 부하를 선택한 이유, 실제 SQL과 통제 조건, 시간별 감속, 객체 잠금 대기 증폭 가설과 단회 개입을 연결한다.
  New Order의 주문 접수 예시, 다섯 업무와 창고·단말 용어, TPC-C 선정 이유와 대안별 적합성도 설명한다.
  OS 파일 캐시 해석, 스캔 전체 적중률의 한계와 미확인 감속 시작 원인을 구분한다.
  [측정값과 검산 스크립트](reviews/CBRD-27724-benchmark/)를 함께 보존한다. JIRA 본문에 반영하고 재조회로 확인했다.
- [CBRD-27816 일반 UPDATE 잔여 비용 후속, 2026-10-28, 수정 2026-11-03](issues/CBRD-27816-ordinary-update-residual-cost_02df4d9_codex.md):
  CBRD-26978의 Sub-task로 생성하고 CBRD-27785와 relates to로 연결했다. 이번 편입에서 관측된 약 +5%를 수용한다는 작성자 결정과 기존 +2% 미달 결과를 구분한다. 후속 로컬 추적은 Work 571이다.
  11-03에 PR #8299 head `4c3c8d7`의 분석 결과(늘 나타나는 성능 변화 −1.34%, 비동기 vacuum에 의한 큰 저하, 코드 변경 없음 결정, 남은 연속 UPDATE 측정)를 더했다. 수치는 좋아지면 +, 나빠지면 −로 적고 표마다 측정 내용과 뜻을 붙였다.
- [CBRD-27785 PR7990 성능 수락 기준 반영, 2026-10-28](issues/CBRD-27785-oos-performance-regression_dcbf09e_codex.md):
  1·3번 우선·잠정 약 +2% 목표, PR8299 선반영과 현재 버전의 이득·손해 공유를 AC로 기록한다. 2번은 threshold를 기존 overflow와 맞춘 뒤 후속 재측정한다.
  기존 두 SELECT의 +2% 검증 완료는 보존하고 현재 판정과 구분한다. 사용자 승인 후 JIRA 설명에 반영하고 재조회로 검증했다.
- [CBRD-26659 관련 PR 목록, 2026-11-03](issues/CBRD-26659-oos-testcase-category-update_e3589ae_codex.md):
  Engine 1건과 TC 4건의 역할·대상 브랜치·실제 Draft 상태를 표로 정리한다. 기존 본문은 2026-10-28까지의 기록으로 보존한다.
- CBRD-27785·CBRD-27788·CBRD-27791 병합 전 성능 검토 배경과 관계 정리, 2026-10-28:
  [27785](issues/CBRD-27785-oos-performance-regression_dcbf09e_codex.md)에 공통 배경과 역할을 기록하고,
  [27788](issues/CBRD-27788-oos-select-performance_dcbf09e_codex.md)·[27791](issues/CBRD-27791-oos-batch-read_dcbf09e_codex.md)의 수행 이유에 연결한다.
  batch read는 후속 개선 후보로 관리하며 다른 성능 저하 원인 조사는 계속한다.
- [CBRD-26835 OOS 병합 전 회귀 처리 요약, 2026-10-28](issues/CBRD-26835-oos-regression-brief_38093ea_codex.md):
  develop 병합 전 정합성·성능 회귀의 분석·수정·재검증 범위와 한계를 간략히 정리한다.
- [CBRD-26198 OOS 사전 조사 요약, 2026-10-28](issues/CBRD-26198-oos-survey-brief_38093ea_codex.md):
  타 DBMS 조사와 CUBRID 코드 분석·개념 설계의 범위를 정리하고 제품 개발과 구분한다.
- [CBRD-26584 OOS M1 요약, 2026-10-28](issues/CBRD-26584-oos-m1-brief_38093ea_codex.md):
  기본 기능 검증의 목표·범위와 M2로 넘긴 운영 기능을 간략히 정리한다.
- [CBRD-26583 OOS M2 요약, 2026-10-28](issues/CBRD-26583-oos-m2-brief_38093ea_codex.md):
  목표, 범위와 한계를 간략히 정리하고 세부 진행 상태는 JIRA 하위 작업에서 관리한다.
- [CBRD-27791 OOS 큰 값 조회의 읽기 지역성 개선, 2026-10-28](issues/CBRD-27791-oos-batch-read_dcbf09e_codex.md):
  제한된 참조 수집·주소순 읽기·선행 읽기·요청 병합의 후보와 검증 순서, 성능 회귀 추적과의 관계 및 저장 배치 변경의 별도 범위를 설명한다.
- [CBRD-27788 최신 PR #7990 OOS SELECT 실측, 2026-10-27](issues/CBRD-27788-oos-select-performance_dcbf09e_codex.md):
  정확한 revision과 실제 저장 진단, 기본 200개 표본과 저장장치 읽기 보조 24개 표본.
  2026-10-28 Conclusion과 Limitation 보완: 조회별 이득·비용, 후속 읽기 진단과 일반화·검증의 한계.
- [CBRD-27014 OOS impact and measured SELECT performance, 2026-10-27](issues/CBRD-27014-oos-impact-and-performance_3173d3b_codex.md):
  completed presentation deliverables, workload-specific benefits and costs,
  fixed benchmark revisions, attachment links and measurement limits.
- [CBRD-27259 STORAGE FORCE_INLINE and fixed-type DEFAULT, 2026-10-27](issues/CBRD-27259-storage-force-inline_bc8a895_codex.md):
  reviewed description covering policy semantics, overflow limits,
  ALTER analysis questions and acceptance criteria.
- [CBRD-26659 OOS testcase categories, 2026-10-27](issues/CBRD-26659-oos-testcase-category-update_e3589ae_codex.md):
  reviewed description with six coverage categories, SQL/SH/UT aliases,
  detailed Markdown references and revision-specific CI results.

## Upload to Jira

Use the `upload` just recipe to interactively upload a Markdown file to Jira:

```sh
just upload      # fzf picker → preview → confirm → upload
just --list      # see all recipes (upload-file, upload-dry, upload-yes, fetch, …)
```

`just upload` runs `cubrid-jira-upload-fzf.sh`, which:

1. Lists all `issues/*.md` files in an `fzf` picker with a preview pane.
2. Hands the choice to `cubrid-jira-upload.sh --interactive`, which derives the
   issue key from the filename (for example,
   `CBRD-25356-some-descriptive-name.md`).
3. Uses `cubrid-jira search` to show the current target and displays a local
   preview.
4. Validates the real converted dry-run payload, asks for confirmation, and
   delegates the live update to `cubrid-jira update`.

For non-interactive use, the same adapter dry-runs by default and performs a
live update only with `--yes`. Recipes: `just upload-dry <file>` and
`just upload-yes <file>`.

`cubrid-jira` is the only publishing implementation. It owns Markdown → Jira
conversion, Korean spacing normalization, formatter validation, credentials,
HTTP behavior, and cache invalidation. The adapter does not modify source files.

Credentials come from `CUBRID_JIRA_USER` / `CUBRID_JIRA_PASSWORD` or the
`jira.cubrid.org` entry in `~/.netrc`. Run `just doctor` to verify tools and
credentials.

### Requirements

- [`cubrid-jira`](https://github.com/vimkim/cubrid-jira) — must be installed and configured
- [`pandoc`](https://pandoc.org/) — used by `cubrid-jira` for Markdown conversion
- [`fzf`](https://github.com/junegunn/fzf)
- [`bat`](https://github.com/sharkdp/bat) (optional, for syntax-highlighted preview)
- [`just`](https://github.com/casey/just)
