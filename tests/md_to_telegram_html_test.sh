#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/md_to_telegram_html.sh"

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

# ── Tests ────────────────────────────────────────────────────────────

run_test_plain_text() {
  local out
  out="$(printf 'Hello world' | "$SCRIPT")"
  assert_eq "$out" "Hello world" "plain text passthrough"
}

run_test_html_escaping() {
  local out
  out="$(printf '1 < 2 & 3 > 0' | "$SCRIPT")"
  assert_eq "$out" "1 &lt; 2 &amp; 3 &gt; 0" "HTML entity escaping"
}

run_test_bold_double_star() {
  local out
  out="$(printf 'This is **bold** text' | "$SCRIPT")"
  assert_eq "$out" "This is <b>bold</b> text" "bold with **"
}

run_test_bold_double_underscore() {
  local out
  out="$(printf 'This is __bold__ text' | "$SCRIPT")"
  assert_eq "$out" "This is <b>bold</b> text" "bold with __"
}

run_test_italic_single_star() {
  local out
  out="$(printf 'This is *italic* text' | "$SCRIPT")"
  assert_eq "$out" "This is <i>italic</i> text" "italic with *"
}

run_test_italic_single_underscore() {
  local out
  out="$(printf 'This is _italic_ text' | "$SCRIPT")"
  assert_eq "$out" "This is <i>italic</i> text" "italic with _"
}

run_test_strikethrough() {
  local out
  out="$(printf 'This is ~~deleted~~ text' | "$SCRIPT")"
  assert_eq "$out" "This is <s>deleted</s> text" "strikethrough"
}

run_test_inline_code() {
  local out
  out="$(printf 'Run \x60ls -la\x60 please' | "$SCRIPT")"
  assert_eq "$out" 'Run <code>ls -la</code> please' "inline code"
}

run_test_inline_code_preserves_special() {
  local out
  out="$(printf 'Use \x60a < b && c > d\x60 here' | "$SCRIPT")"
  assert_eq "$out" 'Use <code>a &lt; b &amp;&amp; c &gt; d</code> here' "inline code preserves HTML-escaped content"
}

run_test_link() {
  local out
  out="$(printf 'Visit [Google](https://google.com) now' | "$SCRIPT")"
  assert_eq "$out" 'Visit <a href="https://google.com">Google</a> now' "link conversion"
}

run_test_link_with_ampersand() {
  local out
  out="$(printf 'Go to [search](https://x.com?a=1&b=2) ok' | "$SCRIPT")"
  assert_eq "$out" 'Go to <a href="https://x.com?a=1&b=2">search</a> ok' "link with & in URL"
}

run_test_heading() {
  local out
  out="$(printf '## My Heading' | "$SCRIPT")"
  assert_eq "$out" "<b>My Heading</b>" "heading to bold"
}

run_test_heading_with_trailing_hash() {
  local out
  out="$(printf '# Title ##' | "$SCRIPT")"
  assert_eq "$out" "<b>Title</b>" "heading strips trailing hashes"
}

run_test_fenced_code_block() {
  local input
  input=$'```python\nprint("hello")\n```'
  local out
  out="$(printf '%s' "$input" | "$SCRIPT")"
  assert_eq "$out" '<pre><code class="language-python">print("hello")</code></pre>' "fenced code block with language"
}

run_test_fenced_code_block_no_lang() {
  local input
  input=$'```\nfoo < bar\n```'
  local out
  out="$(printf '%s' "$input" | "$SCRIPT")"
  assert_eq "$out" '<pre><code>foo &lt; bar</code></pre>' "fenced code block without language"
}

run_test_fenced_code_block_preserves_markdown() {
  local input
  input=$'```\n**not bold** _not italic_\n```'
  local out
  out="$(printf '%s' "$input" | "$SCRIPT")"
  assert_eq "$out" '<pre><code>**not bold** _not italic_</code></pre>' "code block does not convert markdown"
}

run_test_blockquote_single() {
  local out
  out="$(printf '> This is quoted' | "$SCRIPT")"
  assert_eq "$out" "<blockquote>This is quoted</blockquote>" "single-line blockquote"
}

run_test_blockquote_multi() {
  local input
  input=$'> line one\n> line two'
  local out
  out="$(printf '%s' "$input" | "$SCRIPT")"
  assert_eq "$out" $'<blockquote>line one\nline two</blockquote>' "multi-line blockquote"
}

run_test_blockquote_with_formatting() {
  local out
  out="$(printf '> This is **bold** in a quote' | "$SCRIPT")"
  assert_eq "$out" "<blockquote>This is <b>bold</b> in a quote</blockquote>" "blockquote with inline formatting"
}

run_test_mixed_inline() {
  local out
  out="$(printf 'Hello **world** and *friends* with \x60code\x60' | "$SCRIPT")"
  assert_eq "$out" 'Hello <b>world</b> and <i>friends</i> with <code>code</code>' "mixed inline formatting"
}

run_test_multiline() {
  local input
  input=$'First **bold** line\nSecond *italic* line'
  local out
  out="$(printf '%s' "$input" | "$SCRIPT")"
  local expected
  expected=$'First <b>bold</b> line\nSecond <i>italic</i> line'
  assert_eq "$out" "$expected" "multiline with different styles"
}

run_test_empty_input() {
  local out
  out="$(printf '' | "$SCRIPT")"
  assert_eq "$out" "" "empty input"
}

# ── Main ─────────────────────────────────────────────────────────────

main() {
  run_test_plain_text
  run_test_html_escaping
  run_test_bold_double_star
  run_test_bold_double_underscore
  run_test_italic_single_star
  run_test_italic_single_underscore
  run_test_strikethrough
  run_test_inline_code
  run_test_inline_code_preserves_special
  run_test_link
  run_test_link_with_ampersand
  run_test_heading
  run_test_heading_with_trailing_hash
  run_test_fenced_code_block
  run_test_fenced_code_block_no_lang
  run_test_fenced_code_block_preserves_markdown
  run_test_blockquote_single
  run_test_blockquote_multi
  run_test_blockquote_with_formatting
  run_test_mixed_inline
  run_test_multiline
  run_test_empty_input

  echo ""
  if [[ "$failed" -gt 0 ]]; then
    echo "md_to_telegram_html tests: $passed passed, $failed FAILED"
    exit 1
  else
    echo "md_to_telegram_html tests: all $passed passed"
  fi
}

main "$@"
