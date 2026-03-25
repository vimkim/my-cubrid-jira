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
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  File : $SELECTED"
echo "  Key  : $ISSUE_KEY"
echo ""

# Fetch existing JIRA issue to prevent accidental overwrites
echo "  [Fetching existing issue from JIRA...]"
JIRA_JSON=$(curl -sf "http://jira.cubrid.org/rest/api/2/issue/${ISSUE_KEY}?fields=summary,status" 2>/dev/null || true)
if [ -n "$JIRA_JSON" ]; then
  JIRA_TITLE=$(echo "$JIRA_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['fields']['summary'])" 2>/dev/null || echo "(parse error)")
  JIRA_STATUS=$(echo "$JIRA_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['fields']['status']['name'])" 2>/dev/null || echo "?")
  echo "  Existing issue title  : $JIRA_TITLE"
  echo "  Existing issue status : $JIRA_STATUS"
else
  echo "  (Could not fetch existing issue — may be a new issue or network error)"
fi

echo ""
# Show local file preview (first heading + first few content lines)
LOCAL_TITLE=$(grep -m1 '^#' "$SELECTED" 2>/dev/null | sed 's/^#\+ *//' || echo "(no heading found)")
LOCAL_PREVIEW=$(grep -v '^#' "$SELECTED" | grep -v '^$' | head -3 2>/dev/null || true)
echo "  Local file title : $LOCAL_TITLE"
if [ -n "$LOCAL_PREVIEW" ]; then
  echo "  Local content preview:"
  echo "$LOCAL_PREVIEW" | sed 's/^/    /'
fi
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
read -rp "Upload to $ISSUE_KEY? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

echo "Stripping bold/italic markers..."
python3 "$(dirname "${BASH_SOURCE[0]}")/strip-stars.py" -i "$SELECTED"

echo "Sanitizing Korean spacing..."
python3 "$(dirname "${BASH_SOURCE[0]}")/korean-spacing.py" -i "$SELECTED" -o "$SELECTED"

echo ""
jira-md-upload "$ISSUE_KEY" "$SELECTED"
echo ""
echo "Done! $ISSUE_KEY updated."
