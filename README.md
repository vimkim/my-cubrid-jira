# my-cubrid-jira

Personal CUBRID Jira issue notes in Markdown format.

Issue files live in the `issues/` directory, one file per Jira issue, named
`CBRD-<number>[-slug].md`. See [`CLAUDE.md`](CLAUDE.md) for the full workflow.

## Reviewed issue batches

- [CBRD-27193 and all 19 subtasks, 2026-10-21](reviews/CBRD-27193-rewrite/README.md):
  current-skill rewrites against CUBRID `f6cac312`, with per-issue review,
  original-claim accounting, shared scope and description-publication status.

## Proposed issue updates

- [CBRD-26659 OOS testcase categories, 2026-10-27](issues/CBRD-26659-oos-testcase-category-update_e3589ae_codex.md):
  proposed description with six coverage categories, SQL/SH/UT aliases,
  detailed Markdown references and revision-specific CI results; not uploaded.

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
