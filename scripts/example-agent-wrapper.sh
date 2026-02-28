#!/usr/bin/env bash
# example-agent-wrapper.sh — Template wrapper for AGENT_PROVIDER=script
#
# This is an EXAMPLE showing how to add streaming progress updates to any
# CLI agent that supports a JSON/NDJSON streaming output mode. Adapt it to
# your specific CLI tool.
#
# Usage in .env:
#   AGENT_PROVIDER=script
#   AGENT_CMD_TEMPLATE='./scripts/example-agent-wrapper.sh'
#
# Environment (exported by run_script_agent in agent.sh):
#   AGENT_CONTEXT_FILE    — path to the context markdown file (also piped via stdin)
#   AGENT_PROGRESS_MSG_ID — Telegram message ID for progress edits (may be empty)
#
# Contract:
#   stdin  — full context markdown
#   stdout — marker lines: TELEGRAM_REPLY:, VOICE_REPLY:, MEMORY_APPEND:, etc.
#   exit 0 on success, non-zero on failure
#
# ── Adapt the sections marked CUSTOMISE below ──────────────────────────────
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/common.sh"
load_env

# ── CUSTOMISE: CLI command template ────────────────────────────────────────
# Replace with your agent CLI invocation (evaluated via bash -lc).
# Example: Gemini CLI in headless mode with streaming JSON output.
# shellcheck disable=SC2016
: "${WRAPPER_CMD_TEMPLATE:=gemini -p \"\" -o stream-json --yolo}"
# For non-streaming mode, set WRAPPER_STREAM=off (skips progress updates).
: "${WRAPPER_STREAM:=on}"

# ── CUSTOMISE: how to extract status lines from stream events ──────────────
# This function receives one NDJSON line and should print a short status
# string (emoji + text) or nothing.  Adapt to your CLI's streaming schema.
#
# Gemini stream-json events used here:
#   init            → session started
#   tool_use        → .tool_name, .parameters = tool being called
#   tool_result     → .status, .output = tool finished
#   message         → .role, .content, .delta = text chunk
#   result          → final stats
#   error           → something went wrong
parse_stream_event() {
  local line="$1"
  local etype
  etype="$(jq -r '.type // empty' <<< "$line" 2>/dev/null)" || return 0

  case "$etype" in
    init)          echo "⚡ Processing…" ;;
    tool_use)
      local name params_summary
      name="$(jq -r '.tool_name // empty' <<< "$line" 2>/dev/null)"
      params_summary="$(jq -r '.parameters // {} | to_entries | map(.key + "=" + (.value | tostring | .[:40])) | join(", ")' <<< "$line" 2>/dev/null)"
      if [[ -n "$params_summary" ]]; then
        echo "🔧 ${name:-tool}(${params_summary:0:100})"
      else
        echo "🔧 ${name:-tool}"
      fi ;;
    tool_result)
      local status output
      status="$(jq -r '.status // empty' <<< "$line" 2>/dev/null)"
      output="$(jq -r '.output // empty' <<< "$line" 2>/dev/null)"
      if [[ "$status" == "success" ]]; then
        echo "✅ ${output:0:120}"
      else
        echo "❌ ${output:0:120}"
      fi ;;
    message)
      local role content
      role="$(jq -r '.role // empty' <<< "$line" 2>/dev/null)"
      if [[ "$role" == "model" || "$role" == "assistant" ]]; then
        content="$(jq -r '.content // .delta // empty' <<< "$line" 2>/dev/null)"
        if [[ -n "$(trim "$content")" ]]; then
          echo "✍️ Drafting…"
        fi
      fi ;;
    error)
      local msg
      msg="$(jq -r '.message // .error // "error"' <<< "$line" 2>/dev/null)"
      echo "⚠️ ${msg:0:120}" ;;
  esac
}

extract_last_marker_block() {
  local text="$1"
  printf '%s\n' "$text" | awk '
    /^TELEGRAM_REPLY:[[:space:]]*/ { start = NR }
    { lines[NR] = $0 }
    END {
      if (!start) exit 1
      for (i = start; i <= NR; i++) print lines[i]
    }
  '
}

normalize_marker_tokens() {
  local text="$1"
  printf '%s' "$text" | perl -0777 -pe '
    s/TELEGRAM\s*_\s*REPLY\s*:/TELEGRAM_REPLY:/g;
    s/VOICE\s*_\s*REPLY\s*:/VOICE_REPLY:/g;
    s/MEMORY\s*_\s*APPEND\s*:/MEMORY_APPEND:/g;
    s/TASK\s*_\s*APPEND\s*:/TASK_APPEND:/g;
    s/SEND\s*_\s*PHOTO\s*:/SEND_PHOTO:/g;
    s/SEND\s*_\s*DOCUMENT\s*:/SEND_DOCUMENT:/g;
    s/SEND\s*_\s*VIDEO\s*:/SEND_VIDEO:/g;
  '
}

