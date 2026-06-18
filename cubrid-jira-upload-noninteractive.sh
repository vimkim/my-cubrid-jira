#!/usr/bin/env bash
set -euo pipefail

# cubrid-jira-upload-noninteractive.sh <issue-file.md> [--yes|-y] — upload one
# issue markdown file to CUBRID JIRA (jira.cubrid.org) WITHOUT any interactive
# prompt. Intended for callers that have no TTY (Claude Code, CI, scripts).
#
# The interactive sibling (cubrid-jira-upload-interactive.sh) gates the upload
# behind a [y/N] prompt; that prompt hangs forever without a TTY. This script
# replaces the prompt with an explicit --yes flag:
#
#   * without --yes : DRY RUN — derive the key, show the existing issue + a
#                     local preview, then exit 0 WITHOUT uploading.
#   * with --yes    : sanitize Korean spacing and upload (overwrites the live
#                     issue description), same as confirming [y] interactively.
#
# The issue key is derived from the filename ONLY (e.g. CBRD-25356-foo.md ->
# CBRD-25356). There is no key fallback prompt: a file whose name has no real
# key (e.g. a CBRD-XXXXX-*.md draft) is rejected, not uploaded.

CONFIRM=0
SELECTED=""
for arg in "$@"; do
  case "$arg" in
    -y | --yes) CONFIRM=1 ;;
    -*)
      echo "Unknown option: $arg" >&2
      echo "Usage: $(basename "$0") <issue-file.md> [--yes|-y]" >&2
      exit 2
      ;;
    *) SELECTED="$arg" ;;
  esac
done

if [ -z "$SELECTED" ]; then
  echo "Usage: $(basename "$0") <issue-file.md> [--yes|-y]" >&2
  exit 2
fi

if [ ! -f "$SELECTED" ]; then
  echo "File not found: $SELECTED" >&2
  exit 1
fi

BASENAME=$(basename "$SELECTED" .md)

# Derive the issue key from the filename only — never prompt.
if [[ "$BASENAME" =~ ^([A-Z]+-[0-9]+) ]]; then
  ISSUE_KEY="${BASH_REMATCH[1]}"
  echo "Detected issue key: $ISSUE_KEY"
else
  echo "Cannot derive a JIRA issue key from filename: $BASENAME" >&2
  echo "Rename the file to start with a real key (e.g. CBRD-12345-slug.md)." >&2
  echo "Drafts named CBRD-XXXXX-*.md cannot be uploaded." >&2
  exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  File : $SELECTED"
echo "  Key  : $ISSUE_KEY"
echo ""

# Fetch existing JIRA issue so the dry-run output shows what would be overwritten.
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

if [ "$CONFIRM" -ne 1 ]; then
  echo "DRY RUN: not uploading. Re-run with --yes to overwrite $ISSUE_KEY."
  exit 0
fi

echo "Sanitizing Korean spacing..."
korean-spacing -i "$SELECTED" -o "$SELECTED"

echo ""
jira-md-upload "$ISSUE_KEY" "$SELECTED"
echo ""
echo "Done! $ISSUE_KEY updated."
