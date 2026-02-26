#!/usr/bin/env bash
set -euo pipefail

width="${1:-0}"
stats="$("$(dirname "$0")/tmux-sys-stats.sh" 2>/dev/null || printf 'CPU ?%% RAM ?%%')"
text="$stats | $(date '+%Y-%m-%d %H:%M %Z')"

if [[ "$width" =~ ^[0-9]+$ ]] && (( width > 0 )); then
    if (( ${#text} > width )); then
        text="${text:0:width}"
    fi
    printf '%*s\n' "$width" "$text"
    exit 0
fi

printf '%s\n' "$text"
