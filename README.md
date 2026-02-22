# MinusculeClaw

Single-file bash-powered personal voice agent that runs locally and talks over Telegram.

## What it does
- Telegram text and voice input.
- Local ASR via GlmAsrDocker (`ASR_URL`, default `http://localhost:18000`) or local `glm-asr` command.
- Agent loop via Codex CLI (`codex exec --yolo`).
- Local TTS via `kitten-tts`/`kitten-tts-rs` -> Opus OGG -> Telegram `sendVoice`.
- Persistent state in SQLite + human-readable markdown files.
- Daily logs and optional proactive heartbeat.
- Optional local dashboard on `http://localhost:8080`.

## Repo layout
- `agent.sh`: main loop.
- `asr.sh`: voice note transcription.
- `tts_to_voice.sh`: text-to-voice conversion.
- `send_telegram.sh`: Telegram send wrapper.
- `heartbeat.sh`: proactive daily turn.
- `dashboard.py`: last 50 turns dashboard.
- `webhook_server.py`: local webhook receiver (optional mode).
- `SOUL.md`, `USER.md`, `MEMORY.md`, `TASKS/pending.md`: editable memory/personality layer.

## Requirements
- Bash 5+
- `curl`, `jq`, `ffmpeg`, `sqlite3`
- `codex` CLI in `PATH`
- `kitten-tts` or `kitten-tts-rs` in `PATH`
- Either running ASR endpoint (`ASR_URL`) or `glm-asr` in `PATH`

## Quick start
```bash
git clone https://github.com/lsj5031/minusculeclaw.git
cd minusculeclaw
./setup.sh
./agent.sh
```

## Environment contract
Copy `.env.example` to `.env` and set:
- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_CHAT_ID`
- `TTS_CMD_TEMPLATE`

If your binaries are in user-local install location, keep this in `.env`:
```env
PATH="$HOME/.local/bin:$PATH"
```

`TTS_CMD_TEMPLATE` is executed with two exported vars:
- `TEXT`: reply text
- `WAV_OUTPUT`: output wav path

For `kitten-tts`, use the same runtime-libs pattern as `kitten-say`:
```env
ORT_LIB="$HOME/.local/opt/onnxruntime/onnxruntime-linux-x64-gpu-1.23.2/lib/libonnxruntime.so"
CUDA_LIB_DIR="$HOME/.local/opt/cuda12-runtime/lib"
CUDNN_LIB_DIR="/usr/lib"
TTS_CMD_TEMPLATE='kitten-tts synthesize --phonemizer espeak-ng ${ORT_LIB:+--ort-lib "$ORT_LIB"} ${CUDA_LIB_DIR:+--cuda-lib-dir "$CUDA_LIB_DIR"} ${CUDNN_LIB_DIR:+--cudnn-lib-dir "$CUDNN_LIB_DIR"} --text "$TEXT" --output "$WAV_OUTPUT"'
```

ASR supports two modes:
- HTTP mode: set `ASR_URL=...` (and optional `ASR_TEXT_JQ`).
- Command mode: set `ASR_CMD_TEMPLATE`, which runs with `AUDIO_INPUT` and `AUDIO_INPUT_PREP` exported.
- With `ASR_PREPROCESS=on` (default), incoming Telegram voice is normalized to mono WAV before ASR for better quality.

Example command mode:
```env
ASR_PREPROCESS=on
ASR_SAMPLE_RATE=16000
ASR_CMD_TEMPLATE='glm-asr transcribe "$AUDIO_INPUT_PREP"'
```

To reduce clipped/truncated voice replies, long text is split into chunks before synthesis.
Tune chunk size with:
```env
TTS_MAX_CHARS=260
```

## Codex output contract
MinusculeClaw expects strict markers in Codex output:
- `TELEGRAM_REPLY: ...` (required)
- `VOICE_REPLY: ...` (optional)
- `MEMORY_APPEND: ...` (optional)
- `TASK_APPEND: ...` (optional)

If markers are missing, MinusculeClaw sends a safe fallback text reply and logs `parse_fallback`.

## Ingress modes
- `WEBHOOK_MODE=off` (default): long polling (`getUpdates`).
- `WEBHOOK_MODE=on`: consume updates from `runtime/webhook_updates.jsonl`.
  - Run webhook receiver with `./webhook_server.py`.
  - Configure Telegram webhook separately or via `setup.sh` if `WEBHOOK_PUBLIC_URL` is set.

## systemd (user)
```bash
mkdir -p ~/.config/systemd/user
cp systemd/minusculeclaw* ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now minusculeclaw.service
systemctl --user enable --now minusculeclaw-heartbeat.timer
```

## cron alternative
```bash
crontab cron/minusculeclaw.crontab.example
```

## Dashboard
```bash
./dashboard.py
# open http://localhost:8080
```

## Runtime visibility
- `agent.sh` now prints startup and periodic idle status logs by default.
- Set `AGENT_LOG_LEVEL=debug` in `.env` for detailed polling/update traces.
- If `.env` still has placeholder `replace_me` values for Telegram, startup exits with a clear error.

## Safety note
Default mode uses `EXEC_POLICY=yolo` (`codex exec --yolo`), which allows unrestricted command execution by Codex. Use with caution on trusted machines.

## License
MIT
