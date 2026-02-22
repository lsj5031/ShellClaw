# MinusculeClaw

Bash-powered personal voice agent that runs locally and talks over Telegram.

<img src="docs/images/minusculeclaw-avatar.jpg" alt="MinusculeClaw project avatar" width="280" />

## agent.sh Internals

```mermaid
flowchart TB
    subgraph main_loop["main_loop()"]
        direction TB
        START([Loop Start])
        CHECK{WEBHOOK_MODE?}
        WHQ[consume_webhook_queue_line]
        POLL[poll_once]
        SLEEP[sleep $POLL_INTERVAL]
        START --> CHECK
        CHECK -->|"on"| WHQ
        CHECK -->|"off"| POLL
        WHQ -->|has data| PROCESS
        WHQ -->|empty| POLL
        POLL --> PROCESS
        PROCESS --> SLEEP
        SLEEP --> START
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
        ASR_CALL[asr.sh transcribe]
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
        RUN[run_codex]
        EXTRACT2[extract_marker<br/>TELEGRAM_REPLY<br/>VOICE_REPLY]
        CHECK_REPLY{Has reply?}
        SEND_TEXT[safe_send_text]
        SEND_VOICE[safe_send_voice]
        APPEND[append_memory_and_tasks]
        STORE[store_turn to SQLite]
        LOG[append_daily_log]
        
        BUILD --> RUN --> EXTRACT2 --> CHECK_REPLY
        CHECK_REPLY -->|voice input| SEND_VOICE
        CHECK_REPLY -->|text input| SEND_TEXT
        SEND_VOICE --> APPEND
        SEND_TEXT --> APPEND
        APPEND --> STORE --> LOG
    end

    POLL -.->|"for each update"| process_update
    PROCESS -.-> handle_user
```

## Context Building

```mermaid
flowchart LR
    subgraph Input
        IT[input_type]
        UT[user_text]
        AT[asr_text]
    end

    subgraph Context_File["Context File (tmp/context_*.md)"]
        direction TB
        HDR["# MinusculeClaw Runtime Context"]
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

## Codex Execution Modes

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
        EXEC["Execute codex<br/>stdin < context_file"]
        OUTPUT["--output-last-message out_file"]
        PARSE[Read out_file]
        RETURN[Return output]
    end
    
    INPUT --> BUILD_CMD
    BUILD_CMD --> POLICY
    POLICY --> OPT_MODEL --> EXEC --> OUTPUT --> PARSE --> RETURN
```

## Marker Parsing

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

## Reply Dispatch Logic

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
        FALLBACK_V[safe_send_text<br/>telegram_reply]
    end
    
    subgraph Text_Path["Text Input Path"]
        HAS_TG{telegram_reply<br/>exists?}
        SEND_TG[safe_send_text<br/>telegram_reply]
        HAS_VR_T{voice_reply<br/>exists?}
        TTS_T[safe_send_voice]
        FAIL_T["safe_send_text<br/>'Voice output failed'"]
    end
    
    START --> INPUT_TYPE
    INPUT_TYPE -->|"voice"| HAS_VOICE
    INPUT_TYPE -->|"text"| HAS_TG
    
    HAS_VOICE -->|"yes"| USE_VR --> TTS_CALL
    HAS_VOICE -->|"no"| USE_TR_V --> TTS_CALL
    TTS_CALL --> TTS_OK
    TTS_OK -->|"yes"| DONE([done])
    TTS_OK -->|"no"| FALLBACK_V --> DONE
    
    HAS_TG -->|"yes"| SEND_TG --> DONE
    HAS_TG -->|"no"| HAS_VR_T
    HAS_VR_T -->|"yes"| TTS_T --> TTS_OK2{TTS success?}
    TTS_OK2 -->|"yes"| DONE
    TTS_OK2 -->|"no"| FAIL_T --> DONE
    HAS_VR_T -->|"no"| DONE
```

## Architecture Overview

```mermaid
flowchart TB
    subgraph User
        TG[Telegram App]
    end

    subgraph MinusculeClaw
        direction TB
        AGENT[agent.sh<br/>Main Loop]

        subgraph Ingress
            POLL[Long Polling<br/>getUpdates]
            WH[Webhook Server<br/>webhook_server.py]
        end

        subgraph Processing
            ASR[asr.sh<br/>Voice → Text]
            CTX[Context Builder<br/>SOUL + USER + MEMORY]
            CODEX[Codex CLI<br/>AI Agent]
            TTS[tts_to_voice.sh<br/>Text → Voice]
        end

        subgraph Storage
            SQLITE[(SQLite<br/>state.db)]
            MD[Markdown Files<br/>MEMORY.md<br/>TASKS/pending.md]
            LOGS[Daily Logs<br/>LOGS/YYYY-MM-DD.md]
        end
    end

    TG -->|"Text Message"| POLL
    TG -->|"Voice Note"| POLL
    TG -->|"Webhook (optional)"| WH

    POLL --> AGENT
    WH -->|"JSONL queue"| AGENT

    AGENT -->|"Voice file"| ASR
    ASR -->|"Transcript"| AGENT

    AGENT --> CTX
    CTX -->|"Runtime Context"| CODEX
    CODEX -->|"Marker Output"| AGENT

    AGENT -->|"Reply Text"| TTS
    TTS -->|"OGG Voice"| AGENT

    AGENT -->|"sendMessage/sendVoice"| TG

    AGENT --> SQLITE
    AGENT --> MD
    AGENT --> LOGS
