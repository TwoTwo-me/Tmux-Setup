#!/usr/bin/env bash
set -euo pipefail

path_input="${1:-${PWD:-/root}}"

if ! git -C "$path_input" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    exit 0
fi

repo_root="$(git -C "$path_input" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$path_input")"
repo_name="$(basename "$repo_root")"
branch_name="$(git -C "$path_input" symbolic-ref --quiet --short HEAD 2>/dev/null || git -C "$path_input" rev-parse --short HEAD 2>/dev/null || printf '?')"
dirty=''

if [[ -n "$(git -C "$path_input" status --porcelain --ignore-submodules=dirty 2>/dev/null)" ]]; then
    dirty='*'
fi

printf '#[bg=colour220,fg=colour16,bold] %s:%s%s #[default]\n' "$repo_name" "$branch_name" "$dirty"
