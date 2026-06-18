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
- `cubrid-jira-upload.sh` — the **worker**: uploads one file (see below).
- `cubrid-jira-upload-fzf.sh` — the **interactive front-end**: fzf picker → worker.
- `justfile` — task runner; run `just` to list recipes.

## Uploading (this is automated — do not hand-craft API calls)

The upload pipeline is `just upload` → `cubrid-jira-upload-fzf.sh` (fzf picker)
→ `cubrid-jira-upload.sh <file>` (worker). The worker:

1. Derives the issue key from the filename (or prompts if absent).
2. Fetches the **current** JIRA issue (summary + status) so you can see what
   you're about to overwrite.
3. Shows a local preview and asks `Upload to <KEY>? [y/N]`.
4. Runs `korean-spacing` in place to fix spacing around inline markdown next to
   Korean text.
5. Calls `jira-md-upload <KEY> <file>`, which converts Markdown → JIRA wiki
   markup and **overwrites the issue description**.

Common commands:

| Command | What it does |
| --- | --- |
| `just upload` | Pick a file with fzf and upload it (the normal path). |
| `just upload-file issues/CBRD-26517-oos-todo.md` | Upload one specific file. |
| `just fetch CBRD-26517` | Print the live issue (summary/status/description) — inspect before overwriting. |
| `just list` | List local issue files, newest first. |
| `just fix-spacing <file>` | Run `korean-spacing` on a file without uploading. |
| `just serve` | Preview the notes in a browser (markserv, http://localhost:8000). |
| `just doctor` | Check required tools + JIRA credentials are present. |

## Guardrails for the AI agent

- **Never run an upload autonomously.** `jira-md-upload` overwrites a live,
  shared JIRA issue — an outward-facing, hard-to-reverse action. Only run
  `just upload` / `just upload-file` / `cubrid-jira-upload.sh` when the user
  explicitly asks, and let *its* `[y/N]` prompt be the final confirmation.
  The worker also exits `130` (not `0`) when the user declines, so a decline is
  not a success.
- **Your job is the Markdown.** Default to creating and editing `issues/*.md`.
  When you want to upload, propose the exact `just` command and let the user run
  it. Use `just fetch <KEY>` (read-only) to compare local vs. server first.
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
