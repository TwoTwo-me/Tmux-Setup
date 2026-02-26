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

api_key="${ZAI_API_KEY:-${ZHIPU_API_KEY:-}}"
base_url="${ZAI_API_BASE:-https://api.z.ai}"

if [[ -z "$api_key" ]] && command -v tmux >/dev/null 2>&1; then
    tmux_key="$(tmux show-environment -g ZAI_API_KEY 2>/dev/null || true)"
    if [[ "$tmux_key" == ZAI_API_KEY=* ]]; then
        api_key="${tmux_key#ZAI_API_KEY=}"
    fi
fi

home_dir="$(resolve_home_dir)"
data_home="${XDG_DATA_HOME:-$home_dir/.local/share}"
auth_file="$data_home/opencode/auth.json"
if [[ -z "$api_key" && -f "$auth_file" ]] && command -v jq >/dev/null 2>&1; then
    api_key="$(jq -r '.["zai-coding-plan"].key // empty' "$auth_file" 2>/dev/null || true)"
fi

if [[ -z "$api_key" ]]; then
    printf '#[fg=colour250,bg=colour240] set ZAI_API_KEY #[default]\n'
    exit 0
fi

response="$(curl -fsS "${base_url%/}/api/monitor/usage/quota/limit" \
    -H "Authorization: ${api_key}" \
    -H 'Accept-Language: en-US,en' \
    -H 'Content-Type: application/json' || true)"

if [[ -z "$response" ]]; then
    printf '#[fg=colour250,bg=colour240] quota fetch failed #[default]\n'
    exit 0
fi

five_used="$(jq -r '.data.limits[]? | select(.type=="TOKENS_LIMIT" and .unit==3) | .percentage // empty' <<<"$response" 2>/dev/null || true)"
five_reset_ms="$(jq -r '.data.limits[]? | select(.type=="TOKENS_LIMIT" and .unit==3) | .nextResetTime // empty' <<<"$response" 2>/dev/null || true)"

seven_used="$(jq -r '.data.limits[]? | select(.type=="TOKENS_LIMIT" and .unit==6) | .percentage // empty' <<<"$response" 2>/dev/null || true)"
seven_reset_ms="$(jq -r '.data.limits[]? | select(.type=="TOKENS_LIMIT" and .unit==6) | .nextResetTime // empty' <<<"$response" 2>/dev/null || true)"

tools_used_pct="$(jq -r '.data.limits[]? | select(.type=="TIME_LIMIT" and .unit==5) | .percentage // empty' <<<"$response" 2>/dev/null || true)"
tools_usage="$(jq -r '.data.limits[]? | select(.type=="TIME_LIMIT" and .unit==5) | .usage // empty' <<<"$response" 2>/dev/null || true)"
tools_current_value="$(jq -r '.data.limits[]? | select(.type=="TIME_LIMIT" and .unit==5) | .currentValue // empty' <<<"$response" 2>/dev/null || true)"
tools_remaining="$(jq -r '.data.limits[]? | select(.type=="TIME_LIMIT" and .unit==5) | .remaining // empty' <<<"$response" 2>/dev/null || true)"
tools_reset_ms="$(jq -r '.data.limits[]? | select(.type=="TIME_LIMIT" and .unit==5) | .nextResetTime // empty' <<<"$response" 2>/dev/null || true)"

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
printf '%s\n' "$summary_text"
