#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [[ -f "$script_dir/tmux-quota-common.sh" ]]; then
    source "$script_dir/tmux-quota-common.sh"
elif [[ -f "$script_dir/../lib/tmux-quota-common.sh" ]]; then
    source "$script_dir/../lib/tmux-quota-common.sh"
else
    printf '#[fg=colour250,bg=colour240] quota lib missing #[default]\n'
    exit 0
fi

fetch_quota_payload() {
    local api_key="$1"
    local base_url="$2"
    local timeout_sec="$3"
    local url="${base_url%/}/api/monitor/usage/quota/limit"
    local response body http_status

    response="$(curl -sS --max-time "$timeout_sec" "$url" \
        -H "Authorization: ${api_key}" \
        -H 'Accept-Language: en-US,en' \
        -H 'Content-Type: application/json' \
        -w $'\n%{http_code}' 2>/dev/null || true)"

    if [[ -z "$response" ]]; then
        return 1
    fi

    http_status="${response##*$'\n'}"
    body="${response%$'\n'*}"
    if [[ "$http_status" != '200' ]]; then
        return 1
    fi
    if ! jq -e . >/dev/null 2>&1 <<<"$body"; then
        return 1
    fi

    printf '%s' "$body"
}

api_key="${ALIBABA_API_KEY:-}"
base_url="${ZAI_API_BASE:-https://api.z.ai}"

if [[ -z "$api_key" ]] && command -v tmux >/dev/null 2>&1; then
    tmux_key="$(tmux show-environment -g ALIBABA_API_KEY 2>/dev/null || true)"
    if [[ "$tmux_key" == ALIBABA_API_KEY=* ]]; then
        api_key="${tmux_key#ALIBABA_API_KEY=}"
    fi
fi

home_dir="$(resolve_home_dir)"
data_home="${XDG_DATA_HOME:-$home_dir/.local/share}"
auth_file="$data_home/opencode/auth.json"

if [[ -z "$api_key" && -f "$auth_file" ]] && command -v jq >/dev/null 2>&1; then
    api_key="$(load_auth_value "$auth_file" '.["alibaba-coding-plan"].key // empty')"
fi

if [[ -z "$api_key" ]]; then
    printf '#[fg=colour250,bg=colour240] alibaba login needed #[default]\n'
    exit 0
fi

if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    printf '#[fg=colour250,bg=colour240] quota fetch failed #[default]\n'
    exit 0
fi

default_cache_file="$(get_cache_dir)/alibaba-quota-limit.json"
legacy_cache_file="$home_dir/.cache/tmux-alibaba-quota-limit.json"
cache_file="${ALIBABA_QUOTA_CACHE_FILE:-$default_cache_file}"
if [[ -z "${ALIBABA_QUOTA_CACHE_FILE:-}" && ! -f "$cache_file" && -f "$legacy_cache_file" ]]; then
    cache_file="$legacy_cache_file"
fi
cache_ttl="${ALIBABA_QUOTA_CACHE_TTL_SEC:-60}"
stale_after="${ALIBABA_QUOTA_STALE_SEC:-1800}"
fetch_timeout="${ALIBABA_QUOTA_TIMEOUT_SEC:-8}"

if ! is_int "$cache_ttl" || (( cache_ttl < 1 )); then
    cache_ttl=60
fi
if ! is_int "$stale_after" || (( stale_after < cache_ttl )); then
    stale_after=1800
fi
if ! is_int "$fetch_timeout" || (( fetch_timeout < 1 )); then
    fetch_timeout=8
fi

payload=''
cache_age="$(read_cached_age "$cache_file")"
stale=0

if (( cache_age <= cache_ttl )); then
    payload="$(read_cached_payload "$cache_file")"
fi

if [[ -z "$payload" ]]; then
    fresh_payload="$(fetch_quota_payload "$api_key" "$base_url" "$fetch_timeout" || true)"
    if [[ -n "$fresh_payload" ]]; then
        payload="$fresh_payload"
        write_cache_payload "$cache_file" "$payload"
        cache_age=0
    else
        payload="$(read_cached_payload "$cache_file")"
        cache_age="$(read_cached_age "$cache_file")"
        stale=1
    fi
fi

if [[ -z "$payload" ]]; then
    printf '#[fg=colour250,bg=colour240] quota fetch failed #[default]\n'
    exit 0
fi

if (( cache_age > stale_after )); then
    stale=1
fi

five_used="$(jq -r '.data.limits[]? | select(.type=="TOKENS_LIMIT" and .unit==3) | .percentage // empty' <<<"$payload" 2>/dev/null || true)"
five_reset_ms="$(jq -r '.data.limits[]? | select(.type=="TOKENS_LIMIT" and .unit==3) | .nextResetTime // empty' <<<"$payload" 2>/dev/null || true)"

