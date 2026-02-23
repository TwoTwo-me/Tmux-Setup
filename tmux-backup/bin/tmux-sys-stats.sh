#!/usr/bin/env bash
set -euo pipefail

read_cpu() {
    local cpu user nice system idle iowait irq softirq steal guest guest_nice
    read -r cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
    local idle_all total
    idle_all=$((idle + iowait))
    total=$((user + nice + system + idle + iowait + irq + softirq + steal))
    printf '%s %s\n' "$idle_all" "$total"
}

read -r idle1 total1 <<<"$(read_cpu)"
sleep 0.2
read -r idle2 total2 <<<"$(read_cpu)"

cpu_pct=0
total_delta=$((total2 - total1))
idle_delta=$((idle2 - idle1))
if (( total_delta > 0 )); then
    cpu_pct=$(((100 * (total_delta - idle_delta)) / total_delta))
fi

mem_total_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
mem_avail_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
mem_pct=0
if [[ -n "$mem_total_kb" && -n "$mem_avail_kb" ]] && (( mem_total_kb > 0 )); then
    mem_pct=$((((mem_total_kb - mem_avail_kb) * 100) / mem_total_kb))
fi

printf 'CPU %s%% RAM %s%%\n' "$cpu_pct" "$mem_pct"
