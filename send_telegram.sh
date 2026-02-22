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
voice_path=""
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
      voice_path="$2"
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

case "$mode" in
  text)
    curl -fsS "$api_base/sendMessage" \
      -d "chat_id=$TELEGRAM_CHAT_ID" \
      --data-urlencode "text=$msg" \
      -d "disable_web_page_preview=true" >/dev/null
    ;;
  voice)
    if [[ ! -f "$voice_path" ]]; then
      echo "voice file not found: $voice_path" >&2
      exit 1
    fi
    if [[ -n "$caption" ]]; then
      curl -fsS "$api_base/sendVoice" \
        -F "chat_id=$TELEGRAM_CHAT_ID" \
        -F "voice=@$voice_path" \
        -F "caption=$caption" >/dev/null
    else
      curl -fsS "$api_base/sendVoice" \
        -F "chat_id=$TELEGRAM_CHAT_ID" \
        -F "voice=@$voice_path" >/dev/null
    fi
    ;;
  *)
    echo "usage: $0 --text <message> | --voice <file> [--caption <text>]" >&2
    exit 1
    ;;
esac
