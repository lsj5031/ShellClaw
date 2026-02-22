#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

load_env() {
  local env_file="${1:-$ROOT_DIR/.env}"
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
    SQLITE_DB_PATH="$ROOT_DIR/$SQLITE_DB_PATH"
  fi
  if [[ "$LOG_DIR" != /* ]]; then
    LOG_DIR="$ROOT_DIR/$LOG_DIR"
  fi

  export ROOT_DIR SQLITE_DB_PATH LOG_DIR TIMEZONE
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
  mkdir -p "$LOG_DIR" "$ROOT_DIR/TASKS" "$ROOT_DIR/runtime" "$ROOT_DIR/tmp"
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
