#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
    *)
      echo "unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

api_base="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"

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
  if [[ -n "$caption" ]]; then
    cmd+=(-F "caption=$caption")
  fi
  "${cmd[@]}" >/dev/null
}

case "$mode" in
  text)
    curl -fsS "$api_base/sendMessage" \
      -d "chat_id=$TELEGRAM_CHAT_ID" \
      --data-urlencode "text=$msg" \
      -d "disable_web_page_preview=true" >/dev/null
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