# ── CUSTOMISE: how to extract the final text from the stream ───────────────
# Called once with the full captured stream on stdin.
# Should print the plain-text final response.
extract_final_text() {
  local raw
  local raw_norm
  raw="$(cat)"
  raw_norm="$(normalize_marker_tokens "$raw")"

  # If your CLI already emits ShellClaw marker lines, pass them through.
  if printf '%s\n' "$raw_norm" | grep -qE '^TELEGRAM_REPLY:'; then
    extract_last_marker_block "$raw_norm" || printf '%s\n' "$raw_norm"
    return 0
  fi
  if printf '%s\n' "$raw_norm" | grep -qE '^(VOICE_REPLY|MEMORY_APPEND|TASK_APPEND|SEND_PHOTO|SEND_DOCUMENT|SEND_VIDEO):'; then
    printf '%s\n' "$raw_norm"
    return 0
  fi

  # For Gemini stream-json: assistant messages arrive as delta chunks.
  # Concatenate all assistant message content to reconstruct the full reply.
  local parsed
  local parsed_norm
  parsed="$(jq -j 'select(.type == "message" and (.role == "model" or .role == "assistant")) | (.content // .delta // empty)' <<< "$raw" 2>/dev/null || true)"

  # If parsing failed, use raw output as-is.
  if [[ -z "$parsed" ]]; then
    printf '%s\n' "$raw_norm"
    return 0
  fi

  parsed_norm="$(normalize_marker_tokens "$parsed")"

  # Ensure each marker keyword starts on its own line.
  local markers='TELEGRAM_REPLY|VOICE_REPLY|MEMORY_APPEND|TASK_APPEND|SEND_PHOTO|SEND_DOCUMENT|SEND_VIDEO'
  # Insert a newline before any marker that isn't already at line start.
  # shellcheck disable=SC2001
  parsed_norm="$(printf '%s' "$parsed_norm" | sed -E "s/([^\n])(($markers):)/\1\\n\2/g")"

  if printf '%s\n' "$parsed_norm" | grep -qE '^TELEGRAM_REPLY:'; then
    extract_last_marker_block "$parsed_norm" || printf '%s\n' "$parsed_norm"
    return 0
  fi

  printf '%s\n' "$parsed_norm"
}
# ── Progress monitor (generic — usually no changes needed) ─────────────────
stream_progress_monitor() {
  local msg_id="$1"
  local last_edit_ts=0
  local last_status_text=""
  local status_log=""

  while IFS= read -r line; do
    local status_text
    status_text="$(parse_stream_event "$line")"
    [[ -z "$status_text" ]] && continue
    [[ "$status_text" == "$last_status_text" ]] && continue
    last_status_text="$status_text"

    if [[ -n "$status_log" ]]; then
      status_log="${status_log}
${status_text}"
    else
      status_log="$status_text"
    fi
    # Keep status log bounded
    if (( ${#status_log} > 4500 )); then
      status_log="…${status_log: -4000}"
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
  done

  # Final status flush
  if [[ -n "$status_log" ]]; then
    local edit_text="$status_log"
    if (( ${#edit_text} > 4000 )); then
      edit_text="…${edit_text: -3900}"
    fi
    "$ROOT_DIR/scripts/telegram_api.sh" --edit "$msg_id" --text "$edit_text" 2>/dev/null || true
  fi
}

# ── Main ───────────────────────────────────────────────────────────────────
context_file="${AGENT_CONTEXT_FILE:-}"
progress_msg_id="${AGENT_PROGRESS_MSG_ID:-}"

if [[ -z "$context_file" || ! -f "$context_file" ]]; then
  echo "AGENT_CONTEXT_FILE not set or missing" >&2
  exit 1
fi

mkdir -p "$INSTANCE_DIR/tmp"
tmp_stream="$INSTANCE_DIR/tmp/agent_stream_$$.txt"
tmp_out="$INSTANCE_DIR/tmp/agent_out_$$.txt"
trap 'rm -f "$tmp_stream" "$tmp_out"' EXIT

rc=0
agent_pid=""

# Cleanup and kill background child process on signal/exit
cleanup() {
  local exit_code=$?
  if [[ -n "$agent_pid" ]] && kill -0 "$agent_pid" 2>/dev/null; then
    # Kill background agent process group or pid
    kill -TERM "$agent_pid" 2>/dev/null || true
    sleep 0.5
    kill -KILL "$agent_pid" 2>/dev/null || true
  fi
  rm -f "$tmp_stream" "$tmp_out" "${pipe:-}"
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

if [[ "$WRAPPER_STREAM" == "on" && -n "$progress_msg_id" ]]; then
  # ── Streaming mode: tee output to monitor + capture file ──
  pipe="$INSTANCE_DIR/tmp/agent_wrap_pipe_$$.fifo"
  mkfifo "$pipe"

  set +e
  bash -lc "$WRAPPER_CMD_TEMPLATE" < "$context_file" > "$pipe" 2>/dev/null &
  agent_pid=$!
  tee "$tmp_stream" < "$pipe" | stream_progress_monitor "$progress_msg_id"
  wait "$agent_pid" 2>/dev/null
  rc=$?
  set -e

  # Extract final text from captured stream
  final_text="$(extract_final_text < "$tmp_stream")"
else
  # ── Non-streaming mode: capture stdout, discard stderr ──
  set +e
  bash -lc "$WRAPPER_CMD_TEMPLATE" < "$context_file" > "$tmp_out" 2>/dev/null &
  agent_pid=$!
  wait "$agent_pid" 2>/dev/null
  rc=$?
  set -e
  final_text="$(extract_final_text < "$tmp_out")"
fi

if [[ $rc -ne 0 ]]; then
  if [[ -f "$INSTANCE_DIR/runtime/cancel" || -f "$ROOT_DIR/runtime/cancel" ]]; then
    exit 130
  fi
  echo "TELEGRAM_REPLY: Agent failed, exit code $rc. Check logs."
  exit $rc
fi

final_text="$(trim "$final_text")"

# ── Output marker lines ───────────────────────────────────────────────────
# If the agent already outputs ShellClaw marker lines, pass them through.
# Otherwise, wrap the response as TELEGRAM_REPLY.
if printf '%s\n' "$final_text" | grep -qE '^(TELEGRAM_REPLY|VOICE_REPLY|MEMORY_APPEND|TASK_APPEND|SEND_PHOTO|SEND_DOCUMENT|SEND_VIDEO):'; then
  printf '%s\n' "$final_text"
else
  printf 'TELEGRAM_REPLY: %s\n' "$final_text"
fi
