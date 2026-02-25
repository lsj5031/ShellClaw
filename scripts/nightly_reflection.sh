#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/common.sh"
load_env

require_cmd sqlite3
ensure_dirs

: "${NIGHTLY_REFLECTION_FILE:=./LOGS/nightly_reflection.md}"
: "${NIGHTLY_REFLECTION_SKIP_AGENT:=off}"
: "${NIGHTLY_REFLECTION_PROMPT:=请做一次睡前复盘：结合今天的对话与任务，用第一人称写简短总结，包含“今天成果”“今天体会”“明天最重要一件事”，总长度控制在120字以内。}"

if [[ "$NIGHTLY_REFLECTION_FILE" != /* ]]; then
  NIGHTLY_REFLECTION_FILE="$ROOT_DIR/$NIGHTLY_REFLECTION_FILE"
fi

today_local="$(TZ="$TIMEZONE" date +"%Y-%m-%d")"
marker="<!-- nightly-reflection:${today_local} -->"
now_iso="$(iso_now)"

mkdir -p "$(dirname "$NIGHTLY_REFLECTION_FILE")"
touch "$NIGHTLY_REFLECTION_FILE"

if grep -Fq "$marker" "$NIGHTLY_REFLECTION_FILE"; then
  echo "$now_iso [INFO] nightly reflection already exists for $today_local"
  exit 0
fi

before_id="$(sqlite3 "$SQLITE_DB_PATH" "SELECT COALESCE(MAX(id), 0) FROM turns;")"

if [[ "$NIGHTLY_REFLECTION_SKIP_AGENT" != "on" ]]; then
  "$ROOT_DIR/agent.sh" --inject-text "$NIGHTLY_REFLECTION_PROMPT"
fi

prompt_sql="$(sql_quote "$NIGHTLY_REFLECTION_PROMPT")"
row="$(
  sqlite3 -separator $'\t' "$SQLITE_DB_PATH" \
    "SELECT ts, COALESCE(NULLIF(telegram_reply, ''), NULLIF(voice_reply, ''), ''), status
     FROM turns
     WHERE id > $before_id
       AND user_text = $prompt_sql
     ORDER BY id DESC
     LIMIT 1;"
)"

turn_ts=""
reflection_text=""
turn_status=""
if [[ -n "$row" ]]; then
  IFS=$'\t' read -r turn_ts reflection_text turn_status <<< "$row"
fi

if [[ -z "$(trim "$reflection_text")" ]]; then
  reflection_text=$'- 今天成果：\n- 今天体会：\n- 明天最重要一件事：'
  turn_status="template_only"
fi

{
  printf "%s\n" "$marker"
  printf "## %s 睡前复盘\n" "$today_local"
  printf -- "- generated_at: %s\n" "$now_iso"
  printf -- "- source: shellclaw-nightly-reflection.timer\n"
  printf -- "- turn_ts: %s\n" "${turn_ts:-<none>}"
  printf -- "- status: %s\n\n" "${turn_status:-<unknown>}"
  printf "%s\n\n" "$reflection_text"
} >> "$NIGHTLY_REFLECTION_FILE"

echo "$now_iso [INFO] nightly reflection appended to $NIGHTLY_REFLECTION_FILE"
