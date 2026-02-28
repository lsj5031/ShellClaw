#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$msg (missing: $needle)"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="$3"
  [[ "$haystack" != *"$needle"* ]] || fail "$msg (unexpected: $needle)"
}

setup_fake_bin() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"

  cat > "$bin_dir/curl" <<'CURL_EOF'
#!/usr/bin/env bash
set -euo pipefail

log_file="${TEST_CURL_LOG:?}"
scenario="${TEST_CURL_SCENARIO:-}"
fail_text="${TEST_CURL_FAIL_TEXT:-}"

{
  echo "---"
  printf '%s\n' "$@"
} >> "$log_file"

has_parse_mode=0
text_arg=""
for arg in "$@"; do
  if [[ "$arg" == "parse_mode=MarkdownV2" ]]; then
    has_parse_mode=1
  fi
  if [[ "$arg" == text=* ]]; then
    text_arg="$arg"
  fi
done

if [[ "$scenario" == "fail_markdownv2_once" && "$has_parse_mode" -eq 1 && ! -f "${log_file}.failed_once" ]]; then
  touch "${log_file}.failed_once"
  exit 1
fi

if [[ "$scenario" == "always_fail_markdownv2" && "$has_parse_mode" -eq 1 ]]; then
  exit 1
fi

if [[ "$scenario" == "fail_markdownv2_unescaped" && "$has_parse_mode" -eq 1 ]]; then
  if [[ -n "$fail_text" && "$text_arg" == "text=$fail_text" ]]; then
    exit 1
  fi
fi

printf '{"ok":true,"result":{"message_id":42}}\n'
CURL_EOF
  chmod +x "$bin_dir/curl"
}

new_instance() {
  local tmp_root="$1"
  local parse_mode="$2"
  local name="$3"
  local dir="$tmp_root/$name"
  mkdir -p "$dir"
  cat > "$dir/.env" <<EOF_ENV
TELEGRAM_BOT_TOKEN=test_token
TELEGRAM_CHAT_ID=123456
TELEGRAM_PARSE_MODE=$parse_mode
EOF_ENV
  printf '%s\n' "$dir"
}

new_instance_without_parse_mode() {
  local tmp_root="$1"
  local name="$2"
  local dir="$tmp_root/$name"
  mkdir -p "$dir"
  cat > "$dir/.env" <<'EOF_ENV'
TELEGRAM_BOT_TOKEN=test_token
TELEGRAM_CHAT_ID=123456
EOF_ENV
  printf '%s\n' "$dir"
}

first_call_log() {
  local log_file="$1"
  awk '
    /^---$/ { section++; next }
    section == 1 { print }
  ' "$log_file"
}

run_test_markdownv2_escapes_text() {
  local tmp_root="$1"
  local bin_dir="$tmp_root/bin"
  setup_fake_bin "$bin_dir"

  local instance_dir
  instance_dir="$(new_instance "$tmp_root" "MarkdownV2" "instance_escape")"
  local log_file="$tmp_root/curl_escape.log"

  TEST_CURL_LOG="$log_file" \
  TEST_CURL_SCENARIO="fail_markdownv2_unescaped" \
  TEST_CURL_FAIL_TEXT='Need (a+b)=1.0! #tag [x] {p|q}' \
  PATH="$bin_dir:$PATH" \
  INSTANCE_DIR="$instance_dir" \
    "$ROOT_DIR/scripts/telegram_api.sh" --text 'Need (a+b)=1.0! #tag [x] {p|q}'

  local call_count
  call_count="$(grep -c '^---$' "$log_file")"
  [[ "$call_count" -eq 2 ]] || fail "Expected two curl calls (raw then escaped), got $call_count"

  local first second
  first="$(awk '/^---$/{n++; next} n==1 {print}' "$log_file")"
  second="$(awk '/^---$/{n++; next} n==2 {print}' "$log_file")"

  assert_contains "$first" "parse_mode=MarkdownV2" "First call should include parse mode"
  assert_contains "$first" 'text=Need (a+b)=1.0! #tag [x] {p|q}' "First call should keep raw text"
  assert_contains "$second" "parse_mode=MarkdownV2" "Second call should include parse mode"
  assert_contains "$second" 'text=Need \(a\+b\)\=1\.0\! \#tag \[x\] \{p\|q\}' "Second call should use escaped text"
}

run_test_markdownv2_keeps_valid_markdown() {
  local tmp_root="$1"
  local bin_dir="$tmp_root/bin"
  setup_fake_bin "$bin_dir"

  local instance_dir
  instance_dir="$(new_instance "$tmp_root" "MarkdownV2" "instance_markdown")"
  local log_file="$tmp_root/curl_markdown.log"

  TEST_CURL_LOG="$log_file" \
  PATH="$bin_dir:$PATH" \
  INSTANCE_DIR="$instance_dir" \
    "$ROOT_DIR/scripts/telegram_api.sh" --text '*bold* _ok_'

  local call_count
  call_count="$(grep -c '^---$' "$log_file")"
  [[ "$call_count" -eq 1 ]] || fail "Expected one curl call for valid markdown, got $call_count"

  local first_call
  first_call="$(first_call_log "$log_file")"
  assert_contains "$first_call" "parse_mode=MarkdownV2" "MarkdownV2 parse_mode should be set"
  assert_contains "$first_call" 'text=*bold* _ok_' "Valid markdown should be sent raw"
}

