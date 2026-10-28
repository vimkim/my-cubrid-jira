# my-cubrid-jira

Personal CUBRID Jira issue notes in Markdown format.

Issue files live in the `issues/` directory, one file per Jira issue, named
`CBRD-<number>[-slug].md`. See [`CLAUDE.md`](CLAUDE.md) for the full workflow.

## Reviewed issue batches

- [CBRD-27193 and all 19 subtasks, 2026-10-21](reviews/CBRD-27193-rewrite/README.md):
  current-skill rewrites against CUBRID `f6cac312`, with per-issue review,
  original-claim accounting, shared scope and description-publication status.

## Reviewed issue updates

- [CBRD-26835 OOS 병합 전 회귀 처리 요약, 2026-10-28](issues/CBRD-26835-oos-regression-brief_38093ea_codex.md):
  develop 병합 전 정합성·성능 회귀의 분석·수정·재검증 범위와 한계를 간략히 정리한다.
- [CBRD-26198 OOS 사전 조사 요약, 2026-10-28](issues/CBRD-26198-oos-survey-brief_38093ea_codex.md):
  타 DBMS 조사와 CUBRID 코드 분석·개념 설계의 범위를 정리하고 제품 개발과 구분한다.
- [CBRD-26584 OOS M1 요약, 2026-10-28](issues/CBRD-26584-oos-m1-brief_38093ea_codex.md):
  기본 기능 검증의 목표·범위와 M2로 넘긴 운영 기능을 간략히 정리한다.
- [CBRD-26583 OOS M2 요약, 2026-10-28](issues/CBRD-26583-oos-m2-brief_38093ea_codex.md):
  목표, 범위와 한계를 간략히 정리하고 세부 진행 상태는 JIRA 하위 작업에서 관리한다.
- [CBRD-27791 OOS batch read 검토, 2026-10-28](issues/CBRD-27791-oos-batch-read_dcbf09e_codex.md):
  현재 읽기 동작, SQL 성능 저하, 원인 가설과 실제 엔진에서 검증할 개선 방법을 순서대로 설명한다.
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
