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
CANCEL_FILE="$ROOT_DIR/runtime/cancel"
CODEX_PID_FILE="$ROOT_DIR/runtime/codex.pid"

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

ensure_db_migrations() {
  local has_turns
  has_turns="$(sqlite3 "$SQLITE_DB_PATH" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='turns' LIMIT 1;")"
  if [[ "$has_turns" != "1" ]]; then
    sqlite3 "$SQLITE_DB_PATH" < "$ROOT_DIR/sql/schema.sql"
  fi

  local has_update_id
  has_update_id="$(sqlite3 "$SQLITE_DB_PATH" "SELECT 1 FROM pragma_table_info('turns') WHERE name='update_id' LIMIT 1;")"
  if [[ "$has_update_id" != "1" ]]; then
    log_info "db migration: adding turns.update_id column"
    sqlite_exec "ALTER TABLE turns ADD COLUMN update_id TEXT;"
  fi

  sqlite_exec "CREATE UNIQUE INDEX IF NOT EXISTS idx_turns_update_id_unique ON turns(update_id);"
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
  find "$ROOT_DIR/tmp" -maxdepth 1 \( -name "context_*" -o -name "codex_last_*" -o -name "codex_pipe_*" -o -name "codex_stdout_*" \) -mmin +30 -delete 2>/dev/null || true
  rm -f "$CANCEL_FILE" "$CODEX_PID_FILE"
  if [[ ! -f "$SQLITE_DB_PATH" ]]; then
    sqlite3 "$SQLITE_DB_PATH" < "$ROOT_DIR/sql/schema.sql"
  fi
  ensure_db_migrations

  api_base="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"
  file_base="https://api.telegram.org/file/bot${TELEGRAM_BOT_TOKEN}"
  if [[ "$WEBHOOK_MODE" == "on" ]]; then
    log_info "ShellClaw ready (mode=webhook, exec_policy=$EXEC_POLICY)"
  else
    log_info "ShellClaw ready (mode=poll, poll_interval=${POLL_INTERVAL_SECONDS}s, exec_policy=$EXEC_POLICY)"
  fi
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
  "$ROOT_DIR/scripts/telegram_api.sh" --text "$msg"
}

