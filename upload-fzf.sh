#!/usr/bin/env bash
set -euo pipefail

# upload-fzf.sh — interactively pick a JIRA issue markdown file with fzf, then
# hand it to upload.sh, which detects the key, shows a preview, confirms, fixes
# Korean spacing, and uploads. This is the interactive front-end; upload.sh is
# the worker and can also be run directly with a file argument.

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

# Print the exact worker command (shell-quoted with %q so paths with spaces or
# special chars re-run verbatim) so it can be copied and run directly later.
echo "Running (copy to reproduce):"
printf '  '; printf '%q ' "$SCRIPT_DIR/upload.sh" "$SELECTED"; printf '\n\n'

# Hand off to the worker: upload.sh detects the key, previews, confirms, and
# uploads the selected file. exec replaces this process so upload.sh inherits
# the tty and its exit status propagates.
exec "$SCRIPT_DIR/upload.sh" "$SELECTED"
