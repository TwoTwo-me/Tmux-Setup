#!/usr/bin/env bash
set -euo pipefail

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

is_int() {
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}

format_left() {
    local left_sec="${1:-0}"
    if ! is_int "$left_sec" || (( left_sec < 0 )); then
        left_sec=0
    fi

    local hours mins
    hours=$((left_sec / 3600))
    mins=$(((left_sec % 3600) / 60))
    printf '%d:%02d' "$hours" "$mins"
}

calc_left_sec() {
    local reset_raw="${1:-}"
    if [[ -z "$reset_raw" ]]; then
        printf '%s' ""
        return
    fi

    local now_sec reset_sec left_sec
    now_sec="$(date +%s)"
    reset_sec="$(date -d "$reset_raw" +%s 2>/dev/null || true)"
    if ! is_int "$reset_sec"; then
        printf '%s' ""
        return
    fi

    left_sec=$((reset_sec - now_sec))
    if (( left_sec < 0 )); then
        left_sec=0
    fi
    printf '%s' "$left_sec"
}

segment() {
    local label="$1"
    local remain_pct="$2"
    local left_text="$3"
    local is_alert="$4"

    if [[ "$is_alert" == "1" ]]; then
        printf '#[fg=colour231,bg=colour160,bold] %s %s%%+%s #[default]' "$label" "$remain_pct" "$left_text"
    else
        printf '#[fg=colour255,bg=colour238] %s %s%%+%s #[default]' "$label" "$remain_pct" "$left_text"
    fi
}

unknown_segment() {
    local label="$1"
    printf '#[fg=colour250,bg=colour240] %s ? #[default]' "$label"
}

load_auth_value() {
    local auth_file="$1"
    local jq_filter="$2"
    jq -r "$jq_filter" "$auth_file" 2>/dev/null || true
}

select_auth_file() {
    local data_home="$1"
    local explicit="${COPILOT_AUTH_FILE:-}"
    if [[ -n "$explicit" ]]; then
        printf '%s' "$explicit"
        return
    fi

    printf '%s' "$data_home/opencode/auth.json"
}

expires_to_sec() {
    local expires_raw="${1:-}"
    if ! is_int "$expires_raw"; then
        printf '%s' ""
        return
    fi

    if (( expires_raw >= 1000000000000 )); then
        printf '%s' $((expires_raw / 1000))
        return
    fi

    printf '%s' "$expires_raw"
}