safe_send_voice() {
  local text="$1"
  local caption="${2:-}"
  local voice_file
  voice_file="$ROOT_DIR/tmp/reply_$(date +%s%N).ogg"

  if "$ROOT_DIR/scripts/tts.sh" "$text" "$voice_file" >/dev/null; then
    local -a send_cmd
    send_cmd=("$ROOT_DIR/scripts/telegram_api.sh" --voice "$voice_file")
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

send_or_edit_text() {
  local msg_id="$1"
  local text="$2"
  if [[ -z "$(trim "$text")" ]]; then
    return 0
  fi
  # Remove inline keyboard if present
  if [[ -n "$msg_id" ]]; then
    "$ROOT_DIR/scripts/telegram_api.sh" --remove-keyboard "$msg_id" 2>/dev/null || true
  fi
  local max=4096
  if (( ${#text} <= max )); then
    if [[ -n "$msg_id" ]] && "$ROOT_DIR/scripts/telegram_api.sh" --edit "$msg_id" --text "$text" 2>/dev/null; then
      return 0
    fi
    "$ROOT_DIR/scripts/telegram_api.sh" --text "$text"
    return 0
  fi
  # Long message: edit progress with first chunk, send rest as new messages
  local offset=0 first="true"
  while (( offset < ${#text} )); do
    local chunk="${text:offset:max}"
    if [[ "$first" == "true" && -n "$msg_id" ]]; then
      "$ROOT_DIR/scripts/telegram_api.sh" --edit "$msg_id" --text "$chunk" 2>/dev/null \
        || "$ROOT_DIR/scripts/telegram_api.sh" --text "$chunk"
      first="false"
    else
      "$ROOT_DIR/scripts/telegram_api.sh" --text "$chunk"
    fi
    offset=$((offset + max))
  done
}

codex_stream_monitor() {
  local msg_id="$1"
  local last_edit_ts=0
  local status_log=""
  while IFS= read -r line; do
    local etype status_text=""
    etype="$(jq -r '.type // empty' <<< "$line" 2>/dev/null)" || continue
    case "$etype" in
      turn.started) status_text="⚡ Processing…" ;;
      item.started)
        local itype
        itype="$(jq -r '.item.type // empty' <<< "$line" 2>/dev/null)"
        case "$itype" in
          command_execution)
            local icmd
            icmd="$(jq -r '.item.command // empty' <<< "$line" 2>/dev/null)"
            status_text="🔧 ${icmd:0:120}" ;;
          reasoning) status_text="🤔 Reasoning…" ;;
        esac ;;
      item.completed)
        local itype
        itype="$(jq -r '.item.type // empty' <<< "$line" 2>/dev/null)"
        case "$itype" in
          file_change)
            local fp
            fp="$(jq -r '.item.file_path // empty' <<< "$line" 2>/dev/null)"
            status_text="📝 Edited: ${fp}" ;;
        esac ;;
    esac
    if [[ -n "$status_text" ]]; then
      if [[ -n "$status_log" ]]; then
        status_log="${status_log}
${status_text}"
      else
        status_log="$status_text"
      fi
      local now
      now="$(date +%s)"
      if (( now - last_edit_ts >= 3 )); then
        local edit_text="$status_log"
        if (( ${#edit_text} > 4000 )); then
          edit_text="…${edit_text: -3900}"
        fi
        "$ROOT_DIR/scripts/telegram_api.sh" --edit "$msg_id" --text "$edit_text" --with-cancel-btn 2>/dev/null || true
        "$ROOT_DIR/scripts/telegram_api.sh" --typing 2>/dev/null || true
        last_edit_ts=$now
      fi
    fi
  done
  if [[ -n "$status_log" ]]; then
    local edit_text="$status_log"
    if (( ${#edit_text} > 4000 )); then
      edit_text="…${edit_text: -3900}"
    fi
    "$ROOT_DIR/scripts/telegram_api.sh" --edit "$msg_id" --text "$edit_text" 2>/dev/null || true
  fi
}

check_cancel_poll() {
  local last_id offset resp
  last_id="$(get_kv "last_update_id" 2>/dev/null)" || true
  [[ -z "$last_id" ]] && last_id="0"
  offset=$((last_id + 1))

  resp="$(curl -fsS "$api_base/getUpdates" \
    -d "offset=$offset" -d "timeout=0" \
    -d 'allowed_updates=["message","callback_query"]' 2>/dev/null)" || return 0

  local cancel_uid cancel_cb_id
  cancel_uid="$(jq -r --arg cid "$TELEGRAM_CHAT_ID" '
    [.result[] | select(
      (.message.chat.id | tostring) == $cid and
      ((.message.text // "") | test("^/cancel$"; "i"))
    )] | last | .update_id // empty
  ' <<< "$resp" 2>/dev/null)" || return 0

  cancel_cb_id="$(jq -r --arg cid "$TELEGRAM_CHAT_ID" '
    [.result[] | select(
      (.callback_query.message.chat.id | tostring) == $cid and
      (.callback_query.data // "") == "cancel"
    )] | last | .callback_query.id // empty
  ' <<< "$resp" 2>/dev/null)" || return 0

  if [[ -n "$cancel_cb_id" ]]; then
    log_info "cancel button callback detected"
    "$ROOT_DIR/scripts/telegram_api.sh" --answer-callback "$cancel_cb_id" 2>/dev/null || true
    touch "$CANCEL_FILE"
  elif [[ -n "$cancel_uid" ]]; then
    log_info "cancel command detected via poll (update_id=$cancel_uid)"
    touch "$CANCEL_FILE"
  fi
}

cancel_watcher() {
  local codex_pid="$1"

  while kill -0 "$codex_pid" 2>/dev/null; do
    if [[ -f "$CANCEL_FILE" ]]; then
      log_info "cancel signal: killing codex pid=$codex_pid"
      kill -TERM "$codex_pid" 2>/dev/null || true
      sleep 2
      if kill -0 "$codex_pid" 2>/dev/null; then
        kill -KILL "$codex_pid" 2>/dev/null || true
      fi
      return 0
    fi
    if [[ "$WEBHOOK_MODE" != "on" ]]; then
      check_cancel_poll
    fi
    sleep 2
  done
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
    echo "# ShellClaw Runtime Context"
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
    echo "SEND_PHOTO: <absolute file path>"
    echo "SEND_DOCUMENT: <absolute file path>"
    echo "SEND_VIDEO: <absolute file path>"
    echo "MEMORY_APPEND: <single memory line>"
    echo "TASK_APPEND: <single task line>"
    echo "Do not use markdown, code fences, or extra prefixes."
  } > "$context_file"
}

run_codex() {
  local context_file="$1"
  local progress_msg_id="${2:-}"
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

  rm -f "$CANCEL_FILE" "$CODEX_PID_FILE"
  local cli_out="" rc=0

  if [[ -n "$progress_msg_id" ]]; then
    cmd+=(--json)
    local pipe="$ROOT_DIR/tmp/codex_pipe_$$.fifo"
    mkfifo "$pipe"

    set +e
    "${cmd[@]}" < "$context_file" > "$pipe" 2>/dev/null &
    local codex_pid=$!
    echo "$codex_pid" > "$CODEX_PID_FILE"

    cancel_watcher "$codex_pid" &
    local watcher_pid=$!

    codex_stream_monitor "$progress_msg_id" < "$pipe"
    wait "$codex_pid" 2>/dev/null
    rc=$?
    set -e

    kill "$watcher_pid" 2>/dev/null || true
    wait "$watcher_pid" 2>/dev/null || true
    rm -f "$pipe"
  else
    local tmp_out="$ROOT_DIR/tmp/codex_stdout_$$.txt"
    set +e
    "${cmd[@]}" < "$context_file" > "$tmp_out" 2>&1 &
    local codex_pid=$!
    echo "$codex_pid" > "$CODEX_PID_FILE"

    cancel_watcher "$codex_pid" &
    local watcher_pid=$!

    wait "$codex_pid" 2>/dev/null
    rc=$?
    set -e

    kill "$watcher_pid" 2>/dev/null || true
    wait "$watcher_pid" 2>/dev/null || true
    cli_out="$(cat "$tmp_out" 2>/dev/null || true)"
    rm -f "$tmp_out"
  fi

  rm -f "$CODEX_PID_FILE"

  if [[ -f "$CANCEL_FILE" ]]; then
    rm -f "$CANCEL_FILE" "$out_file"
    return 130
  fi

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

turn_exists_for_update_id() {
  local update_id="$1"
  if [[ -z "$(trim "$update_id")" ]]; then
    return 1
  fi

  local found
  found="$(sqlite3 "$SQLITE_DB_PATH" "SELECT 1 FROM turns WHERE update_id=$(sql_quote "$update_id") LIMIT 1;")"
  [[ "$found" == "1" ]]
}

set_inflight_update() {
  local update_id="$1"
  local payload_json="$2"
  local started_at
  started_at="$(iso_now)"

  set_kv "inflight_update_id" "$update_id"
  set_kv "inflight_update_json" "$payload_json"
  set_kv "inflight_started_at" "$started_at"
}

clear_inflight_update() {
  sqlite_exec "DELETE FROM kv WHERE key IN ('inflight_update_id', 'inflight_update_json', 'inflight_started_at');"
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
  local update_id="${10:-}"
  local update_id_sql="NULL"
  if [[ -n "$(trim "$update_id")" ]]; then
    update_id_sql="$(sql_quote "$update_id")"
  fi

  local changes
  changes="$(sqlite3 "$SQLITE_DB_PATH" "INSERT OR IGNORE INTO turns(ts, chat_id, input_type, user_text, asr_text, codex_raw, telegram_reply, voice_reply, status, update_id) VALUES($(sql_quote "$ts"), $(sql_quote "$chat_id"), $(sql_quote "$input_type"), $(sql_quote "$user_text"), $(sql_quote "$asr_text"), $(sql_quote "$codex_raw"), $(sql_quote "$telegram_reply"), $(sql_quote "$voice_reply"), $(sql_quote "$status"), $update_id_sql); SELECT changes();")"
  changes="${changes##*$'\n'}"
  printf '%s\n' "${changes:-0}"
}

handle_user_message() {
  local input_type="$1"
  local user_text="$2"
  local asr_text="$3"
  local chat_id="$4"
  local attachment_type="${5:-}"
  local attachment_path="${6:-}"
  local update_id="${7:-}"
  local attachment_owned="${8:-false}"

  local ts
  ts="$(iso_now)"
  log_info "processing input_type=$input_type chat_id=$chat_id"
  local context_file
  context_file="$ROOT_DIR/tmp/context_$(date +%s%N).md"
  build_context_file "$input_type" "$user_text" "$asr_text" "$context_file" "$attachment_type" "$attachment_path"

  local progress_msg_id=""
  progress_msg_id="$("$ROOT_DIR/scripts/telegram_api.sh" --text "⏳ Thinking…" --return-id --with-cancel-btn 2>/dev/null)" || true
  "$ROOT_DIR/scripts/telegram_api.sh" --typing 2>/dev/null || true

  local codex_output=""
  local codex_status="ok"
  set +e
  codex_output="$(run_codex "$context_file" "$progress_msg_id" 2>&1)"
  local codex_rc=$?
  set -e
  rm -f "$context_file"

  if [[ $codex_rc -eq 130 ]]; then
    send_or_edit_text "$progress_msg_id" "❌ Cancelled."
    local cancel_inserted
    cancel_inserted="$(store_turn "$ts" "$chat_id" "$input_type" "$user_text" "$asr_text" "" "" "" "cancelled" "$update_id")"
    if [[ "$cancel_inserted" != "1" ]]; then
      log_info "dedup skip for cancelled update_id=$update_id"
      cleanup_attachment_path "$attachment_path" "$attachment_owned"
      return 0
    fi
    local cancel_log
    cancel_log="$(printf "## %s\n- input_type: %s\n- user_text: %s\n- status: cancelled\n" "$ts" "$input_type" "$user_text")"
    append_daily_log "$cancel_log"
    cleanup_attachment_path "$attachment_path" "$attachment_owned"
    log_info "request cancelled by user"
    return 0
  fi

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
    if safe_send_voice "$spoken_text"; then
      if [[ -n "$progress_msg_id" ]]; then
        send_or_edit_text "$progress_msg_id" "${telegram_reply:-🔊}"
      fi
    else
      send_or_edit_text "$progress_msg_id" "$telegram_reply"
    fi
  else
    if [[ -n "$telegram_reply" ]]; then
      send_or_edit_text "$progress_msg_id" "$telegram_reply"
    elif [[ -n "$voice_reply" ]]; then
      if safe_send_voice "$voice_reply"; then
        if [[ -n "$progress_msg_id" ]]; then
          send_or_edit_text "$progress_msg_id" "🔊"
        fi
      else
        send_or_edit_text "$progress_msg_id" "Voice output failed locally; please retry."
      fi
    fi
  fi

  # Send file attachments requested by Codex
  local send_files_marker
  for marker_pair in "SEND_PHOTO:photo" "SEND_DOCUMENT:document" "SEND_VIDEO:video"; do
    local m_name="${marker_pair%%:*}"
    local m_mode="${marker_pair##*:}"
    send_files_marker="$(extract_all_markers "$m_name" "$codex_output" || true)"
    if [[ -n "$(trim "$send_files_marker")" ]]; then
      while IFS= read -r fpath; do
        fpath="$(trim "$fpath")"
        [[ -z "$fpath" ]] && continue
        if [[ -f "$fpath" ]]; then
          "$ROOT_DIR/scripts/telegram_api.sh" --"$m_mode" "$fpath" || log_warn "failed to send $m_mode: $fpath"
        else
          log_warn "SEND_${m_mode^^} path not found: $fpath"
        fi
      done <<< "$send_files_marker"
    fi
  done

  local turn_inserted
  turn_inserted="$(store_turn "$ts" "$chat_id" "$input_type" "$user_text" "$asr_text" "$codex_output" "$telegram_reply" "$voice_reply" "$codex_status" "$update_id")"
  if [[ "$turn_inserted" != "1" ]]; then
    log_info "dedup skip for completed update_id=$update_id"
    cleanup_attachment_path "$attachment_path" "$attachment_owned"
    return 0
  fi

  append_memory_and_tasks "$codex_output"
  log_info "reply complete status=$codex_status"

  cleanup_attachment_path "$attachment_path" "$attachment_owned"

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

cleanup_attachment_path() {
  local attachment_path="$1"
  local attachment_owned="${2:-false}"
  if [[ "$attachment_owned" != "true" ]]; then
    return 0
  fi
  if [[ -n "$attachment_path" && -f "$attachment_path" ]]; then
    rm -f "$attachment_path"
  fi
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

extract_update_id() {
  local obj="$1"
  jq -r '.update_id // 0' <<< "$obj" 2>/dev/null || printf '0\n'
}

process_update_obj() {
  local obj="$1"
  local source_mode="${2:-poll}"
  local update_id chat_id message_text voice_file_id input_type turn_update_id

  update_id="$(extract_update_id "$obj")"
  chat_id="$(jq -r '.message.chat.id // empty' <<< "$obj")"
  turn_update_id=""
  if [[ "$update_id" != "0" ]]; then
    turn_update_id="$update_id"
  fi

  if [[ -n "$turn_update_id" ]] && turn_exists_for_update_id "$turn_update_id"; then
    log_info "dedup hit update_id=$turn_update_id source=$source_mode"
    set_kv "last_update_id" "$update_id"
    return 0
  fi

  if [[ -z "$chat_id" ]]; then
    log_debug "update_id=$update_id has no chat_id; skipping"
    set_kv "last_update_id" "$update_id"
    return 0
  fi

  message_text="$(jq -r '.message.text // .message.caption // empty' <<< "$obj")"

  if [[ "$chat_id" == "$TELEGRAM_CHAT_ID" && "${message_text,,}" =~ ^/cancel$ ]]; then
    log_info "ack /cancel update_id=$update_id"
    if [[ -f "$CODEX_PID_FILE" ]]; then
      touch "$CANCEL_FILE"
      local cancel_pid
      cancel_pid="$(cat "$CODEX_PID_FILE" 2>/dev/null)" || true
      if [[ -n "$cancel_pid" ]] && kill -0 "$cancel_pid" 2>/dev/null; then
        kill -TERM "$cancel_pid" 2>/dev/null || true
      fi
    fi
    set_kv "last_update_id" "$update_id"
    return 0
  fi

  if [[ "$chat_id" != "$TELEGRAM_CHAT_ID" ]]; then
    log_debug "ignored update_id=$update_id for unmatched chat_id=$chat_id"
    set_kv "last_update_id" "$update_id"
    return 0
  fi

  voice_file_id="$(jq -r '.message.voice.file_id // empty' <<< "$obj")"

  input_type="text"
  local asr_text=""
  local effective_text="$message_text"

  if [[ -n "$voice_file_id" ]]; then
    input_type="voice"
    local voice_in="$ROOT_DIR/tmp/in_${update_id}.oga"
    if download_telegram_file "$voice_file_id" "$voice_in"; then
      set +e
      asr_text="$("$ROOT_DIR/scripts/asr.sh" "$voice_in")"
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

  if [[ "$source_mode" == "webhook" || "$source_mode" == "webhook_restore" ]]; then
    set_inflight_update "$turn_update_id" "$obj"
  fi

  log_debug "accepted update_id=$update_id for configured chat_id"
  handle_user_message "$input_type" "$effective_text" "$asr_text" "$chat_id" "$attachment_type" "$attachment_path" "$turn_update_id" "true"

  set_kv "last_update_id" "$update_id"
}

peek_webhook_queue_line() {
  local queue_file="$ROOT_DIR/runtime/webhook_updates.jsonl"
  local lock_file="$ROOT_DIR/runtime/webhook_queue.lock"
  (
    flock -w 2 9
    if [[ ! -s "$queue_file" ]]; then
      exit 1
    fi
    head -n 1 "$queue_file"
  ) 9>"$lock_file"
}

ack_webhook_queue_line() {
  local expected_update_id="${1:-}"
  local queue_file="$ROOT_DIR/runtime/webhook_updates.jsonl"
  local lock_file="$ROOT_DIR/runtime/webhook_queue.lock"
  (
    flock -w 2 9
    if [[ ! -s "$queue_file" ]]; then
      exit 1
    fi
    local head_line head_update_id tmp_file
    head_line="$(head -n 1 "$queue_file")"
    if [[ -n "$expected_update_id" ]]; then
      head_update_id="$(extract_update_id "$head_line")"
      if [[ "$head_update_id" != "$expected_update_id" ]]; then
        exit 2
      fi
    fi
    tmp_file="$queue_file.tmp.$$"
    tail -n +2 "$queue_file" > "$tmp_file" || true
    mv "$tmp_file" "$queue_file"
  ) 9>"$lock_file"
}

restore_inflight_update() {
  local inflight_json inflight_update_id ack_rc restore_rc
  inflight_json="$(get_kv "inflight_update_json" 2>/dev/null || true)"
  if [[ -z "$(trim "$inflight_json")" ]]; then
    return 0
  fi

  inflight_update_id="$(get_kv "inflight_update_id" 2>/dev/null || true)"
  if [[ -z "$(trim "$inflight_update_id")" || "$inflight_update_id" == "0" ]]; then
    inflight_update_id="$(extract_update_id "$inflight_json")"
  fi
  if [[ "$inflight_update_id" == "0" ]]; then
    inflight_update_id=""
  fi

  log_info "inflight restore update_id=${inflight_update_id:-unknown}"
  if [[ -n "$inflight_update_id" ]] && turn_exists_for_update_id "$inflight_update_id"; then
    log_info "dedup hit during inflight restore update_id=$inflight_update_id"
    clear_inflight_update
    set +e
    ack_webhook_queue_line "$inflight_update_id"
    ack_rc=$?
    set -e
    if [[ $ack_rc -eq 0 ]]; then
      log_info "webhook ack update_id=$inflight_update_id (restore dedup)"
    elif [[ $ack_rc -eq 2 ]]; then
      log_warn "webhook ack skipped on restore due head mismatch update_id=$inflight_update_id"
    else
      log_warn "webhook ack failed on restore update_id=$inflight_update_id rc=$ack_rc"
    fi
    return 0
  fi

  set +e
  process_update_obj "$inflight_json" "webhook_restore"
  restore_rc=$?
  set -e
  if [[ $restore_rc -ne 0 ]]; then
    log_warn "inflight restore failed update_id=${inflight_update_id:-unknown} rc=$restore_rc"
    return $restore_rc
  fi

  clear_inflight_update
  if [[ -n "$inflight_update_id" ]]; then
    set +e
    ack_webhook_queue_line "$inflight_update_id"
    ack_rc=$?
    set -e
    if [[ $ack_rc -eq 0 ]]; then
      log_info "webhook ack update_id=$inflight_update_id (restore)"
    elif [[ $ack_rc -eq 2 ]]; then
      log_warn "webhook ack skipped on restore due head mismatch update_id=$inflight_update_id"
    else
      log_warn "webhook ack failed on restore update_id=$inflight_update_id rc=$ack_rc"
    fi
  else
    log_warn "restore completed without update_id; leaving queue head untouched"
  fi
}

drain_webhook_queue() {
  while true; do
    local obj rc update_id ack_rc
    set +e
    obj="$(peek_webhook_queue_line)"
    rc=$?
    set -e
    if [[ $rc -ne 0 || -z "$(trim "$obj")" ]]; then
      break
    fi

    update_id="$(extract_update_id "$obj")"
    log_debug "webhook peek update_id=$update_id"

    set +e
    process_update_obj "$obj" "webhook"
    rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
      log_warn "webhook processing failed update_id=$update_id rc=$rc (will retry)"
      break
    fi

    clear_inflight_update
    set +e
    if [[ "$update_id" != "0" ]]; then
      ack_webhook_queue_line "$update_id"
    else
      ack_webhook_queue_line
    fi
    ack_rc=$?
    set -e
    if [[ $ack_rc -eq 0 ]]; then
      log_info "webhook ack update_id=$update_id"
      continue
    fi
    if [[ $ack_rc -eq 2 ]]; then
      log_warn "webhook ack skipped due head mismatch update_id=$update_id"
    else
      log_warn "webhook ack failed update_id=$update_id rc=$ack_rc"
    fi
    break
  done
}

webhook_loop() {
  local queue_file="$ROOT_DIR/runtime/webhook_updates.jsonl"
  local notify_fifo="$ROOT_DIR/runtime/webhook_notify.fifo"
  touch "$queue_file"

  # Create notification FIFO if missing
  if [[ ! -p "$notify_fifo" ]]; then
    rm -f "$notify_fifo"
    mkfifo "$notify_fifo"
  fi

  # Open FIFO read-write on fd 3 to prevent EOF when last writer disconnects
  exec 3<>"$notify_fifo"
  log_info "webhook loop: waiting on $notify_fifo"

  restore_inflight_update || true
  drain_webhook_queue

  while true; do
    # Block until services/webhook_server.py signals or 30s safety timeout
    read -r -t 30 -n 1 <&3 || true
    drain_webhook_queue
  done
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
  log_info "poll loop started (interval=${POLL_INTERVAL_SECONDS}s)"
  while true; do
    poll_once
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
    drain_webhook_queue
  else
    poll_once
  fi
  exit 0
fi

if [[ "$WEBHOOK_MODE" == "on" ]]; then
  webhook_loop
else
  main_loop
fi
