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

home_dir="$(resolve_home_dir)"
snapshot_file="${CODEX_QUOTA_FILE:-$home_dir/.cache/codex_quota_status.txt}"
opencode_bin="${OPENCODE_BIN:-/root/.opencode/bin/opencode}"
model_key="${CODEX_STATS_MODEL:-openai/gpt-5.3-codex}"
days="${CODEX_STATS_DAYS:-1}"

mkdir -p "$(dirname "$snapshot_file")"

if [[ ! -x "$opencode_bin" ]]; then
    exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
    exit 0
fi

stats_output="$($opencode_bin stats --days "$days" --models 50 2>/dev/null || true)"
if [[ -z "$stats_output" ]]; then
    exit 0
fi

summary="$({ STATS_TEXT="$stats_output" python3 - "$model_key" <<'PY'
import os
import re
import sys

model = sys.argv[1].strip()
text = os.environ.get("STATS_TEXT", "")
if not text:
    sys.exit(1)

text = re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]", "", text)
lines = [line.rstrip() for line in text.splitlines()]

start = None
for idx, line in enumerate(lines):
    if model in line:
        start = idx
        break

if start is None:
    sys.exit(1)

fields = {}
for line in lines[start + 1 :]:
    stripped = line.strip()
    if not stripped:
        continue
    if stripped.startswith(("├", "└", "┌")):
        break
    stripped = stripped.lstrip("│ ").strip()
    match = re.match(r"^(Messages|Input Tokens|Output Tokens|Cache Read|Cost)\s+(.+?)\s*$", stripped)
    if match:
        value = match.group(2).strip().replace("│", " ").replace("┃", " ")
        value = value.split()[0] if value else ""
        fields[match.group(1)] = value

messages = fields.get("Messages")
input_tokens = fields.get("Input Tokens")
output_tokens = fields.get("Output Tokens")
if not (messages and input_tokens and output_tokens):
    sys.exit(1)

cache_read = fields.get("Cache Read", "-")
cost = fields.get("Cost", "$0")
print(f"Msgs {messages} In {input_tokens} Out {output_tokens} Cache {cache_read} Cost {cost}")
PY
} 2>/dev/null || true)"

if [[ -z "$summary" ]]; then
    exit 0
fi

printf '%s\n' "$summary" >"$snapshot_file"
exit 0
