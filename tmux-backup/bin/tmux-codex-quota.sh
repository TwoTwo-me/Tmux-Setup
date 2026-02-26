#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
quota_common_lib=''
if [[ -f "$script_dir/tmux-quota-common.sh" ]]; then
    quota_common_lib="$script_dir/tmux-quota-common.sh"
elif [[ -f "$script_dir/../lib/tmux-quota-common.sh" ]]; then
    quota_common_lib="$script_dir/../lib/tmux-quota-common.sh"
else
    printf '#[fg=colour250,bg=colour240] codex quota unavailable #[default]\n'
    exit 0
fi
source "$quota_common_lib"

select_auth_file() {
    local data_home="$1"
    local home_dir="$2"
    local explicit="${CODEX_AUTH_FILE:-}"
    local -a candidates
    local candidate

    if [[ -n "$explicit" ]]; then
        printf '%s' "$explicit"
        return
    fi

    candidates=(
        "$data_home/opencode/auth.json"
        "$home_dir/.codex/auth.json"
    )

    for candidate in "${candidates[@]}"; do
        if [[ -f "$candidate" ]]; then
            printf '%s' "$candidate"
            return
        fi
    done

    printf '%s' "${candidates[0]}"
}

fetch_payload() {
    local access_token="$1"
    local account_id="$2"
    local timeout_sec="$3"
    local url='https://chatgpt.com/backend-api/wham/usage'
    local response body http_status
    local -a curl_args

    curl_args=(
        -sS
        --max-time "$timeout_sec"
        -H "Authorization: Bearer ${access_token}"
        -H 'Accept: application/json'
        "$url"
        -w $'\n%{http_code}'
    )

    if [[ -n "$account_id" ]]; then
        curl_args=(
            -sS
            --max-time "$timeout_sec"
            -H "Authorization: Bearer ${access_token}"
            -H "ChatGPT-Account-Id: ${account_id}"
            -H 'Accept: application/json'
            "$url"
            -w $'\n%{http_code}'
        )
    fi

    response="$(curl "${curl_args[@]}" 2>/dev/null || true)"
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

extract_number() {
    local payload="$1"
    local jq_filter="$2"
    jq -r "$jq_filter" <<<"$payload" 2>/dev/null || true
}

home_dir="$(resolve_home_dir)"
default_cache_file="$(get_cache_dir)/codex-usage.json"
legacy_cache_file="$home_dir/.cache/tmux-codex-usage.json"
cache_file="${CODEX_QUOTA_CACHE_FILE:-$default_cache_file}"
if [[ -z "${CODEX_QUOTA_CACHE_FILE:-}" && ! -f "$cache_file" && -f "$legacy_cache_file" ]]; then
    cache_file="$legacy_cache_file"
fi
cache_ttl="${CODEX_QUOTA_CACHE_TTL_SEC:-60}"
stale_after="${CODEX_QUOTA_STALE_SEC:-1800}"
fetch_timeout="${CODEX_QUOTA_TIMEOUT_SEC:-8}"

if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    printf '#[fg=colour250,bg=colour240] codex deps missing #[default]\n'
    exit 0
fi

data_home="${XDG_DATA_HOME:-$home_dir/.local/share}"
auth_file="$(select_auth_file "$data_home" "$home_dir")"

access_token="${CODEX_ACCESS_TOKEN:-}"
account_id="${CODEX_ACCOUNT_ID:-}"

if [[ -z "$access_token" && -f "$auth_file" ]]; then
    access_token="$(load_auth_value "$auth_file" '.openai.access // .codex.access // .chatgpt.access // .tokens.access_token // empty')"
fi
if [[ -z "$account_id" && -f "$auth_file" ]]; then
    account_id="$(load_auth_value "$auth_file" '.openai.accountId // .codex.accountId // .chatgpt.accountId // .tokens.account_id // .tokens.accountId // empty')"
fi

if [[ -z "$access_token" ]]; then
    printf '#[fg=colour250,bg=colour240] codex login needed #[default]\n'
    exit 0
fi

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
    fresh_payload="$(fetch_payload "$access_token" "$account_id" "$fetch_timeout" || true)"
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
    printf '#[fg=colour250,bg=colour240] codex quota unavailable #[default]\n'
    exit 0
fi

if (( cache_age > stale_after )); then
    stale=1
fi

five_used="$(extract_number "$payload" '(.rate_limit.primary_window.used_percent // empty) | tonumber? | floor // empty')"
five_reset="$(extract_number "$payload" '(.rate_limit.primary_window.reset_at // empty) | tonumber? | floor // empty')"
five_window="$(extract_number "$payload" '(.rate_limit.primary_window.limit_window_seconds // empty) | tonumber? | floor // empty')"

seven_used="$(extract_number "$payload" '(.rate_limit.secondary_window.used_percent // empty) | tonumber? | floor // empty')"
seven_reset="$(extract_number "$payload" '(.rate_limit.secondary_window.reset_at // empty) | tonumber? | floor // empty')"
seven_window="$(extract_number "$payload" '(.rate_limit.secondary_window.limit_window_seconds // empty) | tonumber? | floor // empty')"

tools_used="$(extract_number "$payload" '(
    .code_review_rate_limit.primary_window.used_percent
    // (.additional_rate_limits[]? | select((.metered_feature // "") | test("code|review|tool"; "i")) | .rate_limit.primary_window.used_percent)
    // empty
) | tonumber? | floor // empty')"
tools_reset="$(extract_number "$payload" '(
    .code_review_rate_limit.primary_window.reset_at
    // (.additional_rate_limits[]? | select((.metered_feature // "") | test("code|review|tool"; "i")) | .rate_limit.primary_window.reset_at)
    // empty
) | tonumber? | floor // empty')"
tools_window="$(extract_number "$payload" '(
    .code_review_rate_limit.primary_window.limit_window_seconds
    // (.additional_rate_limits[]? | select((.metered_feature // "") | test("code|review|tool"; "i")) | .rate_limit.primary_window.limit_window_seconds)
    // empty
) | tonumber? | floor // empty')"

