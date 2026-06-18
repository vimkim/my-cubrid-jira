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
- `cubrid-jira-upload-interactive.sh` — the **interactive worker**: uploads one
  file behind a `[y/N]` prompt (needs a TTY; for humans). (see below)
- `cubrid-jira-upload-noninteractive.sh` — the **non-interactive worker**: same
  job, no prompt. Dry-runs by default; uploads only with `--yes`. This is the
  one Claude Code / CI can run.
- `cubrid-jira-upload-fzf.sh` — the **interactive front-end**: fzf picker →
  interactive worker.
- `justfile` — task runner; run `just` to list recipes.

## Uploading (this is automated — do not hand-craft API calls)

There are two workers — one for humans (interactive), one for Claude Code / CI
(non-interactive) — that do the **same five steps**:

1. Derives the issue key from the filename.
2. Fetches the **current** JIRA issue (summary + status) so you can see what
   you're about to overwrite.
3. Shows a local preview, then confirms (see below).
4. Runs `korean-spacing` in place to fix spacing around inline markdown next to
   Korean text.
5. Calls `jira-md-upload <KEY> <file>`, which converts Markdown → JIRA wiki
   markup and **overwrites the issue description**.

The only difference is step 3 (and the missing-key case):

- **Interactive** (`just upload` → `cubrid-jira-upload-fzf.sh` → `cubrid-jira-upload-interactive.sh <file>`):
  asks `Upload to <KEY>? [y/N]` on the TTY, and prompts for the key if the
  filename has none. Declining exits `130` (not `0`), so a decline ≠ success.
- **Non-interactive** (`cubrid-jira-upload-noninteractive.sh <file> [--yes]`):
  never prompts. Without `--yes` it **dry-runs** — shows the diff target and
  exits `0` without uploading. With `--yes` it uploads. A filename with no real
  key is rejected (not prompted), so `CBRD-XXXXX-*.md` drafts can't be uploaded.

Common commands:

| Command | What it does |
| --- | --- |
| `just upload` | Pick a file with fzf and upload it interactively (the normal human path). |
| `just upload-file issues/CBRD-26517-oos-todo.md` | Upload one file interactively (`[y/N]` prompt). |
| `just upload-dry issues/CBRD-26517-oos-todo.md` | **Non-interactive dry run** — preview the overwrite, upload nothing. Safe for Claude / CI. |
| `just upload-yes issues/CBRD-26517-oos-todo.md` | **Non-interactive upload** — no prompt, overwrites the live issue. |
| `just fetch CBRD-26517` | Print the live issue (summary/status/description) — inspect before overwriting. |
| `just list` | List local issue files, newest first. |
| `just fix-spacing <file>` | Run `korean-spacing` on a file without uploading. |
| `just serve` | Preview the notes in a browser (markserv, http://localhost:8000). |
| `just doctor` | Check required tools + JIRA credentials are present. |

## Guardrails for the AI agent

- **Never upload autonomously; never pass `--yes` on your own initiative.**
  `jira-md-upload` overwrites a live, shared JIRA issue — an outward-facing,
  hard-to-reverse action. The interactive scripts (`just upload`,
  `just upload-file`, `cubrid-jira-upload-interactive.sh`) hang waiting for a
  TTY you don't have, so don't run them. The non-interactive worker
  (`cubrid-jira-upload-noninteractive.sh` / `just upload-yes`) *will* run for
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
- **Korean spacing** is applied automatically by the worker; don't pre-mangle
  spacing by hand. Markdown bold/inline-code survive the md→wiki conversion.

## Credentials

`jira-md-upload` reads `JIRA_URL`, `JIRA_USER`, `JIRA_PASSWORD` from the
environment. These are exported by `.envrc` (gitignored) and loaded by
**direnv** — run `direnv allow` once. If an upload fails with an auth error, run
`just doctor`; a missing credential means direnv hasn't loaded `.envrc`.

## External tools (installed separately, on `PATH`)

- `jira-md-upload` — md → JIRA wiki uploader (https://github.com/vimkim/md-to-jira-uploader).
- `korean-spacing` — Korean/markdown spacing normalizer (UV tool).
- `fzf` (picker), `bat` (optional preview), `markserv` (optional preview), `just`.
