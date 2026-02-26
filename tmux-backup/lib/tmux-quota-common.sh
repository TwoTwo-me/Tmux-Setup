#!/usr/bin/env bash
# tmux-quota-common.sh - Shared functions for tmux quota scripts
# Source this file; do not execute directly.

# Resolve home directory with fallbacks
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

# Check if argument is a positive integer
is_int() {
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}

# Format seconds remaining as compact DHM string
format_left() {
    local left_sec="${1:-0}"
    if ! is_int "$left_sec" || (( left_sec < 0 )); then
        left_sec=0
    fi

    local total_mins total_hours days hours mins
    total_mins=$((left_sec / 60))
    total_hours=$((total_mins / 60))
    mins=$((total_mins % 60))
    days=$((total_hours / 24))
    hours=$((total_hours % 24))
    
    if (( days > 0 )); then
        printf '%dd%dh%dm' "$days" "$hours" "$mins"
    elif (( hours > 0 )); then
        printf '%dh%dm' "$hours" "$mins"
    else
        printf '%dm' "$mins"
    fi
}

# Calculate seconds left from reset timestamp
# Accepts: seconds, milliseconds, or ISO date string
calc_left_sec() {
    local reset_raw="${1:-}"
    if [[ -z "$reset_raw" ]]; then
        printf '%s' ""
        return
    fi

    local now_sec reset_sec left_sec
    now_sec="$(date +%s)"

    # Try as integer first (sec or ms)
    if is_int "$reset_raw"; then
        if (( reset_raw >= 1000000000000 )); then
            reset_sec=$((reset_raw / 1000))
        else
            reset_sec="$reset_raw"
        fi
    else
        # Try as date string
        reset_sec="$(date -d "$reset_raw" +%s 2>/dev/null || true)"
        if ! is_int "$reset_sec"; then
            printf '%s' ""
            return
        fi
    fi

    left_sec=$((reset_sec - now_sec))
    if (( left_sec < 0 )); then
        left_sec=0
    fi
    printf '%s' "$left_sec"
}

# Format a quota segment with tmux colors
segment() {
    local label="$1"
    local remain_pct="$2"
    local left_text="$3"
    local is_alert="$4"
    local text
    text="${label} ${remain_pct}% ${left_text}"
    if [[ "$is_alert" == "1" ]]; then
        printf '#[fg=colour196,bold]%s#[default]' "$text"
    else
        printf '#[fg=colour252]%s#[default]' "$text"
    fi
}

# Format an unknown/missing segment
unknown_segment() {
    local label="$1"
    printf '#[fg=colour250]%s ?#[default]' "$label"
}

# Load a value from auth JSON file using jq
load_auth_value() {
    local auth_file="$1"
    local jq_filter="$2"
    jq -r "$jq_filter" "$auth_file" 2>/dev/null || true
}

# Read cached payload from file
read_cached_payload() {
    local cache_file="$1"
    if [[ ! -f "$cache_file" ]]; then
        return 1
    fi
    jq -c '.payload // empty' "$cache_file" 2>/dev/null || true
}

# Read cache file age in seconds
read_cached_age() {
    local cache_file="$1"
    if [[ ! -f "$cache_file" ]]; then
        printf '999999'
        return
    fi

    local now_ts file_ts age_sec
    now_ts="$(date +%s)"
    file_ts="$(stat -c %Y "$cache_file" 2>/dev/null || echo "$now_ts")"
    age_sec=$((now_ts - file_ts))
    if (( age_sec < 0 )); then
        age_sec=0
    fi
    printf '%s' "$age_sec"
}

# Write payload to cache file with atomic write and optional locking
write_cache_payload() {
    local cache_file="$1"
    local payload="$2"
    local cache_dir tmp_file lock_fd
    
    cache_dir="$(dirname "$cache_file")"
    mkdir -p "$cache_dir"
    
    # Try flock if available (non-blocking with short timeout)
    if command -v flock >/dev/null 2>&1; then
        lock_fd=200
        # shellcheck disable=SC2086
        exec 200>"${cache_file}.lock"
        if ! flock -w 2 200; then
            return 1  # Skip write if lock not acquired
        fi
    fi
    
    tmp_file="$(mktemp "${cache_file}.tmp.XXXXXX")"
    chmod 600 "$tmp_file" 2>/dev/null || true
    printf '{"payload":%s}\n' "$payload" >"$tmp_file"
    mv "$tmp_file" "$cache_file"
    
    # Release lock if we acquired it
    if command -v flock >/dev/null 2>&1 && [[ -n "${lock_fd:-}" ]]; then
        flock -u 200 2>/dev/null || true
        exec 200>&-
    fi
}

# Get XDG-compliant cache directory for tmux-quota
get_cache_dir() {
    local home_dir
    home_dir="$(resolve_home_dir)"
    printf '%s' "${TMUX_QUOTA_CACHE_DIR:-${XDG_CACHE_HOME:-$home_dir/.cache}/tmux-quota}"
}

# Get XDG-compliant bin directory
get_bin_dir() {
    local home_dir
    home_dir="$(resolve_home_dir)"
    printf '%s' "${TMUX_BIN_DIR:-${XDG_BIN_HOME:-$home_dir/.local/bin}}"
}

# Get tmux conf path
get_tmux_conf() {
    local home_dir
    home_dir="$(resolve_home_dir)"
    printf '%s' "${TMUX_CONF_FILE:-$home_dir/.tmux.conf}"
}

# Source this library from a script, handling both repo and installed locations
# Usage: source_quota_lib
source_quota_lib() {
    local script_dir lib_path
    
    # Get directory of the calling script
    script_dir="$(cd "$(dirname "${BASH_SOURCE[1]:-$0}")" && pwd)"
    
    # Try installed location first (same dir as script)
    if [[ -f "$script_dir/tmux-quota-common.sh" ]]; then
        lib_path="$script_dir/tmux-quota-common.sh"
    # Then try repo structure (../lib/)
    elif [[ -f "$script_dir/../lib/tmux-quota-common.sh" ]]; then
        lib_path="$script_dir/../lib/tmux-quota-common.sh"
    else
        return 1
    fi
    
    # shellcheck source=tmux-quota-common.sh
    source "$lib_path"
}
