#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/common.sh"
load_env

require_cmd ffmpeg

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <text> <output_ogg>" >&2
  exit 1
fi

text="$1"
output_ogg="$2"

: "${TTS_CMD_TEMPLATE:?TTS_CMD_TEMPLATE is required in .env}"
: "${VOICE_BITRATE:=32k}"
: "${TTS_MAX_CHARS:=260}"

mkdir -p "$(dirname "$output_ogg")" "$ROOT_DIR/tmp"
tmp_wav="$ROOT_DIR/tmp/tts_$$.wav"
merged_wav="$ROOT_DIR/tmp/tts_merged_$$.wav"
chunks_file="$ROOT_DIR/tmp/tts_chunks_$$.txt"
concat_list="$ROOT_DIR/tmp/tts_concat_$$.txt"
declare -a segment_wavs=()
cleanup_tts_tmp() {
  rm -f "$tmp_wav" "$merged_wav" "$chunks_file" "$concat_list"
  if [[ ${#segment_wavs[@]} -gt 0 ]]; then
    rm -f "${segment_wavs[@]}" 2>/dev/null || true
  fi
}
trap cleanup_tts_tmp EXIT

run_tts_once() {
  local chunk_text="$1"
  local out_wav="$2"
  export TEXT="$chunk_text"
  export WAV_OUTPUT="$out_wav"

  set +e
  bash -lc "$TTS_CMD_TEMPLATE"
  tts_rc=$?
  set -e
  if [[ $tts_rc -ne 0 ]]; then
    echo "TTS command failed (TTS_CMD_TEMPLATE): $TTS_CMD_TEMPLATE" >&2
    if command -v kitten-tts >/dev/null 2>&1; then
      echo 'hint: if kitten-say works on this machine, use kitten-say-style libs in TTS_CMD_TEMPLATE (synthesize + --ort-lib/--cuda-lib-dir/--cudnn-lib-dir)' >&2
    fi
    exit $tts_rc
  fi
}

printf "%s\n" "$text" | fold -s -w "$TTS_MAX_CHARS" > "$chunks_file"
mapfile -t chunks < "$chunks_file"

if [[ "${#chunks[@]}" -le 1 ]]; then
  run_tts_once "$text" "$tmp_wav"
  final_wav="$tmp_wav"
else
  i=0
  : > "$concat_list"
  for chunk in "${chunks[@]}"; do
    chunk="$(trim "$chunk")"
    [[ -z "$chunk" ]] && continue
    wav_i="$ROOT_DIR/tmp/tts_${$}_$i.wav"
    run_tts_once "$chunk" "$wav_i"
    if [[ ! -s "$wav_i" ]]; then
      echo "TTS command did not produce wav output: $wav_i" >&2
      exit 1
    fi
    segment_wavs+=("$wav_i")
    printf "file '%s'\n" "$wav_i" >> "$concat_list"
    i=$((i + 1))
  done

  if [[ "${#segment_wavs[@]}" -eq 0 ]]; then
    echo "no non-empty TTS chunks were generated" >&2
    exit 1
  fi

  ffmpeg -hide_banner -loglevel error -y -f concat -safe 0 -i "$concat_list" -c copy "$merged_wav"
  if [[ ! -s "$merged_wav" ]]; then
    echo "failed to merge TTS wav chunks" >&2
    exit 1
  fi
  final_wav="$merged_wav"
fi

if [[ ! -s "$final_wav" ]]; then
  echo "TTS command did not produce wav output: $final_wav" >&2
  exit 1
fi

ffmpeg -hide_banner -loglevel error -y -i "$final_wav" -ac 1 -ar 48000 -c:a libopus -b:a "$VOICE_BITRATE" -vbr on "$output_ogg"

if [[ ! -s "$output_ogg" ]]; then
  echo "failed to produce ogg output: $output_ogg" >&2
  exit 1
fi

printf "%s\n" "$output_ogg"
