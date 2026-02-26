#!/usr/bin/env bash
set -euo pipefail

fail_count=0

ok() {
    printf '[OK] %s\n' "$1"
}

warn() {
    printf '[WARN] %s\n' "$1"
}

fail() {
    printf '[FAIL] %s\n' "$1"
    fail_count=$((fail_count + 1))
}

if systemctl is-enabled ttyd-tmux.service >/dev/null 2>&1; then
    ok 'ttyd-tmux.service is enabled'
else
    fail 'ttyd-tmux.service is not enabled'
fi

if systemctl is-enabled tmux-zai-key-bootstrap.service >/dev/null 2>&1; then
    ok 'tmux-zai-key-bootstrap.service is enabled'
else
    fail 'tmux-zai-key-bootstrap.service is not enabled'
fi

bootstrap_result="$(systemctl show tmux-zai-key-bootstrap.service -p Result --value 2>/dev/null || true)"
if [[ "$bootstrap_result" == "success" ]]; then
    ok 'bootstrap service last result: success'
elif [[ -n "$bootstrap_result" ]]; then
    warn "bootstrap service last result: ${bootstrap_result}"
else
    warn 'bootstrap service result unavailable'
fi

if tmux has-session -t web >/dev/null 2>&1; then
    ok 'tmux session web exists'
else
    fail 'tmux session web does not exist'
fi

tmux_key_line="$(tmux show-environment -g ZAI_API_KEY 2>/dev/null || true)"
if [[ "$tmux_key_line" == ZAI_API_KEY=* ]]; then
    key_value="${tmux_key_line#ZAI_API_KEY=}"
    if [[ -n "$key_value" ]]; then
        ok "tmux global ZAI_API_KEY is set (length=${#key_value})"
    else
        fail 'tmux global ZAI_API_KEY is empty'
    fi
else
    fail 'tmux global ZAI_API_KEY is missing'
fi

status_format="$(tmux show-options -gqv status-format[1] 2>/dev/null || true)"
if [[ "$status_format" == *"tmux-zai-quota.sh"* ]]; then
    ok 'status-format[1] references tmux-zai-quota.sh'
else
    warn 'status-format[1] does not reference tmux-zai-quota.sh'
fi

quota_output="$("$(dirname "$0")/tmux-zai-quota.sh" 2>/dev/null || true)"
if [[ -z "$quota_output" ]]; then
    fail 'quota script returned empty output'
elif [[ "$quota_output" == *'set ZAI_API_KEY'* ]]; then
    fail 'quota script reports missing key'
else
    ok "quota script output: ${quota_output}"
fi

if (( fail_count > 0 )); then
    printf '\nHealthcheck result: FAIL (%s issue(s))\n' "$fail_count"
    exit 1
fi

printf '\nHealthcheck result: PASS\n'
