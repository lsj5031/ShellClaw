#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/common.sh"
load_env

msg="Daily heartbeat for MinusculeClaw. Summarize today, surface urgent tasks from TASKS/pending.md, and suggest next 1-3 actions."
"$ROOT_DIR/agent.sh" --inject-text "$msg"
