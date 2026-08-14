#!/usr/bin/env bash
set -euo pipefail

# Thin repository adapter around the canonical `cubrid-jira update` interface.
# It derives the issue key from the Markdown filename and optionally provides a
# human confirmation prompt. Markdown conversion, spacing normalization,
# credential handling, dry-run payload construction, HTTP, and cache handling
# all belong to cubrid-jira.

usage()
{
  echo "Usage: $(basename "$0") <issue-file.md> [--interactive | --yes]" >&2
}

MODE=dry-run
SELECTED=""

while [ $# -gt 0 ]; do
  case "$1" in
    -i | --interactive)
      [ "$MODE" = dry-run ] || { echo "Choose only one upload mode." >&2; usage; exit 2; }
      MODE=interactive
      ;;
    -y | --yes)
      [ "$MODE" = dry-run ] || { echo "Choose only one upload mode." >&2; usage; exit 2; }
      MODE=live
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
    *)
      [ -z "$SELECTED" ] || { echo "Only one issue file may be uploaded." >&2; usage; exit 2; }
      SELECTED=$1
      ;;
  esac
  shift
done

[ -n "$SELECTED" ] || { usage; exit 2; }
[ -f "$SELECTED" ] || { echo "File not found: $SELECTED" >&2; exit 1; }
[[ "$SELECTED" = *.md ]] || { echo "Issue file must end in .md: $SELECTED" >&2; exit 1; }

BASENAME=$(basename "$SELECTED" .md)
if [[ "$BASENAME" =~ ^([A-Z][A-Z0-9]*-[0-9]+)(-|$) ]]; then
  ISSUE_KEY=${BASH_REMATCH[1]}
else
  echo "Cannot derive a Jira issue key from filename: $BASENAME" >&2
  echo "Rename it to start with a real key, such as CBRD-12345-slug.md." >&2
  exit 1
fi

command -v cubrid-jira >/dev/null 2>&1 \
  || { echo "Error: cubrid-jira is not installed." >&2; exit 1; }

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  File : $SELECTED"
echo "  Key  : $ISSUE_KEY"
echo
echo "  Current Jira target:"
cubrid-jira search "$ISSUE_KEY" --no-recurse | sed -n '1,16p'
echo
echo "  Local preview:"
sed -n '1,24p' "$SELECTED" | sed 's/^/    /'
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

UPDATE=(
  cubrid-jira update "$ISSUE_KEY"
  --description-file "$SELECTED"
  --from markdown
)

case "$MODE" in
  dry-run)
    exec "${UPDATE[@]}"
    ;;
  live)
    exec "${UPDATE[@]}" --yes
    ;;
  interactive)
    # Exercise the real conversion and payload-building path before asking the
    # user to approve a live overwrite. JSON is suppressed because the local
    # preview above is the human-facing view.
    "${UPDATE[@]}" --output json >/dev/null
    echo
    read -rp "Upload to $ISSUE_KEY? [y/N] " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 130; }
    exec "${UPDATE[@]}" --yes
    ;;
esac
