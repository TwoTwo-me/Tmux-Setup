#!/usr/bin/env bash
set -euo pipefail

if ! command -v tmux >/dev/null 2>&1; then
    exit 0
fi

raw_target="${1:-}"
if [[ -z "$raw_target" ]]; then
    exit 0
fi
client_tty="${2:-}"

refresh_now() {
    if [[ -n "$client_tty" ]]; then
        tmux refresh-client -t "$client_tty" 2>/dev/null || tmux refresh-client 2>/dev/null || true
        return
    fi
    tmux refresh-client 2>/dev/null || true
}

target="${raw_target##*|}"

if [[ "$target" =~ ^%[0-9]+$ ]]; then
    pane_meta="$(tmux display-message -p -t "$target" '#{session_name}|#{window_id}|#{window_index}' 2>/dev/null || true)"
    IFS='|' read -r target_session target_window_id target_window_index <<<"$pane_meta"

    if [[ -n "${target_session:-}" ]]; then
        tmux switch-client -t "$target_session" 2>/dev/null || true
    fi

    moved=0
    if [[ -n "${target_window_id:-}" ]]; then
        if tmux select-window -t "$target_window_id" 2>/dev/null; then
            moved=1
        fi
    fi
    if (( moved == 0 )) && [[ -n "${target_session:-}" && -n "${target_window_index:-}" ]]; then
        tmux select-window -t "${target_session}:${target_window_index}" 2>/dev/null || true
    fi

    tmux select-pane -t "$target" 2>/dev/null || true
    refresh_now
    exit 0
fi

if [[ "$target" =~ ^@[0-9]+$ ]]; then
    tmux select-window -t "$target" 2>/dev/null || true
    refresh_now
    exit 0
fi

tmux select-window -t = 2>/dev/null || true
refresh_now
exit 0
