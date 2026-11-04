#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(git -C "$script_dir" rev-parse --show-toplevel)"
issue_file="$repo_dir/issues/CBRD-27933-vacuum-oos-vfid-lookup-error.md"
summary="$(sed -n '1s/^# //p' "$issue_file")"
test -n "$summary"

cubrid-jira create \
  --project CBRD \
  --type Sub-task \
  --parent CBRD-26978 \
  --summary "$summary" \
  --description-file "$issue_file" \
  --from markdown \
  --field 'customfield_210565={"value":"Required"}' \
  --link-relates CBRD-27860 \
  --server http://jira.cubrid.org \
  --dry-run \
  --output json