seven_used="$(jq -r '.data.limits[]? | select(.type=="TOKENS_LIMIT" and .unit==6) | .percentage // empty' <<<"$payload" 2>/dev/null || true)"
seven_reset_ms="$(jq -r '.data.limits[]? | select(.type=="TOKENS_LIMIT" and .unit==6) | .nextResetTime // empty' <<<"$payload" 2>/dev/null || true)"

tools_used_pct="$(jq -r '.data.limits[]? | select(.type=="TIME_LIMIT" and .unit==5) | .percentage // empty' <<<"$payload" 2>/dev/null || true)"
tools_usage="$(jq -r '.data.limits[]? | select(.type=="TIME_LIMIT" and .unit==5) | .usage // empty' <<<"$payload" 2>/dev/null || true)"
tools_current_value="$(jq -r '.data.limits[]? | select(.type=="TIME_LIMIT" and .unit==5) | .currentValue // empty' <<<"$payload" 2>/dev/null || true)"
tools_remaining="$(jq -r '.data.limits[]? | select(.type=="TIME_LIMIT" and .unit==5) | .remaining // empty' <<<"$payload" 2>/dev/null || true)"
tools_reset_ms="$(jq -r '.data.limits[]? | select(.type=="TIME_LIMIT" and .unit==5) | .nextResetTime // empty' <<<"$payload" 2>/dev/null || true)"

five_alert=0
five_segment="$(unknown_segment '5h')"
if is_int "$five_used"; then
    five_remain=$((100 - five_used))
    if (( five_remain < 0 )); then
        five_remain=0
    fi
    five_left_sec="$(calc_left_sec "$five_reset_ms")"
    five_left_text='?'
    if is_int "$five_left_sec"; then
        five_left_text="$(format_left "$five_left_sec")"
    fi

    if (( five_remain < 20 )); then
        five_alert=1
    fi

    five_segment="$(segment '5h' "$five_remain" "$five_left_text" "$five_alert")"
fi

seven_alert=0
seven_segment="$(unknown_segment '7d')"
if is_int "$seven_used"; then
    seven_remain=$((100 - seven_used))
    if (( seven_remain < 0 )); then
        seven_remain=0
    fi
    seven_left_sec="$(calc_left_sec "$seven_reset_ms")"
    seven_left_text='?'
    if is_int "$seven_left_sec"; then
        seven_left_text="$(format_left "$seven_left_sec")"
        seven_window_sec=$((7 * 24 * 3600))
        seven_elapsed_pct=$(((seven_window_sec - seven_left_sec) * 100 / seven_window_sec))
        if (( seven_elapsed_pct < 0 )); then
            seven_elapsed_pct=0
        fi
        if (( seven_elapsed_pct > 100 )); then
            seven_elapsed_pct=100
        fi
        if (( seven_used > seven_elapsed_pct )); then
            seven_alert=1
        fi
    fi

    seven_segment="$(segment '7d' "$seven_remain" "$seven_left_text" "$seven_alert")"
fi

tools_alert=0
tools_segment="$(unknown_segment '30d')"
tools_used_calc=''
if is_int "$tools_used_pct"; then
    tools_used_calc="$tools_used_pct"
elif is_int "$tools_current_value" && is_int "$tools_usage" && (( tools_usage > 0 )); then
    tools_used_calc=$((tools_current_value * 100 / tools_usage))
elif is_int "$tools_usage" && is_int "$tools_remaining"; then
    tools_total=$((tools_usage + tools_remaining))
    if (( tools_total > 0 )); then
        tools_used_calc=$((tools_usage * 100 / tools_total))
    fi
fi

if is_int "$tools_used_calc"; then
    tools_remain=$((100 - tools_used_calc))
    if (( tools_remain < 0 )); then
        tools_remain=0
    fi
    tools_left_sec="$(calc_left_sec "$tools_reset_ms")"
    tools_left_text='?'
    if is_int "$tools_left_sec"; then
        tools_left_text="$(format_left "$tools_left_sec")"
        tools_window_sec="${ZAI_TOOLS_WINDOW_SEC:-2592000}"
        if ! is_int "$tools_window_sec" || (( tools_window_sec <= 0 )); then
            tools_window_sec=2592000
        fi

        tools_elapsed_pct=$(((tools_window_sec - tools_left_sec) * 100 / tools_window_sec))
        if (( tools_elapsed_pct < 0 )); then
            tools_elapsed_pct=0
        fi
        if (( tools_elapsed_pct > 100 )); then
            tools_elapsed_pct=100
        fi
        if (( tools_used_calc > tools_elapsed_pct )); then
            tools_alert=1
        fi
    fi

    tools_segment="$(segment '30d' "$tools_remain" "$tools_left_text" "$tools_alert")"
fi

summary_text="${five_segment} | ${seven_segment} | ${tools_segment}"

if (( stale == 1 )); then
    summary_text+=" #[fg=colour250]stale $((cache_age / 60))m#[default]"
fi

printf '%s\n' "$summary_text"
