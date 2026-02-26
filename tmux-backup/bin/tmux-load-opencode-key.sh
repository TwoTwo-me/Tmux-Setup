#!/usr/bin/env bash
set -euo pipefail

set_tmux_key() {
    local key="${1:-}"
    if [[ -z "$key" ]]; then
        return 1
    fi

    tmux set-environment -g ZAI_API_KEY "$key" >/dev/null 2>&1 || return 1
    return 0
}

resolve_home_dir() {
    local home_dir="${HOME:-}"
    if [[ -z "$home_dir" ]]; then
        home_dir="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6 || true)"
    fi
    if [[ -z "$home_dir" ]]; then
        home_dir='/root'
    fi
    printf '%s' "$home_dir"
}

if ! command -v tmux >/dev/null 2>&1; then
    exit 0
fi

if [[ -n "${ZAI_API_KEY:-}" ]]; then
    set_tmux_key "$ZAI_API_KEY" || true
    exit 0
fi

tmux_key="$(tmux show-environment -g ZAI_API_KEY 2>/dev/null || true)"
if [[ "$tmux_key" == ZAI_API_KEY=* ]]; then
    existing_key="${tmux_key#ZAI_API_KEY=}"
    if [[ -n "$existing_key" ]]; then
        exit 0
    fi
fi

home_dir="$(resolve_home_dir)"
data_home="${XDG_DATA_HOME:-$home_dir/.local/share}"
auth_file="$data_home/opencode/auth.json"
if [[ -f "$auth_file" ]] && command -v jq >/dev/null 2>&1; then
    api_key="$(jq -r '.["zai-coding-plan"].key // empty' "$auth_file" 2>/dev/null || true)"
    if set_tmux_key "$api_key"; then
        exit 0
    fi
fi

if command -v timeout >/dev/null 2>&1 && command -v pass >/dev/null 2>&1; then
    api_key="$(timeout 1s pass show api/zai 2>/dev/null | head -n1 || true)"
    set_tmux_key "$api_key" || true
fi

exit 0
