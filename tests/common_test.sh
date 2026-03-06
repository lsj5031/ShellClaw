#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/common.sh"

passed=0
failed=0

fail() {
  echo "FAIL: $*" >&2
  failed=$((failed + 1))
}

pass() {
  passed=$((passed + 1))
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local msg="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass
  else
    fail "$msg"
    echo "  expected: $(printf '%q' "$expected")" >&2
    echo "  actual:   $(printf '%q' "$actual")" >&2
  fi
}

assert_match() {
  local actual="$1"
  local pattern="$2"
  local msg="$3"
  if [[ "$actual" =~ $pattern ]]; then
    pass
  else
    fail "$msg"
    echo "  actual:  $(printf '%q' "$actual")" >&2
    echo "  pattern: $(printf '%q' "$pattern")" >&2
  fi
}

# ── Tests ────────────────────────────────────────────────────────────

run_test_iso_now_format() {
  local out
  TIMEZONE="UTC"
  out="$(iso_now)"
  # Format: 2026-03-06T09:04:14+0000
  assert_match "$out" "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4}$" "iso_now format"
}

run_test_iso_now_timezone() {
  local out
  TIMEZONE="America/New_York"
  out="$(iso_now)"
  assert_match "$out" "-0[45]00$" "iso_now respects TIMEZONE (NY)"

  TIMEZONE="UTC"
  out="$(iso_now)"
  assert_match "$out" "\+0000$" "iso_now respects TIMEZONE (UTC)"
}

run_test_trim() {
  assert_eq "$(trim "  hello  ")" "hello" "trim both sides"
  assert_eq "$(trim "	tabs	")" "tabs" "trim tabs"
  assert_eq "$(trim "
  newlines
")" "newlines" "trim newlines"
}

run_test_sql_quote() {
  assert_eq "$(sql_quote "plain")" "'plain'" "sql_quote plain"
  assert_eq "$(sql_quote "it's")" "'it''s'" "sql_quote single quote"
  assert_eq "$(sql_quote "multiple '' quotes")" "'multiple '''' quotes'" "sql_quote multiple quotes"
}

run_test_today_file() {
  LOG_DIR="/tmp/logs"
  TIMEZONE="UTC"
  local day
  day="$(date -u +"%Y-%m-%d")"
  assert_eq "$(today_file)" "/tmp/logs/$day.md" "today_file path"
}

# ── Main ─────────────────────────────────────────────────────────────

main() {
  run_test_iso_now_format
  run_test_iso_now_timezone
  run_test_trim
  run_test_sql_quote
  run_test_today_file

  echo ""
  if [[ "$failed" -gt 0 ]]; then
    echo "common_test: $passed passed, $failed FAILED"
    exit 1
  else
    echo "common_test: all $passed passed"
  fi
}

main "$@"
