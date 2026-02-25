# ShellClaw 🦀

**Pure-bash local voice agent that lives in Telegram.**

Send a voice note → local ASR on your laptop → Codex CLI (with real file access + persistent Markdown memory) → local TTS voice reply.

**Everything is stored in simple, human-readable `.md` files** you can literally `cat` or open in any editor.

No servers. No heavy frameworks. No Docker-compose. Maximum privacy and hackability.

<img src="docs/images/ShellClaw.png" alt="ShellClaw project logo" width="560" />

## ✨ Why people love it

- Full voice round-trip with **local** ASR + TTS
- Persistent memory & tasks you can read/edit by hand (`cat MEMORY.md`)
- Uses OpenAI **Codex CLI** as the brain (it can actually read/write your files)
- Live progress updates in Telegram (edits message with what Codex is doing)
- `/cancel` command to interrupt long-running requests mid-execution
- Local web dashboard (`http://localhost:8080`)
- Optional daily heartbeat (the bot can message you proactively)
- Optional nightly reflection journal (auto-written to markdown)
- Three safety modes: `strict` | `allowlist` | `yolo`
- Works great in English and Chinese (and likely more)

## 🚀 Quick Start

```bash
git clone https://github.com/lsj5031/ShellClaw.git
cd ShellClaw

cp .env.example .env
# Edit .env → add your TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID

./scripts/setup.sh            # interactive: sets .env, inits DB
make install           # installs systemd units, enables linger
make start             # starts agent (poll mode by default)

# Optional: for webhook mode instead of polling, set WEBHOOK_MODE=on in .env, then:
# make webhook-register && make start
```

