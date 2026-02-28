#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/common.sh"
load_env

require_cmd curl

: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN is required in .env}"
: "${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID is required in .env}"

mode=""
msg=""
file_path=""
caption=""
edit_msg_id=""
return_id=""
with_cancel_btn=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --text)
      mode="text"
      msg="$2"
      shift 2
      ;;
    --voice)
      mode="voice"
      file_path="$2"
      shift 2
      ;;
    --photo)
      mode="photo"
      file_path="$2"
      shift 2
      ;;
    --document)
      mode="document"
      file_path="$2"
      shift 2
      ;;
    --video)
      mode="video"
      file_path="$2"
      shift 2
      ;;
    --caption)
      caption="$2"
      shift 2
      ;;
    --edit)
      edit_msg_id="$2"
      shift 2
      ;;
    --return-id)
      return_id="true"
      shift
      ;;
    --typing)
      mode="typing"
      shift
      ;;
    --with-cancel-btn)
      with_cancel_btn="true"
      shift
      ;;
    --remove-keyboard)
      mode="remove_keyboard"
      edit_msg_id="$2"
      shift 2
      ;;
    --answer-callback)
      mode="answer_callback"
      msg="$2"
      shift 2
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

api_base="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"

cancel_keyboard='{"inline_keyboard":[[{"text":"Cancel","callback_data":"cancel"}]]}'
telegram_parse_mode="${TELEGRAM_PARSE_MODE:-HTML}"
parse_mode_args=()

case "$telegram_parse_mode" in
  off | OFF)
    telegram_parse_mode=""
    ;;
  Markdown | MarkdownV2 | HTML)
    parse_mode_args=(-d "parse_mode=$telegram_parse_mode")
    ;;
  *)
    if declare -F log_warn >/dev/null 2>&1; then
      log_warn "unsupported TELEGRAM_PARSE_MODE='$telegram_parse_mode'; expected Markdown, MarkdownV2, HTML, or off"
    else
      echo "WARN: unsupported TELEGRAM_PARSE_MODE='$telegram_parse_mode'; expected Markdown, MarkdownV2, HTML, or off" >&2
    fi
    telegram_parse_mode=""
    ;;
esac

escape_markdownv2_text() {
  local text="$1"
  text="${text//\\/\\\\}"
  text="${text//_/\\_}"
  text="${text//\*/\\*}"
  text="${text//[/\\[}"
  text="${text//]/\\]}"
  text="${text//(/\\(}"
  text="${text//)/\\)}"
  text="${text//~/\\~}"
  text="${text//\`/\\\`}"
  text="${text//>/\\>}"
  text="${text//#/\\#}"
  text="${text//+/\\+}"
  text="${text//-/\\-}"
  text="${text//=/\\=}"
  text="${text//|/\\|}"
  text="${text//\{/\\{}"
  text="${text//\}/\\}}"
  text="${text//./\\.}"
  text="${text//!/\\!}"
  printf '%s' "$text"
}

strip_markdown_like_text() {
  local text="$1"
  # Fallback path only: remove common markdown markers so users do not see raw
  # formatting tokens when parse-mode validation fails.
  text="${text//\\/}"
  text="${text//\`\`\`/}"
  text="${text//\`/}"
  text="${text//\*\*/}"
  text="${text//\*/}"
  text="${text//__/}"
  text="${text//~~/}"
  text="${text//||/}"
  printf '%s' "$text"
}

