#!/usr/bin/env bash
set -euo pipefail

# Force UTF-8 locale for consistent string handling
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# INSTANCE_DIR holds per-bot data (.env, state.db, SOUL.md, MEMORY.md, etc.).
# Defaults to ROOT_DIR (single-bot backward compat). Override via environment
# or agent.sh --instance-dir <path>.
: "${INSTANCE_DIR:=$ROOT_DIR}"
if [[ "$INSTANCE_DIR" != /* ]]; then
  INSTANCE_DIR="$(cd "$INSTANCE_DIR" && pwd)"
fi

load_env() {
  local env_file="${1:-$INSTANCE_DIR/.env}"
  if [[ -f "$env_file" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
  fi

  : "${SQLITE_DB_PATH:=./state.db}"
  : "${LOG_DIR:=./LOGS}"
  : "${TIMEZONE:=UTC}"

  if [[ "$SQLITE_DB_PATH" != /* ]]; then
    SQLITE_DB_PATH="$INSTANCE_DIR/$SQLITE_DB_PATH"
  fi
  if [[ "$LOG_DIR" != /* ]]; then
    LOG_DIR="$INSTANCE_DIR/$LOG_DIR"
  fi

  export ROOT_DIR INSTANCE_DIR SQLITE_DB_PATH LOG_DIR TIMEZONE
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing dependency: $1" >&2
    exit 1
  }
}

iso_now() {
  TZ="$TIMEZONE" date +"%Y-%m-%dT%H:%M:%S%z"
}

today_file() {
  local day
  day="$(TZ="$TIMEZONE" date +"%Y-%m-%d")"
  printf "%s/%s.md" "$LOG_DIR" "$day"
}

ensure_dirs() {
  mkdir -p "$LOG_DIR" "$INSTANCE_DIR/TASKS" "$INSTANCE_DIR/runtime" "$INSTANCE_DIR/tmp"
}

sql_quote() {
  local s="${1//\'/\'\'}"
  printf "'%s'" "$s"
}

sqlite_exec() {
  local sql="$1"
  sqlite3 "$SQLITE_DB_PATH" "$sql"
}

get_kv() {
  local key="$1"
  sqlite3 "$SQLITE_DB_PATH" "SELECT value FROM kv WHERE key=$(sql_quote "$key") LIMIT 1;"
}

set_kv() {
  local key="$1"
  local val="$2"
  sqlite3 "$SQLITE_DB_PATH" "INSERT INTO kv(key,value) VALUES($(sql_quote "$key"),$(sql_quote "$val")) ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
}

append_daily_log() {
  local text="$1"
  local path
  path="$(today_file)"
  mkdir -p "$(dirname "$path")"
  printf "%s\n" "$text" >> "$path"
}

trim() {
  local x="$1"
  x="${x#"${x%%[![:space:]]*}"}"
  x="${x%"${x##*[![:space:]]}"}"
  printf '%s' "$x"
}
