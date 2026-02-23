#!/usr/bin/env bash
# Claude Code statusLine script - visually distinct from normal terminal prompt

input=$(cat)
cwd=$(echo "$input" | jq -r '.workspace.current_dir')
dir=$(basename "$cwd")
model=$(echo "$input" | jq -r '.model.display_name // "Claude"')
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

# ANSI color codes
BOLD="\033[1m"
MAGENTA="\033[35m"
BRIGHT_MAGENTA="\033[95m"
CYAN="\033[36m"
YELLOW="\033[33m"
RED="\033[31m"
GREEN="\033[32m"
BLUE="\033[34m"
DIM="\033[2m"
RESET="\033[0m"

# ── Model name ────────────────────────────────────────────────────────────────
model_part="${BOLD}${BRIGHT_MAGENTA}${model}${RESET}"

# ── Current directory ─────────────────────────────────────────────────────────
dir_part="${BOLD}${CYAN}${dir}${RESET}"

# ── Context usage bar ─────────────────────────────────────────────────────────
ctx_part=""
if [ -n "$used_pct" ]; then
  used_int=$(printf "%.0f" "$used_pct")
  if [ "$used_int" -ge 80 ]; then
    ctx_color="${RED}"
  elif [ "$used_int" -ge 50 ]; then
    ctx_color="${YELLOW}"
  else
    ctx_color="${GREEN}"
  fi
  ctx_part=" ${DIM}ctx:${RESET}${ctx_color}${used_int}%${RESET}"
fi

# ── Git info ──────────────────────────────────────────────────────────────────
git_part=""
if git_branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null); then
  if git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null | grep -q .; then
    dirty=" ${YELLOW}✗${RESET}"
  else
    dirty=""
  fi
  git_part=" ${DIM}on${RESET} ${BOLD}${MAGENTA}${git_branch}${RESET}${dirty}"
fi

printf "${model_part}  ${dir_part}${git_part}${ctx_part}\n"
