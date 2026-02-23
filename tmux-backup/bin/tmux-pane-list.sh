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
    lines="$(tmux list-panes -a -F '#{session_name}|#{window_index}|#{pane_id}|#{pane_index}|#{pane_title}|#{pane_current_command}|#{pane_active}' 2>/dev/null || true)"
else
    if [[ -z "$target" ]]; then
        target="$(tmux display-message -p '#{session_name}:#{window_index}' 2>/dev/null || true)"
    fi
    if [[ -z "$target" ]]; then
        exit 0
    fi
    lines="$(tmux list-panes -t "$target" -F '#{session_name}|#{window_index}|#{pane_id}|#{pane_index}|#{pane_title}|#{pane_current_command}|#{pane_active}' 2>/dev/null || true)"
fi

if [[ -z "$lines" ]]; then
    exit 0
fi

short_host="$(hostname -s 2>/dev/null || true)"
current_pane="$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)"
result=''
count=0
while IFS= read -r line; do
    IFS='|' read -r session_name window_idx pane_id pane_idx pane_title pane_cmd active <<<"$line"
    if [[ -z "$pane_id" || -z "$pane_idx" || -z "$window_idx" ]]; then
        continue
    fi

    pane_title="${pane_title//$'\n'/ }"
    pane_title="${pane_title//$'\r'/ }"

    pane_name="$pane_title"
    if [[ -z "$pane_name" || "$pane_name" == "$short_host" ]]; then
        pane_name="$pane_cmd"
    fi
    if [[ -z "$pane_name" ]]; then
        pane_name='-'
    fi

    if (( ${#pane_name} > label_max )); then
        pane_name="${pane_name:0:label_max-1}~"
    fi

    pane_label="${window_idx}.${pane_idx}:${pane_name}"

    if [[ -n "$result" ]]; then
        result+=" | "
    fi
    is_current=0
    if [[ -n "$current_pane" && "$pane_id" == "$current_pane" ]]; then
        is_current=1
    elif [[ -z "$current_pane" && "$active" == "1" ]]; then
        is_current=1
    fi

    if (( is_current == 1 )); then
        result+="#[range=user|$pane_id]#[bg=colour24,fg=colour231,bold]$pane_label#[default]#[norange]"
    else
        result+="#[range=user|$pane_id]#[fg=colour252]$pane_label#[default]#[norange]"
    fi

    count=$((count + 1))
    if (( count >= max_items )); then
        break
    fi
done <<<"$lines"

printf '%s\n' "$result"