**Recommended backends** (super easy to run):
- ASR → [GlmAsrDocker](https://github.com/lsj5031/GlmAsrDocker)
- TTS → [kitten-tts-rs](https://github.com/lsj5031/kitten-tts-rs)

Then just send a voice note to your Telegram bot — done!

## What it does

- Telegram text and voice input.
- Local ASR via your own backend (HTTP endpoint or CLI).
- Agent loop via Codex CLI (`codex exec`).
- Local TTS backend → Opus OGG → Telegram `sendVoice`.
- Persistent state in SQLite + human-readable markdown files.
- Daily logs, proactive heartbeat, and nightly reflection journal.
- Optional local dashboard on `http://localhost:8080`.

## How it works (high-level)

1. Telegram voice/text → `agent.sh`
2. Local ASR (`scripts/asr.sh`) → transcript
3. Build rich context (`SOUL.md` + `USER.md` + `MEMORY.md` + `TASKS/pending.md` + recent history)
4. `codex exec --json` with special marker contract + live Telegram progress updates
5. Parse markers → reply via text or local TTS (`scripts/tts.sh`)
6. Auto-append to memory/tasks + log everything

## Repo layout

```text
agent.sh                 # Main loop - webhook or poll, context building, Codex orchestration
scripts/
  asr.sh                 # Voice note transcription (HTTP or CLI backend)
  tts.sh                 # Text-to-voice conversion with Opus encoding
  telegram_api.sh        # Telegram API wrapper (sendMessage/sendVoice/editMessageText)
  heartbeat.sh           # Proactive daily turn trigger
  nightly_reflection.sh  # Sleep-time reflection trigger + markdown journal append
  webhook_manage.sh      # Register/unregister/status for Telegram webhook
  setup.sh               # Interactive bootstrap/migration script
services/
  webhook_server.py      # Webhook receiver (secret token, flock, FIFO signal)
  dashboard.py           # Web UI showing last 50 turns
lib/common.sh            # Shared helpers (env, SQLite, logging)
Makefile                 # Service lifecycle: make install/start/stop/restart/status/logs
SOUL.md                  # System prompt / personality
USER.md                  # User preferences
MEMORY.md                # Append-only memory facts
TASKS/pending.md         # Task list
```

## Requirements

- Bash 5+
- `curl`, `jq`, `ffmpeg`, `sqlite3`
- `codex` CLI in `PATH`
- A working ASR backend
- A working TTS backend
- `cloudflared` (for webhook mode with Cloudflare Tunnel)

---

## Deep Technical Dive

### agent.sh Internals

```mermaid
flowchart TB
    subgraph mode_select["Mode Selection"]
        CHECK{WEBHOOK_MODE?}
        CHECK -->|"on"| webhook_loop
        CHECK -->|"off"| main_loop
    end

    subgraph webhook_loop["webhook_loop()"]
        direction TB
        FIFO_INIT[Create FIFO<br/>Open fd 3 read-write]
        DRAIN1[drain_webhook_queue]
        FIFO_WAIT["read -r -t 30 &lt;&amp;3<br/>(block on FIFO)"]
        DRAIN2[drain_webhook_queue]
        FIFO_INIT --> DRAIN1 --> FIFO_WAIT
        FIFO_WAIT -->|"signal or timeout"| DRAIN2
        DRAIN2 --> FIFO_WAIT
    end

    subgraph main_loop["main_loop()"]
        direction TB
        START([Loop Start])
        POLL[poll_once]
        SLEEP[sleep $POLL_INTERVAL]
        START --> POLL --> SLEEP --> START
    end

    subgraph poll_once["poll_once()"]
        GETID[get_kv last_update_id]
        REQ[telegram_get_updates]
        PARSE[jq parse results]
        GETID --> REQ --> PARSE
    end

    subgraph process_update["process_update_obj()"]
        direction TB
        EXTRACT[Extract update_id, chat_id]
        CHECK_CHAT{chat_id matches<br/>TELEGRAM_CHAT_ID?}
        MSG_TEXT[Extract message.text/caption]
        VOICE_ID[Extract voice.file_id]
        DOWNLOAD[download_voice_file]
        ASR_CALL[scripts/asr.sh transcribe]
        HANDLE[handle_user_message]
        
        EXTRACT --> CHECK_CHAT
        CHECK_CHAT -->|"no"| SKIP[Skip, save offset]
        CHECK_CHAT -->|"yes"| MSG_TEXT
        MSG_TEXT --> VOICE_ID
        VOICE_ID -->|has voice| DOWNLOAD --> ASR_CALL --> HANDLE
        VOICE_ID -->|no voice| HANDLE
    end

    subgraph handle_user["handle_user_message()"]
        direction TB
        BUILD[build_context_file]
        PROGRESS[Send ⏳ Thinking…<br/>get message_id]
        RUN[run_codex --json<br/>stream to monitor]
        EXTRACT2[extract_marker<br/>TELEGRAM_REPLY<br/>VOICE_REPLY]
        CHECK_REPLY{Has reply?}
        EDIT_TEXT[editMessageText<br/>final reply]
        SEND_VOICE[safe_send_voice]
        APPEND[append_memory_and_tasks]
        STORE[store_turn to SQLite]
        LOG[append_daily_log]
        
        BUILD --> PROGRESS --> RUN --> EXTRACT2 --> CHECK_REPLY
        CHECK_REPLY -->|voice input| SEND_VOICE
        CHECK_REPLY -->|text input| EDIT_TEXT
        SEND_VOICE --> APPEND
        EDIT_TEXT --> APPEND
        APPEND --> STORE --> LOG
    end

    POLL -.->|"for each update"| process_update
    DRAIN2 -.->|"for each queued line"| process_update
    PROCESS -.-> handle_user
```

### Context Building

```mermaid
flowchart LR
    subgraph Input
        IT[input_type]
        UT[user_text]
        AT[asr_text]
    end

    subgraph Context_File["Context File (tmp/context_*.md)"]
        direction TB
        HDR["# ShellClaw Runtime Context"]
        META[Timestamp, Input type,<br/>Exec policy, Allowlist]
        SOUL["## SOUL.md<br/>(cat SOUL.md)"]
        USER["## USER.md<br/>(cat USER.md)"]
        MEM["## MEMORY.md<br/>(cat MEMORY.md)"]
        TASKS["## TASKS/pending.md<br/>(cat TASKS/pending.md)"]
        RECENT["## Recent turns<br/>(recent_turns_snippet)"]
        CURRENT["## Current user input<br/>USER_TEXT: ..."]
        REQ["## Output requirements<br/>Marker format docs"]
    end

    subgraph recent_turns["recent_turns_snippet()"]
        SQL["SELECT last 8 turns<br/>FROM turns ORDER BY id DESC"]
    end

    IT --> HDR
    UT --> CURRENT
    SOUL --> Context_File
    USER --> Context_File
    MEM --> Context_File
    TASKS --> Context_File
    SQL --> RECENT
    RECENT --> Context_File
```

### Codex Execution Modes

```mermaid
flowchart TB
    subgraph run_codex["run_codex()"]
        INPUT[context_file]
        BUILD_CMD[Build codex command]
        
        subgraph POLICY["EXEC_POLICY modes"]
            YOLO["--dangerously-bypass-approvals-and-sandbox<br/>(yolo)"]
            ALLOWLIST["--full-auto<br/>(allowlist)"]
            STRICT["no extra flags<br/>(strict)"]
        end
        
        OPT_MODEL["--model $CODEX_MODEL<br/>(if set)"]
        STREAM{"progress_msg_id<br/>set?"}
        JSON_PATH["--json mode<br/>pipe to codex_stream_monitor"]
        PLAIN_PATH["plain mode<br/>capture stdout"]
        OUTPUT["--output-last-message out_file"]
        PARSE[Read out_file]
        RETURN[Return output]
    end
    
    INPUT --> BUILD_CMD
    BUILD_CMD --> POLICY
    POLICY --> OPT_MODEL --> STREAM
    STREAM -->|"yes"| JSON_PATH --> OUTPUT
    STREAM -->|"no"| PLAIN_PATH --> OUTPUT
    OUTPUT --> PARSE --> RETURN
```

### Marker Parsing

```mermaid
flowchart LR
    subgraph Codex_Output["Codex Raw Output"]
        L1["TELEGRAM_REPLY: Hello! ..."]
        L2["VOICE_REPLY: Hi there! ..."]
        L3["MEMORY_APPEND: User likes cats"]
        L4["TASK_APPEND: Buy groceries"]
        L5["TASK_APPEND: Call mom"]
    end

    subgraph extract_marker["extract_marker()"]
        AWK1["awk: match single line<br/>prefix, return first"]
    end

    subgraph extract_all["extract_all_markers()"]
        AWK2["awk: match all lines<br/>with prefix"]
    end

    L1 --> AWK1 --> TG["telegram_reply"]
    L2 --> AWK1 --> VR["voice_reply"]
    L3 --> AWK2 --> MEM_APPEND["memory_lines"]
    L4 --> AWK2 --> TASK_LINES
    L5 --> AWK2 --> TASK_LINES["task_lines"]
```

### Reply Dispatch Logic

```mermaid
flowchart TB
    START([handle_user_message])
    INPUT_TYPE{input_type?}
    
    subgraph Voice_Path["Voice Input Path"]
        HAS_VOICE{voice_reply<br/>exists?}
        USE_VR[Use voice_reply]
        USE_TR_V[Use telegram_reply<br/>as voice text]
        TTS_CALL[safe_send_voice]
        TTS_OK{TTS success?}
        EDIT_PROGRESS_V[editMessageText<br/>telegram_reply]
        FALLBACK_V[send_or_edit_text<br/>telegram_reply]
    end
    
    subgraph Text_Path["Text Input Path"]
        HAS_TG{telegram_reply<br/>exists?}
        EDIT_TG[send_or_edit_text<br/>telegram_reply]
        HAS_VR_T{voice_reply<br/>exists?}
        TTS_T[safe_send_voice]
        FAIL_T["send_or_edit_text<br/>'Voice output failed'"]
    end
    
    START --> INPUT_TYPE
    INPUT_TYPE -->|"voice"| HAS_VOICE
    INPUT_TYPE -->|"text"| HAS_TG
    
    HAS_VOICE -->|"yes"| USE_VR --> TTS_CALL
    HAS_VOICE -->|"no"| USE_TR_V --> TTS_CALL
    TTS_CALL --> TTS_OK
    TTS_OK -->|"yes"| EDIT_PROGRESS_V --> DONE([done])
    TTS_OK -->|"no"| FALLBACK_V --> DONE
    
    HAS_TG -->|"yes"| EDIT_TG --> DONE
    HAS_TG -->|"no"| HAS_VR_T
    HAS_VR_T -->|"yes"| TTS_T --> TTS_OK2{TTS success?}
    TTS_OK2 -->|"yes"| DONE
    TTS_OK2 -->|"no"| FAIL_T --> DONE
    HAS_VR_T -->|"no"| DONE
```

### Architecture Overview

```mermaid
flowchart TB
    subgraph User
        TG[Telegram App]
    end

    subgraph ShellClaw
        direction TB
        AGENT[agent.sh]

        subgraph Ingress
            direction TB
            subgraph webhook_path["Webhook Mode (default)"]
                CF[cloudflared tunnel]
                WH[services/webhook_server.py<br/>secret token + flock]
                FIFO([FIFO notify pipe])
            end
            POLL[Long Polling<br/>getUpdates<br/>fallback mode]
        end

        subgraph Processing
            ASR[scripts/asr.sh<br/>Voice → Text]
            CTX[Context Builder<br/>SOUL + USER + MEMORY]
            CODEX[Codex CLI<br/>AI Agent]
            TTS[scripts/tts.sh<br/>Text → Voice]
        end

        subgraph Storage
            SQLITE[(SQLite<br/>state.db)]
            MD[Markdown Files<br/>MEMORY.md<br/>TASKS/pending.md]
            LOGS[Daily Logs<br/>LOGS/YYYY-MM-DD.md]
        end
    end

    TG -->|"voice/text"| AGENT
    AGENT --> ASR
    ASR --> CTX
    CTX --> CODEX
    CODEX --> TTS
    TTS -->|"voice reply"| TG
    CODEX -->|"text reply"| TG
    AGENT --> SQLITE
    AGENT --> MD
    AGENT --> LOGS

    CF --> WH --> FIFO --> AGENT
    TG -->|"webhook POST"| CF
    TG -->|"getUpdates"| POLL
    POLL --> AGENT
```

### Request Flow (Sequence)

```mermaid
sequenceDiagram
    participant T as Telegram
    participant A as agent.sh
    participant ASR as scripts/asr.sh
    participant C as Codex CLI
    participant TTS as scripts/tts.sh
    participant DB as SQLite

    T->>A: Voice message / Text
    
    alt Voice Input
        A->>A: download_telegram_file
        A->>ASR: Transcribe audio
        ASR-->>A: Transcript text
    end

    A->>A: build_context_file
    A->>T: sendMessage "⏳ Thinking…" (get message_id)

    A->>C: codex exec --json < context
    
    loop JSONL stream events
        C-->>A: item.started / item.completed
        A->>T: editMessageText (live status)
    end
    
    C-->>A: Final agent message (markers)

    alt Voice Reply
        A->>TTS: Generate voice
        TTS->>TTS: ffmpeg → Opus OGG
        TTS-->>A: Voice file
        A->>T: sendVoice
        A->>T: editMessageText (text version)
    else Text Reply
        A->>T: editMessageText (final reply)
    end

    A->>DB: Store turn
    A->>A: Append to MEMORY.md/TASKS
```

### Components

```mermaid
mindmap
  root((ShellClaw))
    Core Scripts
      agent.sh
        Webhook loop or poll loop
        Context building
        Marker parsing
        Live progress streaming
      scripts/asr.sh
        Voice transcription
        ffmpeg preprocessing
        HTTP or CLI backend
      scripts/tts.sh
        Text chunking
        TTS synthesis
        Opus encoding
      scripts/telegram_api.sh
        sendMessage wrapper
        sendVoice wrapper
        editMessageText wrapper
      scripts/heartbeat.sh
        Proactive daily trigger
    Supporting
      lib/common.sh
        Env loading
        SQLite helpers
        Logging utilities
      services/webhook_server.py
        HTTP POST receiver
        Secret token verification
        FIFO notification
        JSONL queue writer
      scripts/webhook_manage.sh
        Register/unregister webhook
        Webhook status
      services/dashboard.py
        Web UI for turns
      Makefile
        Service lifecycle
        Logs and webhook management
    Storage
      state.db
        turns table
        tasks table
        kv store
      MEMORY.md
        Append-only facts
      TASKS/pending.md
        Task list
      SOUL.md
        System prompt
      USER.md
        User preferences
```

### Data Flow

```mermaid
flowchart LR
    subgraph Input
        TXT[Text Message]
        VOICE[Voice Note]
    end

    subgraph Context_Sources
        SOUL[SOUL.md<br/>Personality]
        USER[USER.md<br/>Preferences]
        MEM[MEMORY.md<br/>Facts]
        TASKS[TASKS/pending.md]
        RECENT[Recent 8 Turns<br/>from SQLite]
    end

    subgraph AI_Processing
        CTX[Context File]
        CODEX[Codex CLI]
        OUT[Marker Output]
    end

    subgraph Output_Actions
        TG_REPLY[Telegram Reply]
        VOICE_REPLY[Voice Reply]
        MEM_APPEND[Append Memory]
        TASK_APPEND[Add Task]
    end

    TXT --> CTX
    VOICE -->|ASR| CTX
    SOUL --> CTX
    USER --> CTX
    MEM --> CTX
    TASKS --> CTX
    RECENT --> CTX

    CTX --> CODEX
    CODEX --> OUT

    OUT -->|"TELEGRAM_REPLY:"| TG_REPLY
    OUT -->|"VOICE_REPLY:"| VOICE_REPLY
    OUT -->|"MEMORY_APPEND:"| MEM_APPEND
    OUT -->|"TASK_APPEND:"| TASK_APPEND
```

## Environment contract

Copy `.env.example` to `.env`, then set at minimum:
- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_CHAT_ID`
- `CODEX_BIN` (if `codex` is not in systemd/user PATH)

Then choose one ASR mode:
- `ASR_URL` for HTTP ASR service
- or `ASR_CMD_TEMPLATE` for CLI-based ASR

And set `TTS_CMD_TEMPLATE` for your TTS command.

ShellClaw passes:
- `AUDIO_INPUT` and `AUDIO_INPUT_PREP` to ASR command templates
- `TEXT` and `WAV_OUTPUT` to TTS command templates

For backend-specific install/runtime flags, use the backend repos above.

Optional nightly reflection settings:
- `NIGHTLY_REFLECTION_FILE` (default `./LOGS/nightly_reflection.md`)
- `NIGHTLY_REFLECTION_SKIP_AGENT=on` for dry-run/template-only writes

## Codex output contract

ShellClaw expects strict markers in Codex output:
- `TELEGRAM_REPLY: ...` (required)
- `VOICE_REPLY: ...` (optional)
- `SEND_PHOTO: <absolute path>` (optional)
- `SEND_DOCUMENT: <absolute path>` (optional)
- `SEND_VIDEO: <absolute path>` (optional)
- `MEMORY_APPEND: ...` (optional)
- `TASK_APPEND: ...` (optional)

If markers are missing, ShellClaw sends a safe fallback text reply and logs `parse_fallback`.

## Ingress modes

### Webhook mode (recommended, `WEBHOOK_MODE=on`)

Telegram pushes updates via webhook → cloudflared tunnel → `services/webhook_server.py` → JSONL queue.
The agent sleeps on a FIFO pipe and wakes instantly when new data arrives (zero-CPU idle).

- `WEBHOOK_PUBLIC_URL` — your tunnel domain (e.g. `https://claw.liu.nz`)
- `WEBHOOK_SECRET` — secret token verified via `X-Telegram-Bot-Api-Secret-Token` header
- Queue writes are `flock`-protected against reader/writer races
- Register/unregister with `./scripts/webhook_manage.sh register|unregister|status`

### Poll mode (fallback, `WEBHOOK_MODE=off`)

Agent calls `getUpdates` every `POLL_INTERVAL_SECONDS` (default 2s). No extra services needed.

## Makefile

```bash
make help              # show all targets
make install           # install systemd units + enable linger
make start / stop      # start/stop all services
make restart           # restart all services
make status            # show service status
make logs              # follow agent logs (also: logs-webhook, logs-tunnel, logs-reflection)
make webhook-register  # register Telegram webhook
make webhook-status    # check webhook info
make lint              # shellcheck all scripts
make test              # smoke test via --inject-text
```

## systemd services

| Unit | Description |
|------|-------------|
| `shellclaw.service` | Main agent loop (webhook or poll) |
| `shellclaw-webhook.service` | Webhook HTTP server on `:8787` |
| `shellclaw-tunnel.service` | Cloudflare Tunnel (`cloudflared`) |
| `shellclaw-heartbeat.timer` | Daily heartbeat at 09:00 |
| `shellclaw-nightly-reflection.timer` | Daily reflection at 22:30 (local time) |

Install all with `make install`, or manually:
```bash
cp systemd/shellclaw* ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable shellclaw.service shellclaw-webhook.service shellclaw-tunnel.service shellclaw-heartbeat.timer shellclaw-nightly-reflection.timer
sudo loginctl enable-linger $USER   # services survive logout & start on boot
```

## Dashboard

```bash
./services/dashboard.py
# open http://localhost:8080
```

## Runtime visibility

- `agent.sh` prints startup and periodic idle status logs by default.
- Set `AGENT_LOG_LEVEL=debug` in `.env` for detailed polling/update traces.
- If `.env` still has placeholder `replace_me` values for Telegram, startup exits with a clear error.

## Safety note

Default mode uses `EXEC_POLICY=yolo` (`codex exec --yolo`), which allows unrestricted command execution by Codex. Use with caution on trusted machines.

## License

MIT
