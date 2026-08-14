# justfile — manage CUBRID JIRA issue notes (issues/*.md) and push them to
# jira.cubrid.org. Run `just` (or `just --list`) to see every recipe.
#
# Credentials come from CUBRID_JIRA_USER / CUBRID_JIRA_PASSWORD or ~/.netrc;
# run `just doctor` if uploads fail with an auth error.

set shell := ["bash", "-uc"]

issues_dir := "issues"

# Show all recipes (default when you run `just` with no arguments).
default:
    @just --list

# Interactively pick an issue file with fzf, preview it, then upload to JIRA.
upload:
    bash cubrid-jira-upload-fzf.sh

# Upload one file directly with a [y/N] confirmation prompt (needs a TTY),
# e.g. `just upload-file issues/CBRD-26517-oos-todo.md`.
upload-file file:
    bash cubrid-jira-upload.sh {{ quote(file) }} --interactive

# Dry-run a non-interactive upload (shows the diff target, uploads nothing).
# Safe for Claude Code / CI. e.g. `just upload-dry issues/CBRD-26517-oos-todo.md`.
upload-dry file:
    bash cubrid-jira-upload.sh {{ quote(file) }}

# Non-interactive upload — NO prompt, overwrites the live issue immediately.
# e.g. `just upload-yes issues/CBRD-26517-oos-todo.md`.
upload-yes file:
    bash cubrid-jira-upload.sh {{ quote(file) }} --yes

# Exercise the upload adapter with a fake cubrid-jira executable.
test:
    bash tests/test-cubrid-jira-upload.sh

# Live-preview the notes in a browser (markserv on http://0.0.0.0:8000 — reachable from other machines on the LAN).
serve:
    markserv . --address 0.0.0.0 --port 8000 --browser false

# List local issue files, newest first.
list:
    @find {{ issues_dir }} -maxdepth 1 -name '*.md' -printf '%TY-%Tm-%Td  %p\n' | sort -r

# Fetch the live JIRA issue (summary/status/description), e.g. `just fetch CBRD-26517`.
fetch key:
    cubrid-jira search {{ quote(key) }} --no-recurse

# Verify required tools and JIRA credentials are present.
doctor:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    echo "Required:"
    for t in cubrid-jira pandoc fzf python3; do
      if command -v "$t" >/dev/null 2>&1; then echo "  ✓ $t"; else echo "  ✗ $t (missing)"; rc=1; fi
    done
    echo "Optional:"
    for t in bat markserv just; do
      command -v "$t" >/dev/null 2>&1 && echo "  ✓ $t" || echo "  ○ $t (not installed)"
    done
    echo "Credentials:"
    if [ -n "${CUBRID_JIRA_USER:-}" ] && [ -n "${CUBRID_JIRA_PASSWORD:-}" ]; then
      echo "  ✓ CUBRID_JIRA_USER / CUBRID_JIRA_PASSWORD set"
    elif python3 -c 'import netrc; import sys; sys.exit(0 if netrc.netrc().authenticators("jira.cubrid.org") else 1)' >/dev/null 2>&1; then
      echo "  ✓ ~/.netrc entry for jira.cubrid.org"
    else
      echo "  ✗ set CUBRID_JIRA_USER / CUBRID_JIRA_PASSWORD or add a ~/.netrc entry"
      rc=1
    fi
    if [ -n "${JIRA_USER:-}" ] || [ -n "${JIRA_PASSWORD:-}" ]; then
      echo "  ○ JIRA_USER / JIRA_PASSWORD are legacy and ignored by cubrid-jira"
    fi
    exit $rc
