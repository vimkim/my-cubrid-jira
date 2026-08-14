#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKER="$ROOT_DIR/cubrid-jira-upload.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

fail()
{
  echo "FAIL: $*" >&2
  exit 1
}

assert_log_contains()
{
  local expected=$1
  grep -Fx -- "$expected" "$CALL_LOG" >/dev/null \
    || fail "missing invocation: $expected"
}

assert_log_excludes()
{
  local unexpected=$1
  if grep -F -- "$unexpected" "$CALL_LOG" >/dev/null; then
    fail "unexpected invocation fragment: $unexpected"
  fi
}

mkdir -p "$TEST_DIR/bin"
CALL_LOG="$TEST_DIR/calls.log"
export CALL_LOG

cat > "$TEST_DIR/bin/cubrid-jira" <<'EOF'
#!/usr/bin/env bash
printf '<%s>' "$@" >> "$CALL_LOG"
printf '\n' >> "$CALL_LOG"
if [ "${1:-}" = "search" ]; then
  printf '# [CBRD-12345] Existing issue\n\n## Metadata\n'
elif [ "${1:-}" = "update" ]; then
  printf '{"dry_run":true}\n'
fi
EOF
chmod +x "$TEST_DIR/bin/cubrid-jira"
export PATH="$TEST_DIR/bin:/usr/bin:/bin"

ISSUE_FILE="$TEST_DIR/CBRD-12345-sample issue.md"
printf '# Sample\n\nBody\n' > "$ISSUE_FILE"
cp "$ISSUE_FILE" "$TEST_DIR/original.md"

: > "$CALL_LOG"
"$WORKER" "$ISSUE_FILE" >/dev/null
assert_log_contains '<search><CBRD-12345><--no-recurse>'
assert_log_contains "<update><CBRD-12345><--description-file><$ISSUE_FILE><--from><markdown>"
assert_log_excludes '<--yes>'

: > "$CALL_LOG"
"$WORKER" "$ISSUE_FILE" --yes >/dev/null
assert_log_contains "<update><CBRD-12345><--description-file><$ISSUE_FILE><--from><markdown><--yes>"

: > "$CALL_LOG"
printf 'y\n' | "$WORKER" "$ISSUE_FILE" --interactive >/dev/null
assert_log_contains "<update><CBRD-12345><--description-file><$ISSUE_FILE><--from><markdown><--output><json>"
assert_log_contains "<update><CBRD-12345><--description-file><$ISSUE_FILE><--from><markdown><--yes>"

: > "$CALL_LOG"
set +e
printf 'n\n' | "$WORKER" "$ISSUE_FILE" --interactive >/dev/null
rc=$?
set -e
[ "$rc" -eq 130 ] || fail "interactive decline returned $rc, expected 130"
assert_log_contains "<update><CBRD-12345><--description-file><$ISSUE_FILE><--from><markdown><--output><json>"
assert_log_excludes '<--yes>'

INVALID_FILE="$TEST_DIR/not-an-issue.md"
printf '# Invalid\n' > "$INVALID_FILE"
: > "$CALL_LOG"
if "$WORKER" "$INVALID_FILE" >/dev/null 2>&1; then
  fail "invalid issue filename was accepted"
fi
[ ! -s "$CALL_LOG" ] || fail "invalid filename invoked cubrid-jira"
cmp -s "$ISSUE_FILE" "$TEST_DIR/original.md" \
  || fail "upload adapter modified the source Markdown"

echo "PASS: cubrid-jira upload adapter"
