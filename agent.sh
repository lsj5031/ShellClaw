#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/common.sh"
load_env

require_cmd curl
require_cmd jq
require_cmd sqlite3

: "${CODEX_BIN:=codex}"
: "${EXEC_POLICY:=yolo}"
: "${POLL_INTERVAL_SECONDS:=2}"
: "${WEBHOOK_MODE:=off}"
: "${ALLOWLIST_PATH:=./config/allowlist.txt}"
: "${AGENT_LOG_LEVEL:=info}"

api_base=""
file_base=""
poll_fail_count=0
empty_polls=0

log_ts() {
  TZ="$TIMEZONE" date +"%Y-%m-%dT%H:%M:%S%z"
}

log_info() {
  printf "%s [INFO] %s\n" "$(log_ts)" "$*"
}

log_warn() {
  printf "%s [WARN] %s\n" "$(log_ts)" "$*" >&2
}

log_debug() {
  if [[ "$AGENT_LOG_LEVEL" == "debug" ]]; then
    printf "%s [DEBUG] %s\n" "$(log_ts)" "$*"
  fi
}

validate_runtime_requirements() {
  : "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN is required in .env}"
  : "${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID is required in .env}"
  if [[ "$TELEGRAM_BOT_TOKEN" == "replace_me" || "$TELEGRAM_CHAT_ID" == "replace_me" ]]; then
    echo "TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID are still set to placeholder values in .env" >&2
    exit 1
  fi

  if ! command -v "$CODEX_BIN" >/dev/null 2>&1; then
    echo "missing Codex CLI binary: $CODEX_BIN" >&2
    exit 1
  fi

  if [[ "$ALLOWLIST_PATH" != /* ]]; then
    ALLOWLIST_PATH="$ROOT_DIR/$ALLOWLIST_PATH"
  fi

  ensure_dirs
  find "$ROOT_DIR/tmp" -maxdepth 1 \( -name "context_*" -o -name "codex_last_*" \) -mmin +30 -delete 2>/dev/null || true
  if [[ ! -f "$SQLITE_DB_PATH" ]]; then
    sqlite3 "$SQLITE_DB_PATH" < "$ROOT_DIR/sql/schema.sql"
  fi

  api_base="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"
  file_base="https://api.telegram.org/file/bot${TELEGRAM_BOT_TOKEN}"
  log_info "MinusculeClaw ready (mode=$WEBHOOK_MODE, poll_interval=${POLL_INTERVAL_SECONDS}s, exec_policy=$EXEC_POLICY)"
}

extract_marker() {
  local marker="$1"
  local payload="$2"
  printf '%s\n' "$payload" | awk -v m="$marker" 'index($0, m ":") == 1 { sub("^" m ":[[:space:]]*", "", $0); print; exit }'
}

extract_all_markers() {
  local marker="$1"
  local payload="$2"
  printf '%s\n' "$payload" | awk -v m="$marker" 'index($0, m ":") == 1 { sub("^" m ":[[:space:]]*", "", $0); print }'
}

safe_send_text() {
  local msg="$1"
  if [[ -z "$(trim "$msg")" ]]; then
    return 0
  fi
  "$ROOT_DIR/send_telegram.sh" --text "$msg"
}

safe_send_voice() {
  local text="$1"
  local caption="${2:-}"
  local voice_file
  voice_file="$ROOT_DIR/tmp/reply_$(date +%s%N).ogg"

  if "$ROOT_DIR/tts_to_voice.sh" "$text" "$voice_file" >/dev/null; then
    local -a send_cmd
    send_cmd=("$ROOT_DIR/send_telegram.sh" --voice "$voice_file")
    if [[ -n "$caption" ]]; then
      send_cmd+=(--caption "$caption")
    fi
    "${send_cmd[@]}"
    if [[ "${LOCAL_SPEAKER_PLAYBACK:-off}" == "on" ]]; then
      : "${SPEAKER_PLAY_CMD:=ffplay -nodisp -autoexit \"$VOICE_FILE\"}"
      VOICE_FILE="$voice_file" bash -lc "$SPEAKER_PLAY_CMD" >/dev/null 2>&1 &
    fi
    rm -f "$voice_file"
    return 0
  fi

  rm -f "$voice_file"
  return 1
}

append_memory_and_tasks() {
  local codex_output="$1"
  local ts
  ts="$(iso_now)"

  local memory_lines
  memory_lines="$(extract_all_markers "MEMORY_APPEND" "$codex_output" || true)"
  if [[ -n "$(trim "$memory_lines")" ]]; then
    while IFS= read -r line; do
      [[ -z "$(trim "$line")" ]] && continue
      printf -- "- %s | %s\n" "$ts" "$line" >> "$ROOT_DIR/MEMORY.md"
    done <<< "$memory_lines"
  fi

  local task_lines
  task_lines="$(extract_all_markers "TASK_APPEND" "$codex_output" || true)"
  if [[ -n "$(trim "$task_lines")" ]]; then
    while IFS= read -r line; do
      [[ -z "$(trim "$line")" ]] && continue
      ( flock 9; printf -- "- [ ] %s\n" "$line" >> "$ROOT_DIR/TASKS/pending.md" ) 9>"$ROOT_DIR/TASKS/pending.md.lock"
      sqlite_exec "INSERT INTO tasks(ts, source, content, done) VALUES($(sql_quote "$ts"), $(sql_quote "codex"), $(sql_quote "$line"), 0);"
    done <<< "$task_lines"
  fi
}

recent_turns_snippet() {
  sqlite3 "$SQLITE_DB_PATH" <<'SQL'
.headers off
.mode list
.separator "\n"
SELECT ts || ' | in=' || COALESCE(REPLACE(user_text, char(10), ' '), '') || ' | out=' || COALESCE(REPLACE(COALESCE(telegram_reply, voice_reply), char(10), ' '), '')
FROM turns
ORDER BY id DESC
LIMIT 8;
SQL
}

build_context_file() {
  local input_type="$1"
  local user_text="$2"
  local asr_text="$3"
  local context_file="$4"
  local attachment_type="${5:-}"
  local attachment_path="${6:-}"

  {
    echo "# MinusculeClaw Runtime Context"
    echo ""
    echo "Timestamp: $(iso_now)"
    echo "Input type: $input_type"
    echo "Exec policy: $EXEC_POLICY"
    echo "Allowlist path: $ALLOWLIST_PATH"
    echo ""
    echo "## SOUL.md"
    cat "$ROOT_DIR/SOUL.md"
    echo ""
    echo "## USER.md"
    if [[ -f "$ROOT_DIR/USER.md" ]]; then
      cat "$ROOT_DIR/USER.md"
    else
      echo "(missing USER.md)"
    fi
    echo ""
    echo "## MEMORY.md"
    cat "$ROOT_DIR/MEMORY.md"
    echo ""
    echo "## TASKS/pending.md"
    cat "$ROOT_DIR/TASKS/pending.md"
    echo ""
    echo "## Recent turns"
    recent_turns_snippet || true
    echo ""
    echo "## Current user input"
    echo "USER_TEXT: $user_text"
    if [[ -n "$(trim "$asr_text")" ]]; then
      echo "ASR_TEXT: $asr_text"
    fi
    if [[ -n "$attachment_type" && -n "$attachment_path" ]]; then
      echo "ATTACHMENT_TYPE: $attachment_type"
      echo "ATTACHMENT_PATH: $attachment_path"
      echo "The user sent a $attachment_type. The file has been downloaded to the path above. You can access and analyze it using your tools."
    fi
    echo ""
    echo "## Output requirements"
    echo "Return only plain text marker lines. No prose before or after markers."
    echo "Required first line format:"
    echo "TELEGRAM_REPLY: <reply text>"
    echo "Optional additional lines:"
    echo "VOICE_REPLY: <spoken reply text>"
    echo "MEMORY_APPEND: <single memory line>"
    echo "TASK_APPEND: <single task line>"
    echo "Do not use markdown, code fences, or extra prefixes."
  } > "$context_file"
}

run_codex() {
  local context_file="$1"
  local out_file
  out_file="$ROOT_DIR/tmp/codex_last_$(date +%s%N).txt"
  local -a cmd
  cmd=("$CODEX_BIN" exec --cd "$ROOT_DIR" --skip-git-repo-check --output-last-message "$out_file")

  case "$EXEC_POLICY" in
    yolo)
      cmd+=(--dangerously-bypass-approvals-and-sandbox)
      ;;
    allowlist)
      cmd+=(--full-auto)
      ;;
    strict)
      ;;
    *)
      echo "invalid EXEC_POLICY: $EXEC_POLICY" >&2
      return 2
      ;;
  esac

  if [[ -n "${CODEX_MODEL:-}" ]]; then
    cmd+=(--model "$CODEX_MODEL")
  fi

  local cli_out=""
  set +e
  cli_out="$("${cmd[@]}" < "$context_file" 2>&1)"
  local rc=$?
  set -e

  local final_msg=""
  if [[ -f "$out_file" ]]; then
    final_msg="$(cat "$out_file")"
    rm -f "$out_file"
  fi

  if [[ $rc -eq 0 && -n "$(trim "$final_msg")" ]]; then
    printf "%s\n" "$final_msg"
    return 0
  fi

  if [[ -n "$(trim "$cli_out")" ]]; then
    printf "%s\n" "$cli_out"
  fi
  return $rc
}

store_turn() {
  local ts="$1"
  local chat_id="$2"
  local input_type="$3"
  local user_text="$4"
  local asr_text="$5"
  local codex_raw="$6"
  local telegram_reply="$7"
  local voice_reply="$8"
  local status="$9"

  sqlite_exec "INSERT INTO turns(ts, chat_id, input_type, user_text, asr_text, codex_raw, telegram_reply, voice_reply, status) VALUES($(sql_quote "$ts"), $(sql_quote "$chat_id"), $(sql_quote "$input_type"), $(sql_quote "$user_text"), $(sql_quote "$asr_text"), $(sql_quote "$codex_raw"), $(sql_quote "$telegram_reply"), $(sql_quote "$voice_reply"), $(sql_quote "$status"));"
}

handle_user_message() {
  local input_type="$1"
  local user_text="$2"
  local asr_text="$3"
  local chat_id="$4"
  local attachment_type="${5:-}"
  local attachment_path="${6:-}"

  local ts
  ts="$(iso_now)"
  log_info "processing input_type=$input_type chat_id=$chat_id"
  local context_file
  context_file="$ROOT_DIR/tmp/context_$(date +%s%N).md"
  build_context_file "$input_type" "$user_text" "$asr_text" "$context_file" "$attachment_type" "$attachment_path"

  local codex_output=""
  local codex_status="ok"
  set +e
  codex_output="$(run_codex "$context_file" 2>&1)"
  local codex_rc=$?
  set -e
  rm -f "$context_file"

  if [[ $codex_rc -ne 0 ]]; then
    codex_status="codex_error"
  fi

  local telegram_reply voice_reply
  telegram_reply="$(extract_marker "TELEGRAM_REPLY" "$codex_output" || true)"
  voice_reply="$(extract_marker "VOICE_REPLY" "$codex_output" || true)"

  telegram_reply="$(trim "$telegram_reply")"
  voice_reply="$(trim "$voice_reply")"

  if [[ -z "$telegram_reply" && -z "$voice_reply" ]]; then
    if [[ $codex_rc -ne 0 ]]; then
      local err_line
      err_line="$(printf '%s\n' "$codex_output" | head -n 1)"
      telegram_reply="Codex execution failed locally. ${err_line:-Please check local logs and retry.}"
      codex_status="codex_error"
    else
      telegram_reply="I hit a parser issue on my side. Please resend that in text while I recover."
      codex_status="parse_fallback"
    fi
  fi

  if [[ "$input_type" == "voice" ]]; then
    local spoken_text="$voice_reply"
    if [[ -z "$spoken_text" ]]; then
      spoken_text="$telegram_reply"
    fi
    if ! safe_send_voice "$spoken_text"; then
      safe_send_text "$telegram_reply"
    fi
  else
    if [[ -n "$telegram_reply" ]]; then
      safe_send_text "$telegram_reply"
    elif [[ -n "$voice_reply" ]]; then
      if ! safe_send_voice "$voice_reply"; then
        safe_send_text "Voice output failed locally; please retry."
      fi
    fi
  fi

  append_memory_and_tasks "$codex_output"
  store_turn "$ts" "$chat_id" "$input_type" "$user_text" "$asr_text" "$codex_output" "$telegram_reply" "$voice_reply" "$codex_status"
  log_info "reply complete status=$codex_status"

  if [[ -n "$attachment_path" && -f "$attachment_path" ]]; then
    rm -f "$attachment_path"
  fi

  local log_block
  log_block="$({
    echo "## $ts"
    echo "- input_type: $input_type"
    echo "- user_text: $user_text"
    if [[ -n "$(trim "$asr_text")" ]]; then
      echo "- asr_text: $asr_text"
    fi
    if [[ -n "$attachment_type" ]]; then
      echo "- attachment_type: $attachment_type"
    fi
    echo "- telegram_reply: ${telegram_reply:-<none>}"
    echo "- voice_reply: ${voice_reply:-<none>}"
    echo "- status: $codex_status"
    echo ""
  })"
  append_daily_log "$log_block"
}

telegram_get_updates() {
  local offset="$1"
  local timeout="${2:-25}"
  curl -fsS "$api_base/getUpdates" \
    -d "offset=$offset" \
    -d "timeout=$timeout" \
    -d 'allowed_updates=["message"]'
}

download_telegram_file() {
  local file_id="$1"
  local out_path="$2"
  local file_resp file_path
  file_resp="$(curl -fsS "$api_base/getFile" -d "file_id=$file_id")"
  file_path="$(jq -r '.result.file_path // empty' <<< "$file_resp")"
  if [[ -z "$file_path" ]]; then
    return 1
  fi
  curl -fsS "$file_base/$file_path" -o "$out_path"
}

process_update_obj() {
  local obj="$1"
  local update_id chat_id message_text voice_file_id input_type

  update_id="$(jq -r '.update_id // 0' <<< "$obj")"
  chat_id="$(jq -r '.message.chat.id // empty' <<< "$obj")"

  if [[ -z "$chat_id" ]]; then
    log_debug "update_id=$update_id has no chat_id; skipping"
    set_kv "last_update_id" "$update_id"
    return 0
  fi

  message_text="$(jq -r '.message.text // .message.caption // empty' <<< "$obj")"
  voice_file_id="$(jq -r '.message.voice.file_id // empty' <<< "$obj")"

  input_type="text"
  local asr_text=""
  local effective_text="$message_text"

  if [[ -n "$voice_file_id" ]]; then
    input_type="voice"
    local voice_in="$ROOT_DIR/tmp/in_${update_id}.oga"
    if download_telegram_file "$voice_file_id" "$voice_in"; then
      set +e
      asr_text="$("$ROOT_DIR/asr.sh" "$voice_in")"
      local asr_rc=$?
      set -e
      rm -f "$voice_in"
      if [[ $asr_rc -eq 0 && -n "$(trim "$asr_text")" ]]; then
        effective_text="$asr_text"
      else
        log_warn "ASR failed for update_id=$update_id; using fallback text/caption path"
      fi
    fi
  fi

  # Detect file attachments (photo, document, video, video_note)
  local attachment_type="" attachment_path=""
  local photo_file_id
  photo_file_id="$(jq -r '.message.photo[-1].file_id // empty' <<< "$obj")"
  local doc_file_id doc_file_name
  doc_file_id="$(jq -r '.message.document.file_id // empty' <<< "$obj")"
  doc_file_name="$(jq -r '.message.document.file_name // "document"' <<< "$obj")"
  local video_file_id
  video_file_id="$(jq -r '.message.video.file_id // empty' <<< "$obj")"
  local videonote_file_id
  videonote_file_id="$(jq -r '.message.video_note.file_id // empty' <<< "$obj")"

  if [[ -n "$photo_file_id" ]]; then
    attachment_type="photo"
    attachment_path="$ROOT_DIR/tmp/photo_${update_id}.jpg"
    if ! download_telegram_file "$photo_file_id" "$attachment_path"; then
      log_warn "failed to download photo for update_id=$update_id"
      attachment_type="" attachment_path=""
    else
      input_type="photo"
    fi
  elif [[ -n "$doc_file_id" ]]; then
    attachment_type="document"
    local ext="${doc_file_name##*.}"
    attachment_path="$ROOT_DIR/tmp/doc_${update_id}.${ext}"
    if ! download_telegram_file "$doc_file_id" "$attachment_path"; then
      log_warn "failed to download document for update_id=$update_id"
      attachment_type="" attachment_path=""
    else
      input_type="document"
    fi
  elif [[ -n "$video_file_id" ]]; then
    attachment_type="video"
    attachment_path="$ROOT_DIR/tmp/video_${update_id}.mp4"
    if ! download_telegram_file "$video_file_id" "$attachment_path"; then
      log_warn "failed to download video for update_id=$update_id"
      attachment_type="" attachment_path=""
    else
      input_type="video"
    fi
  elif [[ -n "$videonote_file_id" ]]; then
    attachment_type="video_note"
    attachment_path="$ROOT_DIR/tmp/videonote_${update_id}.mp4"
    if ! download_telegram_file "$videonote_file_id" "$attachment_path"; then
      log_warn "failed to download video_note for update_id=$update_id"
      attachment_type="" attachment_path=""
    else
      input_type="video_note"
    fi
  fi

  if [[ -z "$(trim "$effective_text")" ]]; then
    effective_text="(empty message)"
  fi

  if [[ "$chat_id" == "$TELEGRAM_CHAT_ID" ]]; then
    log_debug "accepted update_id=$update_id for configured chat_id"
    handle_user_message "$input_type" "$effective_text" "$asr_text" "$chat_id" "$attachment_type" "$attachment_path"
  else
    log_debug "ignored update_id=$update_id for unmatched chat_id=$chat_id"
  fi

  set_kv "last_update_id" "$update_id"
}

consume_webhook_queue_line() {
  local queue_file="$ROOT_DIR/runtime/webhook_updates.jsonl"
  if [[ ! -s "$queue_file" ]]; then
    return 1
  fi

  local line
  line="$(head -n 1 "$queue_file")"
  tail -n +2 "$queue_file" > "$queue_file.tmp" || true
  mv "$queue_file.tmp" "$queue_file"
  printf '%s\n' "$line"
}

poll_once() {
  local last_id offset resp
  last_id="$(get_kv "last_update_id")"
  if [[ -z "$last_id" ]]; then
    last_id="0"
  fi
  offset=$((last_id + 1))

  set +e
  resp="$(telegram_get_updates "$offset" 20 2>/dev/null)"
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    poll_fail_count=$((poll_fail_count + 1))
    if (( poll_fail_count % 5 == 0 )); then
      log_warn "telegram polling failed $poll_fail_count times consecutively"
    fi
    return 0
  fi

  if (( poll_fail_count > 0 )); then
    log_info "telegram polling recovered after $poll_fail_count failures"
  fi
  poll_fail_count=0

  local count
  count="$(jq -r '.result | length' <<< "$resp")"
  if [[ "$count" == "0" ]]; then
    empty_polls=$((empty_polls + 1))
    if (( empty_polls % 3 == 0 )); then
      log_info "waiting for updates (offset=$offset)"
    fi
    return 0
  fi

  empty_polls=0
  log_info "received $count update(s)"
  while IFS= read -r obj; do
    process_update_obj "$obj"
  done < <(jq -c '.result[]?' <<< "$resp")
}

main_loop() {
  log_info "agent loop started"
  while true; do
    local handled=0
    if [[ "$WEBHOOK_MODE" == "on" ]]; then
      local webhook_obj
      set +e
      webhook_obj="$(consume_webhook_queue_line)"
      local w_rc=$?
      set -e
      if [[ $w_rc -eq 0 && -n "$(trim "$webhook_obj")" ]]; then
        process_update_obj "$webhook_obj"
        handled=1
      fi
    fi

    if [[ $handled -eq 0 ]]; then
      poll_once
    fi

    sleep "$POLL_INTERVAL_SECONDS"
  done
}

usage() {
  cat <<USAGE
usage: $0 [--once] [--inject-text <text>] [--inject-file <path>] [--chat-id <chat-id>]
USAGE
}

inject_text=""
inject_file=""
once="false"
inject_chat_id=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --once)
      once="true"
      shift
      ;;
    --inject-text)
      inject_text="$2"
      shift 2
      ;;
    --inject-file)
      inject_file="$2"
      shift 2
      ;;
    --chat-id)
      inject_chat_id="$2"
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      usage
      exit 1
      ;;
  esac
done

validate_runtime_requirements

if [[ -n "$inject_text" || -n "$inject_file" ]]; then
  if [[ -z "$inject_chat_id" ]]; then
    inject_chat_id="$TELEGRAM_CHAT_ID"
  fi
  local_attach_type=""
  local_attach_path=""
  local_input_type="text"
  if [[ -n "$inject_file" ]]; then
    [[ "$inject_file" != /* ]] && inject_file="$ROOT_DIR/$inject_file"
    if [[ ! -f "$inject_file" ]]; then
      echo "inject file not found: $inject_file" >&2
      exit 1
    fi
    local_attach_path="$inject_file"
    case "${inject_file,,}" in
      *.jpg|*.jpeg|*.png|*.gif|*.webp|*.bmp)
        local_attach_type="photo"; local_input_type="photo" ;;
      *.mp4|*.mkv|*.avi|*.mov|*.webm)
        local_attach_type="video"; local_input_type="video" ;;
      *)
        local_attach_type="document"; local_input_type="document" ;;
    esac
  fi
  : "${inject_text:=(empty message)}"
  handle_user_message "$local_input_type" "$inject_text" "" "$inject_chat_id" "$local_attach_type" "$local_attach_path"
  exit 0
fi

if [[ "$once" == "true" ]]; then
  if [[ "$WEBHOOK_MODE" == "on" ]]; then
    set +e
    single_obj="$(consume_webhook_queue_line)"
    single_rc=$?
    set -e
    if [[ $single_rc -eq 0 && -n "$(trim "$single_obj")" ]]; then
      process_update_obj "$single_obj"
      exit 0
    fi
  fi
  poll_once
  exit 0
fi

main_loop
