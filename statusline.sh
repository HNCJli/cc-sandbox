#!/usr/bin/env bash
# Claude Code statusline (bash port of Windows lm-statusline-script/statusline.ps1)
# stdin: Claude Code JSON payload
# stdout: two-line ANSI-colored status
#   line 1: 🤖 [model] 📁 dir | 🌿 branch
#   line 2: 📊 [=bar-] N% | 💰 $0.0000 | ⏱️ Xd Yh Zm Ws
set -u

ESC=$'\033'
CYAN="$ESC[36m"
YELLOW="$ESC[33m"
GREEN="$ESC[32m"
RED="$ESC[31m"
ORANGE="$ESC[38;5;208m"
LIGHT_GREEN="$ESC[38;5;71m"
RESET="$ESC[0m"

# Repeat a character N times. Handles n<=0 without brace-explosion issues.
repeat_char() {
    local c="$1" n="$2"
    [ "$n" -gt 0 ] 2>/dev/null || return
    printf "%${n}s" '' | tr ' ' "$c"
}

# Robust numeric extraction: try the path chain, coerce strings via tonumber, default 0 on any error.
jq_num() {
    local expr="$1"
    local v
    v=$(printf '%s' "$data" | jq -r "try ($expr | if type == \"string\" then tonumber else . end) catch 0" 2>/dev/null)
    # Guard against empty/null/jq-failure
    case "$v" in
        ''|'null') v=0 ;;
    esac
    printf '%s' "$v"
}

# --- read & validate stdin ---
json="$(cat)"
if ! data=$(printf '%s' "$json" | jq -e . 2>/dev/null); then
    printf '%s[JSON parse failed]%s\n' "$RED" "$RESET" >&2
    exit 1
fi

# --- 1. model ---
model_name=$(printf '%s' "$data" | jq -r '.model.display_name // "Unknown Model"')
model_display="🤖 ${CYAN}[${model_name}]${RESET}"

# --- 2. directory ---
dir_name=$(printf '%s' "$data" | jq -r '.workspace.current_dir // ""')
if [ -n "$dir_name" ]; then
    dir_display="📁 $(basename "$dir_name")"
else
    dir_display="📁 ${YELLOW}Unknown Directory${RESET}"
fi

# --- 3. git branch (need workspace dir to query) ---
if [ -n "$dir_name" ] && branch=$(git -C "$dir_name" branch --show-current 2>/dev/null) && [ -n "$branch" ]; then
    git_part=" | 🌿 $branch"
else
    git_part=" | ${YELLOW}未检测到 Git 分支${RESET}"
fi

# --- 4. progress bar (10 chars, color band by used%) ---
used_pct=$(jq_num '.context_window.used_percentage // 0 | floor')
if   [ "$used_pct" -le 30 ]; then bar_color="$LIGHT_GREEN"
elif [ "$used_pct" -le 60 ]; then bar_color="$GREEN"
elif [ "$used_pct" -le 75 ]; then bar_color="$YELLOW"
elif [ "$used_pct" -le 89 ]; then bar_color="$ORANGE"
else                              bar_color="$RED"
fi
filled=$((used_pct / 10))
[ "$filled" -gt 10 ] && filled=10
[ "$filled" -lt 0 ]  && filled=0
empty=$((10 - filled))
bar="$(repeat_char '=' "$filled")$(repeat_char '-' "$empty")"
progress_display="📊 ${bar_color}[${bar}]${RESET} ${used_pct}%"

# --- 5. cost (multi-path fallback chain, like the PS1) ---
cost=$(jq_num '(.cost.total_cost_usd // .cost.totalCost // .cost.cost_usd // .total_cost_usd // .cost // 0)')
cost_formatted=$(printf '%.4f' "$cost" 2>/dev/null) || cost_formatted="0.0000"
cost_display="${YELLOW}💰 \$${cost_formatted}${RESET}"

# --- 6. duration (ms → Xd Yh Zm Ws) ---
duration_ms=$(jq_num '.cost.total_duration_ms // 0')
total_seconds=$((duration_ms / 1000))
days=$((total_seconds / 86400))
hours=$(( (total_seconds % 86400) / 3600 ))
minutes=$(( (total_seconds % 3600) / 60 ))
seconds=$(( total_seconds % 60 ))
time_parts=()
[ "$days"    -gt 0 ] && time_parts+=("${days}d")
{ [ "$hours"   -gt 0 ] || [ "$days" -gt 0 ]; } && time_parts+=("${hours}h")
{ [ "$minutes" -gt 0 ] || [ "$hours" -gt 0 ] || [ "$days" -gt 0 ]; } && time_parts+=("${minutes}m")
time_parts+=("${seconds}s")
time_display="⏱️ $(IFS=' '; echo "${time_parts[*]}")"

# --- emit two lines ---
printf '%s %s%s\n' "$model_display" "$dir_display" "$git_part"
printf '%s | %s | %s\n' "$progress_display" "$cost_display" "$time_display"
