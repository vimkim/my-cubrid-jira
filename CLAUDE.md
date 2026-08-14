# CLAUDE.md — my-cubrid-jira

Personal CUBRID JIRA issue notes, authored in Markdown and **uploaded to the
live tracker at https://jira.cubrid.org**. Each `issues/*.md` file is the local
source of truth for one JIRA issue; uploading replaces that issue's description
on the server.

## Layout

- `issues/*.md` — one file per JIRA issue. Filename encodes the key:
  `CBRD-<number>[-free-form-slug].md` (e.g. `CBRD-26517-oos-todo.md`,
  `CBRD-25356.md`). The slug after the key is for humans and is ignored by the
  uploader. Files named `CBRD-XXXXX-*.md` are drafts without a key yet — they
  cannot be uploaded until renamed with a real number.
- `cubrid-jira-upload.sh` — a thin adapter that derives the issue key from the
  filename and delegates reads, Markdown conversion, dry-run payload creation,
  and publication to the canonical `cubrid-jira` CLI. It supports dry-run,
  `--interactive`, and `--yes` modes.
- `cubrid-jira-upload-fzf.sh` — the **interactive front-end**: fzf picker →
  `cubrid-jira-upload.sh --interactive`.
- `justfile` — task runner; run `just` to list recipes.

## Uploading (this is automated — do not hand-craft API calls)

The upload adapter performs these steps:

1. Derives the issue key from the filename.
2. Reads the current issue through `cubrid-jira search` and shows the target.
3. Shows a local preview.
4. Delegates to `cubrid-jira update --description-file ... --from markdown`.

`cubrid-jira` owns the deep publishing implementation: Markdown → Jira wiki
conversion, Korean inline-spacing normalization, code-formatter validation,
credential handling, dry-run/live write gating, HTTP errors, and cache
invalidation. The adapter never mutates the source Markdown.

- **Interactive** (`just upload` or `just upload-file`): validates the real
  dry-run payload, asks `Upload to <KEY>? [y/N]`, then adds `--yes`. Declining
  exits `130` (not `0`), so a decline ≠ success.
- **Non-interactive** (`just upload-dry` / `just upload-yes`): never prompts.
  Dry-run prints the actual converted request; `upload-yes` performs the live
  update. A filename without a real key is rejected, so `CBRD-XXXXX-*.md`
  drafts cannot be uploaded.

Common commands:

| Command | What it does |
| --- | --- |
| `just upload` | Pick a file with fzf and upload it interactively (the normal human path). |
| `just upload-file issues/CBRD-26517-oos-todo.md` | Validate and upload one file interactively (`[y/N]` prompt). |
| `just upload-dry issues/CBRD-26517-oos-todo.md` | **Non-interactive dry run** — preview the overwrite, upload nothing. Safe for Claude / CI. |
| `just upload-yes issues/CBRD-26517-oos-todo.md` | **Non-interactive upload** — no prompt, overwrites the live issue. |
| `just fetch CBRD-26517` | Print the live issue (summary/status/description) — inspect before overwriting. |
| `just list` | List local issue files, newest first. |
| `just test` | Test the upload adapter against a fake `cubrid-jira` executable. |
| `just serve` | Preview the notes in a browser (markserv, http://localhost:8000). |
| `just doctor` | Check required tools + JIRA credentials are present. |

## Guardrails for the AI agent

- **Never upload autonomously; never pass `--yes` on your own initiative.**
  `cubrid-jira update` overwrites a live, shared JIRA issue — an outward-facing,
  hard-to-reverse action. The interactive scripts (`just upload`,
  `just upload-file`, `cubrid-jira-upload.sh --interactive`) wait for a
  TTY you don't have, so don't run them. The non-interactive worker
  (`cubrid-jira-upload.sh --yes` / `just upload-yes`) *will* run for
  you — which is exactly why the `--yes` flag is reserved for when the user has
  **explicitly asked you to upload this specific file**. That explicit request
  is the stand-in for the human `[y/N]` confirmation.
- **Dry-run freely; upload only on request.** Running the non-interactive worker
  without `--yes` (or `just upload-dry <file>`) is read-only — it just shows what
  would be overwritten and exits `0`. Use it to preview. Do **not** add `--yes`
  unless the user told you to upload.
- **Your job is the Markdown.** Default to creating and editing `issues/*.md`.
  Unless the user explicitly asked you to upload, propose the exact `just`
  command and let them run it. Use `just fetch <KEY>` or `just upload-dry <file>`
  (both read-only) to compare local vs. server first.
- **Writing a new issue?** Use the `cubrid-jira-issue-write` skill (Korean body,
  English `##` headers) and save to `issues/`. Use `/jira CBRD-XXXXX` to pull an
  existing issue's context before editing.
- **Formatting is applied in memory by `cubrid-jira`.** Do not pre-mangle the
  source file. Markdown bold/inline-code survive the md→wiki conversion.

## Credentials

`cubrid-jira` resolves `CUBRID_JIRA_USER` / `CUBRID_JIRA_PASSWORD` first, then
falls back to the `jira.cubrid.org` entry in `~/.netrc`. If an upload fails with
an auth error, run `just doctor`. Legacy `JIRA_USER` / `JIRA_PASSWORD` variables
are not used by `cubrid-jira`.

## External tools (installed separately, on `PATH`)

- `cubrid-jira` — canonical Jira read/write and Markdown conversion CLI.
- `pandoc` — conversion engine used internally by `cubrid-jira`.
- `fzf` (picker), `bat` (optional preview), `markserv` (optional preview), `just`.
