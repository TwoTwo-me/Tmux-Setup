#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${ZAI_API_KEY:-}" ]]; then
    tmux set-environment -g ZAI_API_KEY "$ZAI_API_KEY"
    exit 0
fi

if ! command -v pass >/dev/null 2>&1; then
    exit 0
fi

api_key="$(pass show api/zai 2>/dev/null | head -n1 || true)"
if [[ -z "$api_key" ]]; then
    exit 0
fi

tmux set-environment -g ZAI_API_KEY "$api_key"
