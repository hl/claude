#!/usr/bin/env bash
# Claude Code status line — technical, flat, all-grey
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
input=$(cat)

cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
cwd_name=$(basename "$cwd")

# Project = main repo name (stable across worktrees, from the shared .git);
# cwd = the worktree/subdir you're actually in. Outside a repo, project = cwd.
common=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
if [ -n "$common" ]; then
  project=$(basename "$(dirname "$common")")
else
  project="$cwd_name"
fi

# Git branch from worktree info, falling back to git command
branch=$(echo "$input" | jq -r '.worktree.branch // empty')
if [ -z "$branch" ]; then
  branch=$(git -C "$cwd" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null)
fi

# Model (display name + working model id)
model=$(echo "$input" | jq -r '.model.display_name // ""')
model_id=$(echo "$input" | jq -r '.model.id // empty')

# Context remaining
remaining=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')

# Technical, flat, all-grey: dir: X | git: Y | mod: Z | ctx: N%
mod=${model_id:-$model}

ctx=""
if [ -n "$remaining" ]; then
  used_int=$(printf '%.0f' "$(echo "$remaining" | awk '{print 100 - $1}')")
  filled=$(( (used_int + 5) / 10 ))   # nearest 10%, 0-10 segments
  [ "$filled" -gt 10 ] && filled=10
  [ "$filled" -lt 0 ] && filled=0
  empty=$(( 10 - filled ))
  fbar=""; ebar=""
  [ "$filled" -gt 0 ] && fbar=$(printf '█%.0s' $(seq 1 "$filled"))
  [ "$empty" -gt 0 ]  && ebar=$(printf '░%.0s' $(seq 1 "$empty"))
  ctx="${fbar}${ebar} $used_int%"
fi

# Colors: gray keys/separators, slightly lighter values
K=$'\033[38;5;243m'   # gray for keys + separators
V=$'\033[38;5;250m'   # slightly lighter for values
R=$'\033[0m'
sep="${K} | "

out="${K}dir: ${V}${project}"
[ -n "$cwd_name" ] && [ "$cwd_name" != "$project" ] && out="${out}${sep}${K}cwd: ${V}${cwd_name}"
[ -n "$branch" ]   && out="${out}${sep}${K}git: ${V}${branch}"
[ -n "$mod" ]      && out="${out}${sep}${K}mod: ${V}${mod}"
[ -n "$ctx" ]      && out="${out}${sep}${K}ctx: ${V}${ctx}"

printf '%s%s' "$out" "$R"