telegram_text_request() {
  local -a raw_request=("$@")
  local -a raw_cmd=(curl -fsS "${raw_request[@]}")

  if [[ ${#parse_mode_args[@]} -eq 0 ]]; then
    "${raw_cmd[@]}"
    return 0
  fi

  local -a parse_raw_cmd=(curl -fsS "${raw_request[@]}")
  if "${parse_raw_cmd[@]}" "${parse_mode_args[@]}"; then
    return 0
  fi

  if [[ "$telegram_parse_mode" == "MarkdownV2" ]]; then
    local -a escaped_request=()
    local idx=0
    while [[ $idx -lt ${#raw_request[@]} ]]; do
      if [[ "${raw_request[$idx]}" == "--data-urlencode" ]] \
        && [[ $((idx + 1)) -lt ${#raw_request[@]} ]] \
        && [[ "${raw_request[$((idx + 1))]}" == text=* ]]; then
        local raw_text="${raw_request[$((idx + 1))]#text=}"
        local escaped_text
        escaped_text="$(escape_markdownv2_text "$raw_text")"
        escaped_request+=("--data-urlencode" "text=$escaped_text")
        idx=$((idx + 2))
        continue
      fi
      escaped_request+=("${raw_request[$idx]}")
      idx=$((idx + 1))
    done

    local -a parse_escaped_cmd=(curl -fsS "${escaped_request[@]}")
    if "${parse_escaped_cmd[@]}" "${parse_mode_args[@]}"; then
      return 0
    fi
  fi

  if declare -F log_warn >/dev/null 2>&1; then
    log_warn "text request failed with TELEGRAM_PARSE_MODE=$telegram_parse_mode"
  else
    echo "WARN: text request failed with TELEGRAM_PARSE_MODE=$telegram_parse_mode" >&2
  fi

  if [[ "$telegram_parse_mode" == "MarkdownV2" ]]; then
    local -a plain_request=()
    local idx=0
    while [[ $idx -lt ${#raw_request[@]} ]]; do
      if [[ "${raw_request[$idx]}" == "--data-urlencode" ]] \
        && [[ $((idx + 1)) -lt ${#raw_request[@]} ]] \
        && [[ "${raw_request[$((idx + 1))]}" == text=* ]]; then
        local raw_text="${raw_request[$((idx + 1))]#text=}"
        local plain_text
        plain_text="$(strip_markdown_like_text "$raw_text")"
        plain_request+=("--data-urlencode" "text=$plain_text")
        idx=$((idx + 2))
        continue
      fi
      plain_request+=("${raw_request[$idx]}")
      idx=$((idx + 1))
    done

    if declare -F log_warn >/dev/null 2>&1; then
      log_warn "retrying MarkdownV2 message as cleaned plain text"
    else
      echo "WARN: retrying MarkdownV2 message as cleaned plain text" >&2
    fi
    curl -fsS "${plain_request[@]}"
    return 0
  fi

  "${raw_cmd[@]}"
}

send_file() {
  local method="$1"
  local field="$2"
  if [[ ! -f "$file_path" ]]; then
    echo "$field file not found: $file_path" >&2
    exit 1
  fi
  local -a cmd=(curl -fsS "$api_base/$method"
    -F "chat_id=$TELEGRAM_CHAT_ID"
    -F "$field=@$file_path")
  if [[ -n "$telegram_parse_mode" ]]; then
    cmd+=(-F "parse_mode=$telegram_parse_mode")
  fi
  if [[ -n "$caption" ]]; then
    cmd+=(-F "caption=$caption")
  fi
  "${cmd[@]}" >/dev/null
}

case "$mode" in
  text)
    text_args=()
    if [[ -n "$edit_msg_id" ]]; then
      text_args+=("$api_base/editMessageText" -d "chat_id=$TELEGRAM_CHAT_ID" -d "message_id=$edit_msg_id")
    else
      text_args+=("$api_base/sendMessage" -d "chat_id=$TELEGRAM_CHAT_ID")
    fi
    text_args+=(--data-urlencode "text=$msg" -d "disable_web_page_preview=true")
    if [[ -n "$with_cancel_btn" ]]; then
      text_args+=(--data-urlencode "reply_markup=$cancel_keyboard")
    fi
    if [[ -z "$edit_msg_id" && "$return_id" == "true" ]]; then
      telegram_text_request "${text_args[@]}" | jq -r '.result.message_id'
    else
      telegram_text_request "${text_args[@]}" >/dev/null
    fi
    ;;
  remove_keyboard)
    curl -fsS "$api_base/editMessageReplyMarkup" \
      -d "chat_id=$TELEGRAM_CHAT_ID" \
      -d "message_id=$edit_msg_id" \
      -d "reply_markup={}" >/dev/null
    ;;
  answer_callback)
    curl -fsS "$api_base/answerCallbackQuery" \
      -d "callback_query_id=$msg" \
      -d "text=Cancelled" >/dev/null
    ;;
  typing)
    curl -fsS "$api_base/sendChatAction" \
      -d "chat_id=$TELEGRAM_CHAT_ID" \
      -d "action=typing" >/dev/null
    ;;
  voice)    send_file "sendVoice" "voice" ;;
  photo)    send_file "sendPhoto" "photo" ;;
  document) send_file "sendDocument" "document" ;;
  video)    send_file "sendVideo" "video" ;;
  *)
    echo "usage: $0 --text <message> | --voice <file> | --photo <file> | --document <file> | --video <file> [--caption <text>]" >&2
    exit 1
    ;;
esac
