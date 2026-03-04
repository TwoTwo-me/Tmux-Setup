#!/usr/bin/env bash
set -euo pipefail

if ! command -v tmux >/dev/null 2>&1; then
    exit 0
fi

scope="${TMUX_PANE_LIST_SCOPE:-all}"
target="${1:-}"
max_items="${TMUX_PANE_LIST_MAX_ITEMS:-16}"
label_max="${TMUX_PANE_LIST_LABEL_MAX:-18}"

if [[ ! "$max_items" =~ ^[0-9]+$ ]] || (( max_items <= 0 )); then
    max_items=16
fi
if [[ ! "$label_max" =~ ^[0-9]+$ ]] || (( label_max <= 4 )); then
    label_max=18
fi

if [[ "$scope" == "all" || "$target" == "all" ]]; then
    lines="$(tmux list-windows -a -F '#{session_name}|#{window_index}|#{window_id}|#{window_name}|#{window_active}' 2>/dev/null || true)"
else
    if [[ -z "$target" ]]; then
        target="$(tmux display-message -p '#{session_name}:#{window_index}' 2>/dev/null || true)"
    fi
    if [[ -z "$target" ]]; then
        exit 0
    fi
    lines="$(tmux list-windows -t "$target" -F '#{session_name}|#{window_index}|#{window_id}|#{window_name}|#{window_active}' 2>/dev/null || true)"
fi

if [[ -z "$lines" ]]; then
    exit 0
fi

result=''
count=0
while IFS= read -r line; do
    IFS='|' read -r session_name window_idx window_id window_name active <<<"$line"
    if [[ -z "$window_id" || -z "$window_idx" ]]; then
        continue
    fi

    window_name="${window_name//$'\n'/ }"
    window_name="${window_name//$'\r'/ }"

    if [[ -z "$window_name" ]]; then
        window_name='-'
    fi

    if (( ${#window_name} > label_max )); then
        window_name="${window_name:0:label_max-1}~"
    fi

    pane_label="${session_name}:${window_idx}:${window_name}"

    if [[ -n "$result" ]]; then
        result+=" | "
    fi
    is_current=0
    current_window="$(tmux display-message -p '#{window_id}' 2>/dev/null || true)"
    if [[ -n "$current_window" && "$window_id" == "$current_window" ]]; then
        is_current=1
    elif [[ -z "$current_window" && "$active" == "1" ]]; then
        is_current=1
    fi

    if (( is_current == 1 )); then
        result+="#[range=user|$window_id]#[bg=colour24,fg=colour231,bold]$pane_label#[default]#[norange]"
    else
        result+="#[range=user|$window_id]#[fg=colour252]$pane_label#[default]#[norange]"
    fi

    count=$((count + 1))
    if (( count >= max_items )); then
        break
    fi
done <<<"$lines"

printf '%s\n' "$result"
