#!/usr/bin/env bash
set -euo pipefail

# Source common library
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [[ -f "$script_dir/tmux-quota-common.sh" ]]; then
    # shellcheck source=tmux-quota-common.sh
    source "$script_dir/tmux-quota-common.sh"
elif [[ -f "$script_dir/../lib/tmux-quota-common.sh" ]]; then
    # shellcheck source=../lib/tmux-quota-common.sh
    source "$script_dir/../lib/tmux-quota-common.sh"
else
    printf '#[fg=colour250]common lib unavailable#[default]\n'
    exit 1
fi

usage() {
    cat <<'EOF'
Usage:
  tmux-configure-quota-visibility.sh \
    --show-codex yes|no \
    --codex-auth-source codex-cli|opencode \
    --show-zai yes|no \
    [--show-copilot yes|no] \
    [--show-alibaba yes|no] \
    [--tmux-conf ~/.tmux.conf] \
    [--apply-services yes|no] \
    [--source-tmux yes|no]

Notes:
  - --codex-auth-source is required when --show-codex=yes.
  - When --show-codex=no, --codex-auth-source is ignored.
EOF
}

normalize_bool() {
    local raw="${1:-}"
    raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
    case "$raw" in
        y|yes|1|true|on) printf 'yes' ;;
        n|no|0|false|off) printf 'no' ;;
        *) return 1 ;;
    esac
}

normalize_auth_source() {
    local raw="${1:-}"
    raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
    case "$raw" in
        codex|codex-cli|codex_cli) printf 'codex-cli' ;;
        opencode|open-code|open_code) printf 'opencode' ;;
        *) return 1 ;;
    esac
}

show_codex=''
show_zai=''
show_copilot='no'
show_alibaba='no'
codex_auth_source=''

# Get configurable paths
home_dir="$(resolve_home_dir)"
bin_dir="$(get_bin_dir)"
tmux_conf_default="$(get_tmux_conf)"
tmux_conf="${TMUX_CONF_OVERRIDE:-$tmux_conf_default}"
apply_services='yes'
source_tmux='yes'

while [[ $# -gt 0 ]]; do
    case "$1" in
        --show-codex)
            show_codex="$(normalize_bool "${2:-}")" || {
                printf 'Invalid --show-codex value: %s\n' "${2:-}" >&2
                usage >&2
                exit 1
            }
            shift 2
            ;;
        --codex-auth-source)
            codex_auth_source="$(normalize_auth_source "${2:-}")" || {
                printf 'Invalid --codex-auth-source value: %s\n' "${2:-}" >&2
                usage >&2
                exit 1
            }
            shift 2
            ;;
        --show-zai)
            show_zai="$(normalize_bool "${2:-}")" || {
                printf 'Invalid --show-zai value: %s\n' "${2:-}" >&2
                usage >&2
                exit 1
            }
            shift 2
            ;;
        --show-copilot)
            show_copilot="$(normalize_bool "${2:-}")" || {
                printf 'Invalid --show-copilot value: %s\n' "${2:-}" >&2
                usage >&2
                exit 1
            }
            shift 2
            ;;
        --show-alibaba)
            show_alibaba="$(normalize_bool "${2:-}")" || {
                printf 'Invalid --show-alibaba value: %s\n' "${2:-}" >&2
                usage >&2
                exit 1
            }
            shift 2
            ;;
        --tmux-conf)
            tmux_conf="${2:-}"
            shift 2
            ;;
        --apply-services)
            apply_services="$(normalize_bool "${2:-}")" || {
                printf 'Invalid --apply-services value: %s\n' "${2:-}" >&2
                usage >&2
                exit 1
            }
            shift 2
            ;;
        --source-tmux)
            source_tmux="$(normalize_bool "${2:-}")" || {
                printf 'Invalid --source-tmux value: %s\n' "${2:-}" >&2
                usage >&2
                exit 1
            }
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ -z "$show_codex" || -z "$show_zai" ]]; then
    printf 'Missing required arguments.\n' >&2
    usage >&2
    exit 1
fi

if [[ "$show_codex" == 'yes' && -z "$codex_auth_source" ]]; then
    printf '--codex-auth-source is required when --show-codex=yes\n' >&2
    usage >&2
    exit 1
fi

if [[ ! -f "$tmux_conf" ]]; then
    printf 'tmux config file not found: %s\n' "$tmux_conf" >&2
    exit 1
fi

