#!/usr/bin/env bash
set -euo pipefail

path_input="${1:-${PWD:-/root}}"
width="${2:-52}"
home_dir="${HOME:-}"

if [[ -z "$home_dir" ]]; then
    home_dir="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6 || true)"
fi
if [[ -z "$home_dir" ]]; then
    home_dir='/root'
fi

display_path="$path_input"
if [[ "$display_path" == "$home_dir"* ]]; then
    display_path="~${display_path#$home_dir}"
fi

if [[ "$width" =~ ^[0-9]+$ ]] && (( width > 0 )) && (( ${#display_path} > width )); then
    if (( width > 3 )); then
        display_path="...${display_path: -$((width - 3))}"
    else
        display_path="${display_path:0:width}"
    fi
fi

printf '%s\n' "$display_path"
