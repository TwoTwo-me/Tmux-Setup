#!/usr/bin/env bash
set -euo pipefail

path_input="${1:-${PWD:-/root}}"
width="${2:-0}"
home_dir="${HOME:-/root}"

print_out() {
    local out="$1"
    if [[ "$width" =~ ^[0-9]+$ ]] && (( width > 0 )); then
        if (( ${#out} > width )); then
            out="${out:0:width}"
        fi
        printf '%-*s\n' "$width" "$out"
        return
    fi
    printf '%s\n' "$out"
}

display_path="$path_input"
if [[ "$display_path" == "$home_dir"* ]]; then
    display_path="~${display_path#$home_dir}"
fi

shorten_tail() {
    local text="$1"
    local max_len="$2"
    if (( ${#text} <= max_len )); then
        printf '%s' "$text"
        return
    fi
    if (( max_len <= 3 )); then
        printf '%s' "${text:0:max_len}"
        return
    fi
    printf '...%s' "${text: -$((max_len - 3))}"
}

max_len=42
display_path="$(shorten_tail "$display_path" "$max_len")"

if git -C "$path_input" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    repo_root="$(git -C "$path_input" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$path_input")"
    project="$(basename "$repo_root")"
    branch="$(git -C "$path_input" symbolic-ref --quiet --short HEAD 2>/dev/null || git -C "$path_input" rev-parse --short HEAD 2>/dev/null || printf '?')"
    dirty=''
    if [[ -n "$(git -C "$path_input" status --porcelain --ignore-submodules=dirty 2>/dev/null)" ]]; then
        dirty='*'
    fi

    rel_path='.'
    if [[ "$path_input" == "$repo_root" ]]; then
        rel_path='.'
    elif [[ "$path_input" == "$repo_root"/* ]]; then
        rel_path="${path_input#$repo_root/}"
    else
        rel_path="$display_path"
    fi

    rel_path="$(shorten_tail "$rel_path" 26)"
    if [[ "$rel_path" == '.' ]]; then
        print_out "$project $branch$dirty"
    else
        print_out "$project $branch$dirty $rel_path"
    fi
    exit 0
fi

print_out "$display_path"