# Build segments with configurable bin_dir
left_segment="#[align=left]#[fg=colour252]#(${bin_dir}/tmux-path-right.sh \"#{pane_current_path}\" 52)#[default] #(${bin_dir}/tmux-git-segment.sh \"#{pane_current_path}\")"
codex_segment="#[bg=colour52,fg=colour231,bold] CODEX #[default] #(${bin_dir}/tmux-codex-quota.sh)"
zai_segment="#[bg=colour22,fg=colour231,bold] Z.AI #[default] #(${bin_dir}/tmux-zai-quota.sh)"
copilot_segment="#[bg=colour17,fg=colour231,bold] COPILOT #[default] #(${bin_dir}/tmux-copilot-quota.sh)"
alibaba_segment="#[bg=colour88,fg=colour231,bold] ALIBABA #[default] #(${bin_dir}/tmux-alibaba-quota.sh)"
separator=' #[fg=colour245]│#[default] '

right_segment=''
if [[ "$show_codex" == 'yes' ]]; then
    right_segment="$codex_segment"
fi
if [[ "$show_zai" == 'yes' ]]; then
    if [[ -n "$right_segment" ]]; then
        right_segment+="$separator"
    fi
    right_segment+="$zai_segment"
fi
if [[ "$show_copilot" == 'yes' ]]; then
    if [[ -n "$right_segment" ]]; then
        right_segment+="$separator"
    fi
    right_segment+="$copilot_segment"
fi
if [[ "$show_alibaba" == 'yes' ]]; then
    if [[ -n "$right_segment" ]]; then
        right_segment+="$separator"
    fi
    right_segment+="$alibaba_segment"
fi
if [[ -z "$right_segment" ]]; then
    right_segment='#[fg=colour244] quota off #[default]'
fi

status_line="${left_segment}#[align=right]${right_segment}"

tmp_file="$(mktemp "${tmux_conf}.tmp.XXXXXX")"
status_replaced=0

while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
        "set -g status-format[0]"*)
            printf "set -g status-format[0] '%s'\n" "$status_line" >>"$tmp_file"
            status_replaced=1
            continue
            ;;
        "run-shell -b '${bin_dir}/tmux-load-opencode-key.sh'"|\
        "set-hook -g client-attached 'run-shell -b ${bin_dir}/tmux-load-opencode-key.sh'"|\
        "# Load Z.AI key from opencode auth.json on attach"|\
        "set-environment -g CODEX_AUTH_FILE "*|\
        "run-shell -b '${bin_dir}/tmux-load-copilot-key.sh'"|\
        "set-hook -g client-attached 'run-shell -b ${bin_dir}/tmux-load-copilot-key.sh'"|\
        "# Load Copilot key on attach"|\
        "set-environment -g COPILOT_AUTH_FILE "*)
            continue
            ;;
    esac
    printf '%s\n' "$line" >>"$tmp_file"
done <"$tmux_conf"

if (( status_replaced == 0 )); then
    printf "set -g status-format[0] '%s'\n" "$status_line" >>"$tmp_file"
fi

if [[ "$show_zai" == 'yes' ]]; then
    printf '# Load Z.AI key from opencode auth.json on attach\n' >>"$tmp_file"
    printf "run-shell -b '%s/tmux-load-opencode-key.sh'\n" >>"$tmp_file"
    printf "set-hook -g client-attached 'run-shell -b %s/tmux-load-opencode-key.sh'\n" >>"$tmp_file"
fi

if [[ "$show_codex" == 'yes' ]]; then
    codex_auth_file="$home_dir/.local/share/opencode/auth.json"
    if [[ "$codex_auth_source" == 'codex-cli' ]]; then
        codex_auth_file="$home_dir/.codex/auth.json"
    fi
    printf 'set-environment -g CODEX_AUTH_FILE %s\n' "$codex_auth_file" >>"$tmp_file"
fi

# Backup existing config before overwriting
if [[ -f "$tmux_conf" ]]; then
    cp "$tmux_conf" "${tmux_conf}.bak.$(date +%Y%m%d%H%M%S)"
fi

mv "$tmp_file" "$tmux_conf"

if [[ "$apply_services" == 'yes' ]] && command -v systemctl >/dev/null 2>&1; then
    if [[ "$show_zai" == 'yes' ]]; then
        systemctl enable --now tmux-zai-key-bootstrap.service >/dev/null 2>&1 || true
    else
        systemctl disable --now tmux-zai-key-bootstrap.service >/dev/null 2>&1 || true
    fi

    if [[ "$show_codex" == 'no' ]]; then
        systemctl disable --now codex-quota-poll.timer >/dev/null 2>&1 || true
    fi
fi

if [[ "$source_tmux" == 'yes' ]] && command -v tmux >/dev/null 2>&1; then
    tmux source-file "$tmux_conf" >/dev/null 2>&1 || true
fi

printf 'Configured quota visibility: codex=%s, zai=%s, copilot=%s, alibaba=%s\n' "$show_codex" "$show_zai" "$show_copilot" "$show_alibaba"
if [[ "$show_codex" == 'yes' ]]; then
    printf 'Codex auth source: %s\n' "$codex_auth_source"
fi
printf 'Updated tmux config: %s\n' "$tmux_conf"