five_alert=0
five_segment="$(unknown_segment '5h')"
if is_int "$five_used"; then
    five_remain=$((100 - five_used))
    if (( five_remain < 0 )); then
        five_remain=0
    fi
    five_left_sec="$(calc_left_sec "$five_reset")"
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
    seven_left_sec="$(calc_left_sec "$seven_reset")"
    seven_left_text='?'
    seven_alert=0

    if is_int "$seven_left_sec"; then
        seven_left_text="$(format_left "$seven_left_sec")"
        if ! is_int "$seven_window" || (( seven_window <= 0 )); then
            seven_window=$((7 * 24 * 3600))
        fi

        seven_elapsed_pct=$(((seven_window - seven_left_sec) * 100 / seven_window))
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
if is_int "$tools_used"; then
    tools_remain=$((100 - tools_used))
    if (( tools_remain < 0 )); then
        tools_remain=0
    fi
    tools_left_sec="$(calc_left_sec "$tools_reset")"
    tools_left_text='?'
    if is_int "$tools_left_sec"; then
        tools_left_text="$(format_left "$tools_left_sec")"
        if ! is_int "$tools_window" || (( tools_window <= 0 )); then
            tools_window=$((30 * 24 * 3600))
        fi
        tools_elapsed_pct=$(((tools_window - tools_left_sec) * 100 / tools_window))
        if (( tools_elapsed_pct < 0 )); then
            tools_elapsed_pct=0
        fi
        if (( tools_elapsed_pct > 100 )); then
            tools_elapsed_pct=100
        fi
        if (( tools_used > tools_elapsed_pct )); then
            tools_alert=1
        fi
    fi

    tools_segment="$(segment '30d' "$tools_remain" "$tools_left_text" "$tools_alert")"
fi

summary_text="${five_segment} | ${seven_segment} | ${tools_segment}"

if (( stale == 1 )); then
    summary_text+=" #[fg=colour250]stale $((cache_age / 60))m#[default]"
    printf '%s\n' "$summary_text"
    exit 0
fi

printf '%s\n' "$summary_text"
