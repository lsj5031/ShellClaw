#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/common.sh"
load_env

: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN required in .env}"
: "${WEBHOOK_PUBLIC_URL:?WEBHOOK_PUBLIC_URL required in .env (e.g. https://your-domain.com)}"
: "${WEBHOOK_SECRET:=}"

api_base="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"

case "${1:-}" in
  register)
    args=(-d "url=${WEBHOOK_PUBLIC_URL}" -d 'allowed_updates=["message","callback_query"]' -d "max_connections=5")
    if [[ -n "$WEBHOOK_SECRET" ]]; then
      args+=(-d "secret_token=$WEBHOOK_SECRET")
    fi
    echo "Registering webhook: $WEBHOOK_PUBLIC_URL"
    curl -fsS "$api_base/setWebhook" "${args[@]}" | jq .
    ;;
  unregister)
    echo "Removing webhook..."
    curl -fsS "$api_base/deleteWebhook" | jq .
    ;;
  status)
    curl -fsS "$api_base/getWebhookInfo" | jq .
    ;;
  *)
    echo "usage: $0 {register|unregister|status}" >&2
    exit 1
    ;;
esac
