# justfile — manage CUBRID JIRA issue notes (issues/*.md) and push them to
# jira.cubrid.org. Run `just` (or `just --list`) to see every recipe.
#
# Credentials (JIRA_URL / JIRA_USER / JIRA_PASSWORD) come from .envrc via
# direnv — run `just doctor` if uploads fail with an auth error.

set shell := ["bash", "-uc"]

issues_dir := "issues"
jira_url   := env_var_or_default("JIRA_URL", "http://jira.cubrid.org")

# Show all recipes (default when you run `just` with no arguments).
default:
    @just --list

# Interactively pick an issue file with fzf, preview it, then upload to JIRA.
upload:
    bash cubrid-jira-upload-fzf.sh

# Upload one file directly with a [y/N] confirmation prompt (needs a TTY),
# e.g. `just upload-file issues/CBRD-26517-oos-todo.md`.
upload-file file:
    bash cubrid-jira-upload-interactive.sh {{file}}

# Dry-run a non-interactive upload (shows the diff target, uploads nothing).
# Safe for Claude Code / CI. e.g. `just upload-dry issues/CBRD-26517-oos-todo.md`.
upload-dry file:
    bash cubrid-jira-upload-noninteractive.sh {{file}}

# Non-interactive upload — NO prompt, overwrites the live issue immediately.
# e.g. `just upload-yes issues/CBRD-26517-oos-todo.md`.
upload-yes file:
    bash cubrid-jira-upload-noninteractive.sh {{file}} --yes

# Live-preview the notes in a browser (markserv on http://0.0.0.0:8000 — reachable from other machines on the LAN).
serve:
    markserv . --address 0.0.0.0 --port 8000 --browser false

# List local issue files, newest first.
list:
    @find {{issues_dir}} -maxdepth 1 -name '*.md' -printf '%TY-%Tm-%Td  %p\n' | sort -r

# Fetch the live JIRA issue (summary/status/description), e.g. `just fetch CBRD-26517`.
fetch key:
    #!/usr/bin/env bash
    set -euo pipefail
    curl -sf "{{jira_url}}/rest/api/2/issue/{{key}}?fields=summary,status,description" \
      | python3 -c 'import sys, json; f = json.load(sys.stdin)["fields"]; print("Summary:", f["summary"]); print("Status :", f["status"]["name"]); print(); print(f.get("description") or "(no description)")'

# Normalize spacing around inline markdown next to Korean text, in place.
fix-spacing file:
    korean-spacing -i {{file}} -o {{file}}

# Verify required tools and JIRA credentials are present.
doctor:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    echo "Required:"
    for t in fzf jira-md-upload korean-spacing curl python3; do
      if command -v "$t" >/dev/null 2>&1; then echo "  ✓ $t"; else echo "  ✗ $t (missing)"; rc=1; fi
    done
    echo "Optional:"
    for t in bat markserv just; do
      command -v "$t" >/dev/null 2>&1 && echo "  ✓ $t" || echo "  ○ $t (not installed)"
    done
    echo "Credentials (.envrc + direnv):"
    for v in JIRA_URL JIRA_USER JIRA_PASSWORD; do
      if [ -n "${!v:-}" ]; then echo "  ✓ $v set"; else echo "  ✗ $v unset (run: direnv allow)"; rc=1; fi
    done
    exit $rc
