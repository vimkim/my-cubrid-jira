#!/usr/bin/env bash
set -euo pipefail

# upload.sh <issue-file.md> — upload one issue markdown file to CUBRID JIRA.
#
# Given a file, it detects the issue key from the filename, shows the existing
# JIRA issue + a local preview, asks for confirmation, sanitizes Korean spacing,
# then uploads via jira-md-upload. Interactive file selection lives in
# upload-fzf.sh, which picks a file with fzf and execs into this script.

if [ $# -lt 1 ]; then
  echo "Usage: $(basename "$0") <issue-file.md>" >&2
  exit 2
fi

SELECTED="$1"

if [ ! -f "$SELECTED" ]; then
  echo "File not found: $SELECTED" >&2
  exit 1
fi

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
# Exit 130 (the SIGINT convention) on a declined upload so the run is recorded
# distinctly from a real success (0) — e.g. in atuin via upload-fzf.sh.
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 130; }

echo "Sanitizing Korean spacing..."
korean-spacing -i "$SELECTED" -o "$SELECTED"

echo ""
jira-md-upload "$ISSUE_KEY" "$SELECTED"
echo ""
echo "Done! $ISSUE_KEY updated."
