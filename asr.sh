#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/common.sh"
load_env

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <audio_file>" >&2
  exit 1
fi

audio_file="$1"
if [[ ! -f "$audio_file" ]]; then
  echo "audio file not found: $audio_file" >&2
  exit 1
fi

: "${ASR_CMD_TEMPLATE:=}"
: "${ASR_URL:=}"
: "${ASR_PREPROCESS:=on}"
: "${ASR_SAMPLE_RATE:=16000}"

asr_input="$audio_file"
tmp_asr_wav=""
tmp_asr_stderr=""
if [[ "$ASR_PREPROCESS" == "on" ]]; then
  require_cmd ffmpeg
  mkdir -p "$ROOT_DIR/tmp"
  tmp_asr_wav="$ROOT_DIR/tmp/asr_in_$$.wav"
  ffmpeg -hide_banner -loglevel error -y -i "$audio_file" -ac 1 -ar "$ASR_SAMPLE_RATE" "$tmp_asr_wav"
  if [[ -s "$tmp_asr_wav" ]]; then
    asr_input="$tmp_asr_wav"
  fi
fi
tmp_asr_stderr="$ROOT_DIR/tmp/asr_cmd_$$.stderr"
trap '[[ -n "$tmp_asr_wav" ]] && rm -f "$tmp_asr_wav"; [[ -n "$tmp_asr_stderr" ]] && rm -f "$tmp_asr_stderr"' EXIT

if [[ -n "$(trim "$ASR_CMD_TEMPLATE")" ]]; then
  export AUDIO_INPUT="$audio_file"
  export AUDIO_INPUT_PREP="$asr_input"
  set +e
  cmd_output="$(bash -lc "$ASR_CMD_TEMPLATE" 2>"$tmp_asr_stderr")"
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    echo "ASR command failed (ASR_CMD_TEMPLATE): $ASR_CMD_TEMPLATE" >&2
    if [[ -s "$tmp_asr_stderr" ]]; then
      cat "$tmp_asr_stderr" >&2
    fi
    exit 1
  fi

  text="$cmd_output"
  if [[ "$ASR_CMD_TEMPLATE" == *"glm-asr transcribe"* ]]; then
    transcript_path="$(printf '%s\n' "$cmd_output" | sed -n 's/^Output:[[:space:]]*//p' | tail -n 1)"
    transcript_path="$(trim "$transcript_path")"
    if [[ -n "$transcript_path" && -f "$transcript_path" ]]; then
      text="$(cat "$transcript_path")"
    else
      # Fallback: keep only likely transcript lines and drop boilerplate/log lines.
      text="$(printf '%s\n' "$cmd_output" | sed '/^GLM-ASR Transcription$/d; /^Input:/d; /^Size:/d; /^Copying /d; /^Transcribing/d; /^Found [0-9]/d; /^\\[[0-9]\\/\\([0-9]\\+\\)\\]/d; /^Loading audio file:/d; /^Duration:/d; /^Processing as /d; /^Transcript saved to:/d; /^✓/d; /^Output:/d')"
    fi
  fi
else
  if [[ -z "$(trim "$ASR_URL")" ]]; then
    echo "ASR is not configured. Set ASR_CMD_TEMPLATE or ASR_URL in .env" >&2
    exit 1
  fi
  require_cmd curl
  require_cmd jq
  : "${ASR_FILE_FIELD:=file}"
  : "${ASR_TEXT_JQ:=.text // .result // .data.text // .data.result // empty}"
  resp="$(curl -fsS -X POST "$ASR_URL" -F "${ASR_FILE_FIELD}=@${asr_input}")"
  text="$(jq -r "$ASR_TEXT_JQ" <<<"$resp")"
fi

# Remove ANSI escape codes some CLIs emit before returning transcript text.
text="$(printf '%s' "$text" | sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g' | tr -d '\r')"
text="$(trim "$text")"
if [[ -z "$text" ]]; then
  if [[ -n "$(trim "$ASR_CMD_TEMPLATE")" ]]; then
    echo "ASR command returned empty transcript" >&2
  else
    echo "ASR returned empty text; raw response: $resp" >&2
  fi
  exit 1
fi

printf "%s\n" "$text"