```

## Request Flow

```mermaid
sequenceDiagram
    participant T as Telegram
    participant A as agent.sh
    participant ASR as asr.sh
    participant C as Codex CLI
    participant TTS as tts_to_voice.sh
    participant DB as SQLite

    alt Voice Message
        T->>A: Voice Note (OGA)
        A->>ASR: Audio file
        ASR->>ASR: ffmpeg preprocess
        ASR->>ASR: ASR backend
        ASR-->>A: Transcript text
    else Text Message
        T->>A: Text message
    end

    A->>A: Build context<br/>(SOUL + USER + MEMORY + TASKS)
    A->>C: Context file
    C->>C: Process with AI
    C-->>A: Marker output

    A->>A: Extract markers<br/>TELEGRAM_REPLY, VOICE_REPLY,<br/>MEMORY_APPEND, TASK_APPEND

    alt Voice Reply (for voice input)
        A->>TTS: Text to speak
        TTS->>TTS: TTS backend → WAV
        TTS->>TTS: ffmpeg → Opus OGG
        TTS-->>A: Voice file
        A->>T: sendVoice
    else Text Reply
        A->>T: sendMessage
    end

    A->>DB: Store turn
    A->>A: Append to MEMORY.md/TASKS
```

## Components

```mermaid
mindmap
  root((MinusculeClaw))
    Core Scripts
      agent.sh
        Main polling/processing loop
        Context building
        Marker parsing
      asr.sh
        Voice transcription
        ffmpeg preprocessing
        HTTP or CLI backend
      tts_to_voice.sh
        Text chunking
        TTS synthesis
        Opus encoding
      send_telegram.sh
        sendMessage wrapper
        sendVoice wrapper
      heartbeat.sh
        Proactive daily trigger
    Supporting
      lib/common.sh
        Env loading
        SQLite helpers
        Logging utilities
      webhook_server.py
        HTTP POST receiver
        JSONL queue writer
      dashboard.py
        Web UI for turns
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

## Data Flow

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

## What it does
- Telegram text and voice input.
- Local ASR via your own backend (HTTP endpoint or CLI).
- Agent loop via Codex CLI (`codex exec --yolo`).
- Local TTS backend -> Opus OGG -> Telegram `sendVoice`.
- Persistent state in SQLite + human-readable markdown files.
- Daily logs and optional proactive heartbeat.
- Optional local dashboard on `http://localhost:8080`.

## Repo layout
```
agent.sh          # Main loop - polling, context building, Codex orchestration
asr.sh            # Voice note transcription (HTTP or CLI backend)
tts_to_voice.sh   # Text-to-voice conversion with Opus encoding
send_telegram.sh  # Telegram API wrapper (sendMessage/sendVoice)
heartbeat.sh      # Proactive daily turn trigger
dashboard.py      # Web UI showing last 50 turns
webhook_server.py # Optional webhook receiver (writes to JSONL queue)
lib/common.sh     # Shared helpers (env, SQLite, logging)
SOUL.md           # System prompt / personality
USER.md           # User preferences
MEMORY.md         # Append-only memory facts
TASKS/pending.md  # Task list
```

## Requirements
- Bash 5+
- `curl`, `jq`, `ffmpeg`, `sqlite3`
- `codex` CLI in `PATH`
- A working ASR backend
- A working TTS backend

Recommended backends:
- ASR: https://github.com/lsj5031/GlmAsrDocker
- TTS: https://github.com/lsj5031/kitten-tts-rs

## Quick start
```bash
git clone https://github.com/lsj5031/MinusculeClaw.git
cd MinusculeClaw
./setup.sh
./agent.sh
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

MinusculeClaw passes:
- `AUDIO_INPUT` and `AUDIO_INPUT_PREP` to ASR command templates
- `TEXT` and `WAV_OUTPUT` to TTS command templates

For backend-specific install/runtime flags, use the backend repos above.

## Codex output contract
MinusculeClaw expects strict markers in Codex output:
- `TELEGRAM_REPLY: ...` (required)
- `VOICE_REPLY: ...` (optional)
- `MEMORY_APPEND: ...` (optional)
- `TASK_APPEND: ...` (optional)

If markers are missing, MinusculeClaw sends a safe fallback text reply and logs `parse_fallback`.

## Ingress modes
- `WEBHOOK_MODE=off` (default): long polling (`getUpdates`).
- `WEBHOOK_MODE=on`: consume updates from `runtime/webhook_updates.jsonl`; run webhook receiver with `./webhook_server.py`.
- `WEBHOOK_PUBLIC_URL`: optional; if set, `setup.sh` can register Telegram webhook.

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
