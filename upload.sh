#!/usr/bin/env bash
set -euo pipefail

ISSUES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/issues"

# Collect markdown files
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

BASENAME=$(basename "$SELECTED" .md)

# Try to extract issue key from filename (e.g. CBRD-25356)
if [[ "$BASENAME" =~ ^([A-Z]+-[0-9]+) ]]; then
  ISSUE_KEY="${BASH_REMATCH[1]}"
  echo "Detected issue key: $ISSUE_KEY"
else
  echo "File: $BASENAME"
  read -rp "Enter Jira issue key (e.g. CBRD-12345, CUBRIDQA-12345): " ISSUE_KEY
  [ -z "$ISSUE_KEY" ] && echo "No issue key provided. Aborting." && exit 1
fi

echo ""
echo "  File : $SELECTED"
echo "  Key  : $ISSUE_KEY"
echo ""
read -rp "Upload? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

echo "Sanitizing Korean spacing..."
python3 "$(dirname "${BASH_SOURCE[0]}")/korean-spacing.py" -i "$SELECTED" -o "$SELECTED"

echo ""
jira-md-upload "$ISSUE_KEY" "$SELECTED"
echo ""
echo "Done! $ISSUE_KEY updated."
