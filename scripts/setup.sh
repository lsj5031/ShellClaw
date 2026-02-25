#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT_DIR"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing dependency: $1" >&2
    exit 1
  }
}

set_env_value() {
  local key="$1"
  local value="$2"
  local file="$3"
  if grep -q "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    printf "%s=%s\n" "$key" "$value" >> "$file"
  fi
}

env_value() {
  local key="$1"
  local file="$2"
  grep "^${key}=" "$file" | head -n1 | cut -d= -f2- || true
}

echo "== ShellClaw setup =="

for c in bash curl jq ffmpeg sqlite3; do
  need_cmd "$c"
done

if ! command -v codex >/dev/null 2>&1; then
  echo "warning: codex CLI not found in PATH"
fi

if [[ -d "$HOME/.local/bin" && ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
  echo "warning: ~/.local/bin is not on PATH in this shell"
  echo "hint: set PATH=\"\\$HOME/.local/bin:\\$PATH\" in .env"
fi

tts_bin=""
if command -v kitten-tts >/dev/null 2>&1; then
  tts_bin="kitten-tts"
elif command -v kitten-tts-rs >/dev/null 2>&1; then
  tts_bin="kitten-tts-rs"
else
  echo "warning: neither kitten-tts nor kitten-tts-rs found in PATH"
fi

mkdir -p TASKS LOGS config sql systemd cron runtime tmp scripts services

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "Created .env from .env.example"
fi

if [[ ! -f USER.md && -f USER.md.example ]]; then
  cp USER.md.example USER.md
  echo "Created USER.md from template"
fi

[[ -f MEMORY.md ]] || printf "# Long-Term Memory\n\n" > MEMORY.md
[[ -f TASKS/pending.md ]] || printf "# Pending Tasks\n\n- (empty)\n" > TASKS/pending.md

read -r -p "Telegram bot token (leave blank to keep current): " token || true
if [[ -n "${token:-}" ]]; then
  set_env_value "TELEGRAM_BOT_TOKEN" "$token" .env
fi

read -r -p "Telegram chat id (leave blank to keep current): " chat_id || true
if [[ -n "${chat_id:-}" ]]; then
  set_env_value "TELEGRAM_CHAT_ID" "$chat_id" .env
fi

if [[ ! -f state.db ]]; then
  sqlite3 state.db < sql/schema.sql >/dev/null
  echo "Initialized state.db"
else
  has_turns="$(sqlite3 state.db "SELECT 1 FROM sqlite_master WHERE type='table' AND name='turns' LIMIT 1;")"
  if [[ "$has_turns" == "1" ]]; then
    has_update_id="$(sqlite3 state.db "SELECT 1 FROM pragma_table_info('turns') WHERE name='update_id' LIMIT 1;")"
    if [[ "$has_update_id" != "1" ]]; then
      sqlite3 state.db "ALTER TABLE turns ADD COLUMN update_id TEXT;"
    fi
  fi

  sqlite3 state.db < sql/schema.sql >/dev/null
  echo "Applied schema migrations"
fi

if curl -fsS "http://localhost:18000" >/dev/null 2>&1; then
  echo "ASR endpoint reachable at http://localhost:18000"
else
  echo "warning: ASR endpoint not reachable at http://localhost:18000"
  if command -v glm-asr >/dev/null 2>&1; then
    echo "info: detected glm-asr binary; command-mode ASR is available via ASR_CMD_TEMPLATE"
  fi
fi

if [[ -f .env ]]; then
  set +u
  set -a
  # shellcheck disable=SC1091
  source ./.env
  set +a
  set -u
fi

if [[ -n "$tts_bin" && "$tts_bin" == "kitten-tts" ]]; then
  current_tts_cmd="$(env_value "TTS_CMD_TEMPLATE" .env)"
  if [[ -z "${current_tts_cmd//[[:space:]]/}" || "$current_tts_cmd" == "''" || "$current_tts_cmd" == *"kitten-tts-rs --text"* || "$current_tts_cmd" == *"kitten-tts --text"* || "$current_tts_cmd" == *"kitten-tts synthesize --text"* ]]; then
    set_env_value "TTS_CMD_TEMPLATE" "'kitten-tts synthesize --phonemizer espeak-ng \${ORT_LIB:+--ort-lib \"\$ORT_LIB\"} \${CUDA_LIB_DIR:+--cuda-lib-dir \"\$CUDA_LIB_DIR\"} \${CUDNN_LIB_DIR:+--cudnn-lib-dir \"\$CUDNN_LIB_DIR\"} --text \"\$TEXT\" --output \"\$WAV_OUTPUT\"'" .env
    echo "Updated TTS_CMD_TEMPLATE to kitten-tts synthesize (kitten-say style libs)"
  fi
fi

if command -v glm-asr >/dev/null 2>&1; then
  current_asr_cmd="$(env_value "ASR_CMD_TEMPLATE" .env)"
  # shellcheck disable=SC2016
  if [[ -z "${current_asr_cmd// }" || "$current_asr_cmd" == "''" || "$current_asr_cmd" == *'glm-asr "$AUDIO_INPUT"'* ]]; then
    set_env_value "ASR_CMD_TEMPLATE" "'glm-asr transcribe \"\$AUDIO_INPUT_PREP\"'" .env
    echo "Set ASR_CMD_TEMPLATE to glm-asr transcribe"
  fi

  current_asr_preprocess="$(env_value "ASR_PREPROCESS" .env)"
  current_asr_sr="$(env_value "ASR_SAMPLE_RATE" .env)"
  if [[ -z "${current_asr_preprocess//[[:space:]]/}" ]]; then
    set_env_value "ASR_PREPROCESS" "on" .env
  fi
  if [[ -z "${current_asr_sr//[[:space:]]/}" ]]; then
    set_env_value "ASR_SAMPLE_RATE" "16000" .env
  fi
fi

if command -v kitten-say >/dev/null 2>&1; then
  current_ort="$(env_value "ORT_LIB" .env)"
  current_cuda="$(env_value "CUDA_LIB_DIR" .env)"
  current_cudnn="$(env_value "CUDNN_LIB_DIR" .env)"
  current_tts_max_chars="$(env_value "TTS_MAX_CHARS" .env)"
  if [[ -z "${current_ort//[[:space:]]/}" ]]; then
    set_env_value "ORT_LIB" "\"\$HOME/.local/opt/onnxruntime/onnxruntime-linux-x64-gpu-1.23.2/lib/libonnxruntime.so\"" .env
  fi
  if [[ -z "${current_cuda//[[:space:]]/}" ]]; then
    set_env_value "CUDA_LIB_DIR" "\"\$HOME/.local/opt/cuda12-runtime/lib\"" .env
  fi
  if [[ -z "${current_cudnn//[[:space:]]/}" ]]; then
    set_env_value "CUDNN_LIB_DIR" "\"/usr/lib\"" .env
  fi
  if [[ -z "${current_tts_max_chars//[[:space:]]/}" ]]; then
    set_env_value "TTS_MAX_CHARS" "260" .env
  fi
fi

if [[ "${WEBHOOK_MODE:-off}" == "on" && -n "${WEBHOOK_PUBLIC_URL:-}" ]]; then
  ./scripts/webhook_manage.sh register || true
fi

chmod +x \
  agent.sh \
  scripts/asr.sh \
  scripts/tts.sh \
  scripts/telegram_api.sh \
  scripts/heartbeat.sh \
  scripts/nightly_reflection.sh \
  scripts/setup.sh \
  scripts/webhook_manage.sh \
  services/dashboard.py \
  services/webhook_server.py

cat <<'MSG'

ShellClaw setup is complete.

Quick smoke test:
  make test

Install & start all services:
  make install
  make webhook-register
  make start

Useful commands:
  make status            # check all services
  make logs              # follow agent logs
  make restart           # restart everything

Dashboard:
  ./services/dashboard.py         # open http://localhost:8080

ShellClaw is now purring on Telegram.
MSG
