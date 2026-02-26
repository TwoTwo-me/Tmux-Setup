#!/usr/bin/env bash
set -euo pipefail

session_name="${TMUX_BOOT_SESSION:-web}"
max_wait_sec="${TMUX_BOOT_WAIT_SEC:-30}"

if ! command -v tmux >/dev/null 2>&1; then
    exit 0
fi

if [[ ! -x "$(dirname "$0")/tmux-load-opencode-key.sh" ]]; then
    exit 0
fi

deadline=$((SECONDS + max_wait_sec))
while (( SECONDS < deadline )); do
    if tmux has-session -t "$session_name" >/dev/null 2>&1; then
        "$(dirname "$0")/tmux-load-opencode-key.sh"
        exit 0
    fi
    sleep 1
done

exit 0
