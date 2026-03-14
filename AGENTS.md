# AGENTS.md — ShellClaw

## What this is
Bash-powered personal voice agent: Telegram ↔ ASR ↔ Agent CLI (Codex/pi/script) ↔ TTS. No test suite; verify manually with `./agent.sh --once` or `./agent.sh --inject-text "hello"`. Lint bash with `shellcheck agent.sh scripts/asr.sh scripts/telegram_api.sh scripts/heartbeat.sh scripts/nightly_reflection.sh scripts/tts.sh scripts/webhook_manage.sh scripts/setup.sh lib/common.sh`.

## Architecture
- **agent.sh** — main loop: polls Telegram (or reads webhook queue), calls agent provider (Codex/pi/script), parses marker output, sends reply.
- **lib/common.sh** — shared helpers (env loading, SQLite wrappers, logging). Sourced by all scripts via `source "$ROOT_DIR/lib/common.sh"; load_env`.
- **services/webhook_server.py / services/dashboard.py** — minimal stdlib-only Python (no deps). Webhook appends JSONL to `runtime/webhook_updates.jsonl`.
- **SQLite (`state.db`)** — schema in `sql/schema.sql`. Tables: `kv`, `turns`, `tasks`, `summaries`. Always use `sql_quote()` for values.
- **Personality/memory layer** — `SOUL.md` (system prompt), `USER.md` (user prefs), `MEMORY.md` (append-only facts), `TASKS/pending.md`.

## Agent Provider Support
ShellClaw supports three agent providers, configured via `AGENT_PROVIDER` in `.env`:
- **codex** — Uses Codex CLI (default). Respects `EXEC_POLICY` and `ALLOWLIST_PATH`.
- **pi** — Uses pi CLI. Safety is delegated to pi.
- **script** — Uses custom script via `AGENT_CMD_TEMPLATE`. Script receives context via stdin and must output marker lines.

## Output markers
Scripts parse agent output for marker lines: `TELEGRAM_REPLY:`, `VOICE_REPLY:`, `SEND_PHOTO:`, `SEND_DOCUMENT:`, `SEND_VIDEO:`, `MEMORY_APPEND:`, `TASK_APPEND:`. Extract with `extract_marker` / `extract_all_markers` in agent.sh.

## Code style
- Bash: `set -euo pipefail`, quote all variables, use `local` for function vars, log via `log_info`/`log_warn`/`log_debug`.
- Python: stdlib only, no third-party imports. Minimal scripts, no frameworks.
- Config: all tunables live in `.env` (see `.env.example`); scripts use `${VAR:-default}` pattern.
- Paths: resolve relative to `$ROOT_DIR`; convert with `[[ "$X" != /* ]] && X="$ROOT_DIR/$X"`.
- No markdown/code-fences in agent output — plain marker lines only.