fetch_session_payload() {
    local oauth_token="$1"
    local timeout_sec="$2"
    local url='https://api.github.com/copilot_internal/v2/token'
    local response body http_status

    response="$(curl -sS --max-time "$timeout_sec" \
        -H 'Accept: application/json' \
        -H "Authorization: Bearer ${oauth_token}" \
        -H 'User-Agent: GitHubCopilotChat/0.35.0' \
        -H 'Editor-Version: vscode/1.107.0' \
        -H 'Editor-Plugin-Version: copilot-chat/0.35.0' \
        -H 'Copilot-Integration-Id: vscode-chat' \
        "$url" \
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

write_token_cache() {
    local cache_file="$1"
    local payload="$2"
    local cache_dir tmp_file

    cache_dir="$(dirname "$cache_file")"
    mkdir -p "$cache_dir"
    tmp_file="$(mktemp "${cache_file}.tmp.XXXXXX")"
    chmod 600 "$tmp_file" 2>/dev/null || true
    printf '%s\n' "$payload" >"$tmp_file"
    mv "$tmp_file" "$cache_file"
}

fetch_quota_payload() {
    local session_token="$1"
    local timeout_sec="$2"
    local url='https://api.github.com/copilot_internal/user'
    local response body http_status

    response="$(curl -sS --max-time "$timeout_sec" \
        -H 'Accept: application/json' \
        -H "Authorization: Bearer ${session_token}" \
        -H 'User-Agent: GitHubCopilotChat/0.35.0' \
        -H 'Editor-Version: vscode/1.107.0' \
        -H 'Editor-Plugin-Version: copilot-chat/0.35.0' \
        -H 'Copilot-Integration-Id: vscode-chat' \
        "$url" \
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

read_cached_payload() {
    local cache_file="$1"
    if [[ ! -f "$cache_file" ]]; then
        return 1
    fi

    jq -c '.payload // empty' "$cache_file" 2>/dev/null || true
}

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

write_cache_payload() {
    local cache_file="$1"
    local payload="$2"
    local cache_dir tmp_file
    cache_dir="$(dirname "$cache_file")"
    mkdir -p "$cache_dir"
    tmp_file="$(mktemp "${cache_file}.tmp.XXXXXX")"
    chmod 600 "$tmp_file" 2>/dev/null || true
    printf '{"payload":%s}\n' "$payload" >"$tmp_file"
    mv "$tmp_file" "$cache_file"
}

extract_number() {
    local payload="$1"
    local jq_filter="$2"
    jq -r "$jq_filter" <<<"$payload" 2>/dev/null || true
}

home_dir="$(resolve_home_dir)"
cache_token_file="${COPILOT_TOKEN_CACHE_FILE:-$home_dir/.cache/tmux-copilot-token.json}"
cache_file="${COPILOT_QUOTA_CACHE_FILE:-$home_dir/.cache/tmux-copilot-user.json}"
cache_ttl="${COPILOT_QUOTA_CACHE_TTL_SEC:-60}"
stale_after="${COPILOT_QUOTA_STALE_SEC:-1800}"
fetch_timeout="${COPILOT_QUOTA_TIMEOUT_SEC:-8}"

if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    printf '#[fg=colour250,bg=colour240] copilot deps missing #[default]\n'
    exit 0
fi

data_home="${XDG_DATA_HOME:-$home_dir/.local/share}"
auth_file="$(select_auth_file "$data_home")"

oauth_token="${COPILOT_OAUTH_TOKEN:-}"
if [[ -z "$oauth_token" && -f "$auth_file" ]]; then
    oauth_token="$(load_auth_value "$auth_file" '."github-copilot".refresh // ."github-copilot".access // empty')"
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

now_sec="$(date +%s)"
cached_session_token="$(jq -r '.token // empty' "$cache_token_file" 2>/dev/null || true)"
cached_expires_raw="$(jq -r '.expires_at // empty' "$cache_token_file" 2>/dev/null || true)"
cached_expires_sec="$(expires_to_sec "$cached_expires_raw")"

session_token=''
session_expires_sec=''

if [[ -n "$cached_session_token" && -n "$cached_expires_sec" ]] && (( cached_expires_sec - now_sec > 300 )); then
    session_token="$cached_session_token"
    session_expires_sec="$cached_expires_sec"
fi

if [[ -z "$session_token" && -n "$oauth_token" ]]; then
    token_payload="$(fetch_session_payload "$oauth_token" "$fetch_timeout" || true)"
    if [[ -n "$token_payload" ]]; then
        new_token="$(jq -r '.token // empty' <<<"$token_payload" 2>/dev/null || true)"
        new_expires_raw="$(jq -r '.expires_at // empty' <<<"$token_payload" 2>/dev/null || true)"
        new_expires_sec="$(expires_to_sec "$new_expires_raw")"

        if [[ -n "$new_token" && -n "$new_expires_sec" ]]; then
            session_token="$new_token"
            session_expires_sec="$new_expires_sec"
            write_token_cache "$cache_token_file" "$token_payload"
        fi
    fi
fi

if [[ -z "$session_token" && -n "$cached_session_token" && -n "$cached_expires_sec" ]] && (( cached_expires_sec > now_sec )); then
    session_token="$cached_session_token"
    session_expires_sec="$cached_expires_sec"
fi

if [[ -z "$session_token" ]]; then
    printf '#[fg=colour250,bg=colour240] copilot login needed #[default]\n'
    exit 0
fi

payload=''
cache_age="$(read_cached_age "$cache_file")"
stale=0

if (( cache_age <= cache_ttl )); then
    payload="$(read_cached_payload "$cache_file")"
fi

if [[ -z "$payload" ]]; then
    fresh_payload="$(fetch_quota_payload "$session_token" "$fetch_timeout" || true)"
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
    printf '#[fg=colour250,bg=colour240] copilot quota unavailable #[default]\n'
    exit 0
fi

if (( cache_age > stale_after )); then
    stale=1
fi

remain_pct="$(extract_number "$payload" '(.quota_snapshots.premium_interactions.percent_remaining // empty) | tonumber? | floor // empty')"
reset_date="$(jq -r '.quota_reset_date // empty' <<<"$payload" 2>/dev/null || true)"

copilot_segment="$(unknown_segment 'copilot')"
if is_int "$remain_pct"; then
    if (( remain_pct < 0 )); then
        remain_pct=0
    fi
    if (( remain_pct > 100 )); then
        remain_pct=100
    fi

    left_sec="$(calc_left_sec "$reset_date")"
    left_text='?'
    if is_int "$left_sec"; then
        left_text="$(format_left "$left_sec")"
    fi

    alert=0
    if (( remain_pct < 20 )); then
        alert=1
    fi

    copilot_segment="$(segment 'copilot' "$remain_pct" "$left_text" "$alert")"
fi

if (( stale == 1 )); then
    printf '%s #[fg=colour250,bg=colour240] stale %sm #[default]\n' "$copilot_segment" "$((cache_age / 60))"
    exit 0
fi

printf '%s\n' "$copilot_segment"