run_test_retry_without_parse_mode() {
  local tmp_root="$1"
  local bin_dir="$tmp_root/bin"
  setup_fake_bin "$bin_dir"

  local instance_dir
  instance_dir="$(new_instance "$tmp_root" "MarkdownV2" "instance_retry")"
  local log_file="$tmp_root/curl_retry.log"

  TEST_CURL_LOG="$log_file" \
  TEST_CURL_SCENARIO="always_fail_markdownv2" \
  PATH="$bin_dir:$PATH" \
  INSTANCE_DIR="$instance_dir" \
    "$ROOT_DIR/scripts/telegram_api.sh" --text 'retry test' >/dev/null

  local call_count
  call_count="$(grep -c '^---$' "$log_file")"
  [[ "$call_count" -eq 3 ]] || fail "Expected three curl calls (raw parse, escaped parse, plain retry), got $call_count"

  local first second third
  first="$(awk '/^---$/{n++; next} n==1 {print}' "$log_file")"
  second="$(awk '/^---$/{n++; next} n==2 {print}' "$log_file")"
  third="$(awk '/^---$/{n++; next} n==3 {print}' "$log_file")"

  assert_contains "$first" "parse_mode=MarkdownV2" "First call should include parse mode"
  assert_contains "$second" "parse_mode=MarkdownV2" "Second call should still use parse mode"
  assert_not_contains "$third" "parse_mode=MarkdownV2" "Third call should drop parse mode"
  assert_contains "$third" "text=retry test" "Fallback call should keep raw text"
}

run_test_off_mode_plain_text() {
  local tmp_root="$1"
  local bin_dir="$tmp_root/bin"
  setup_fake_bin "$bin_dir"

  local instance_dir
  instance_dir="$(new_instance "$tmp_root" "off" "instance_off")"
  local log_file="$tmp_root/curl_off.log"

  TEST_CURL_LOG="$log_file" \
  PATH="$bin_dir:$PATH" \
  INSTANCE_DIR="$instance_dir" \
    "$ROOT_DIR/scripts/telegram_api.sh" --text 'Need (a+b)=1.0! #tag [x] {p|q}'

  local first
  first="$(first_call_log "$log_file")"

  assert_not_contains "$first" "parse_mode=" "off mode should not set parse_mode"
  assert_contains "$first" 'text=Need (a+b)=1.0! #tag [x] {p|q}' "off mode should keep text unchanged"
}

run_test_default_mode_html() {
  local tmp_root="$1"
  local bin_dir="$tmp_root/bin"
  setup_fake_bin "$bin_dir"

  local instance_dir
  instance_dir="$(new_instance_without_parse_mode "$tmp_root" "instance_default_html")"
  local log_file="$tmp_root/curl_default_html.log"

  TEST_CURL_LOG="$log_file" \
  PATH="$bin_dir:$PATH" \
  INSTANCE_DIR="$instance_dir" \
    "$ROOT_DIR/scripts/telegram_api.sh" --text '<b>Hello</b>'

  local first
  first="$(first_call_log "$log_file")"

  assert_contains "$first" "parse_mode=HTML" "Default mode should use HTML parse_mode"
  assert_contains "$first" 'text=<b>Hello</b>' "Default HTML mode should send text unchanged"
}

run_test_default_mode_html_caption() {
  local tmp_root="$1"
  local bin_dir="$tmp_root/bin"
  setup_fake_bin "$bin_dir"

  local instance_dir
  instance_dir="$(new_instance_without_parse_mode "$tmp_root" "instance_default_html_caption")"
  local log_file="$tmp_root/curl_default_html_caption.log"
  local sample_file="$tmp_root/sample.txt"
  printf 'sample\n' > "$sample_file"

  TEST_CURL_LOG="$log_file" \
  PATH="$bin_dir:$PATH" \
  INSTANCE_DIR="$instance_dir" \
    "$ROOT_DIR/scripts/telegram_api.sh" --document "$sample_file" --caption '<b>Cap</b>'

  local first
  first="$(first_call_log "$log_file")"

  assert_contains "$first" "parse_mode=HTML" "Default mode should apply HTML parse_mode for captions"
  assert_contains "$first" 'caption=<b>Cap</b>' "Caption should be sent unchanged"
}

main() {
  local tmp_root
  tmp_root="$(mktemp -d)"
  trap 'rm -rf "${tmp_root:-}"' EXIT

  run_test_markdownv2_escapes_text "$tmp_root"
  run_test_markdownv2_keeps_valid_markdown "$tmp_root"
  run_test_retry_without_parse_mode "$tmp_root"
  run_test_off_mode_plain_text "$tmp_root"
  run_test_default_mode_html "$tmp_root"
  run_test_default_mode_html_caption "$tmp_root"

  echo "telegram_api tests passed"
}

main "$@"
