#!/usr/bin/env bash
set -euo pipefail

# cubrid-jira-upload-fzf.sh — interactively pick a JIRA issue markdown file with
# fzf, then hand it to cubrid-jira-upload-interactive.sh, which detects the key,
# shows a preview, confirms, fixes Korean spacing, and uploads. This is the
# interactive front-end; cubrid-jira-upload-interactive.sh is the worker and can
# also be run directly with a file argument. For non-interactive uploads (Claude
# Code, CI) use cubrid-jira-upload-noninteractive.sh instead.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISSUES_DIR="$SCRIPT_DIR/issues"

# Collect markdown files (newest first)
mapfile -t FILES < <(
  find "$ISSUES_DIR" -maxdepth 1 -name "*.md" -printf '%T@\t%p\n' \
    | sort -rn \
    | cut -f2-
)

if [ ${#FILES[@]} -eq 0 ]; then
  echo "No issue files found in $ISSUES_DIR"
  exit 1
fi

# Use bat for preview if available, otherwise cat
if command -v bat &>/dev/null; then
  PREVIEW_CMD='bat --color=always --style=numbers {}'
else
  PREVIEW_CMD='cat {}'
fi

# Interactive file selection with fzf
SELECTED=$(printf '%s\n' "${FILES[@]}" | fzf \
  --preview "$PREVIEW_CMD" \
  --preview-window=right:60%:wrap \
  --header="Select a Jira issue to upload  [Enter: upload, Esc: cancel]" \
  --prompt="Issue> " \
  --height=90% \
  --border=rounded \
  --info=inline)

[ -z "$SELECTED" ] && echo "Cancelled." && exit 0

# The exact worker command, shell-quoted with %q so paths with spaces or
# special chars re-run verbatim.
CMD=$(printf '%q ' "$SCRIPT_DIR/cubrid-jira-upload-interactive.sh" "$SELECTED")

# Hand off to the worker. We deliberately do NOT exec: exec would replace this
# process and nothing below would run. Running it as a child lets us regain
# control afterward to record/print the command with its real exit code. The
# child still inherits the tty, so the worker's interactive prompts work.
T0=$(date +%s%N 2>/dev/null || echo 0)
rc=0
"$SCRIPT_DIR/cubrid-jira-upload-interactive.sh" "$SELECTED" || rc=$?

# Record the worker command in atuin so it's searchable / up-arrow-able later.
# It is never typed at the prompt (this front-end invokes it internally), so
# atuin's normal shell hook never sees it. start/end is exactly what that hook
# does: start reserves the entry, end stamps the real exit code + duration.
if command -v atuin &>/dev/null; then
  T1=$(date +%s%N 2>/dev/null || echo 0)
  AID=$(atuin history start -- "$CMD" 2>/dev/null) \
    && atuin history end --exit "$rc" --duration "$(( T1 - T0 ))" "$AID" >/dev/null 2>&1 \
    || true
fi

# Print it last so it's the final thing on screen — easy to drag-select + copy.
echo ""
echo "Worker command (copy to reproduce):"
printf '  %s\n' "$CMD"

exit "$rc"
