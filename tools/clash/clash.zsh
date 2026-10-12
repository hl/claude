#!/usr/bin/env zsh
# clash - Claude at your shell prompt: forge-style ":" commands for Claude Code (modelled on tailcallhq/forgecode's shell-plugin).
#
# Hooks Enter, so a line starting with ":" is never parsed by the shell: no quoting needed,
# and the : builtin still works in scripts. Each shell keeps one Claude session across messages.
#
#   : <message>          send to the current session
#   :<agent> [message]   switch agent (e.g. :claudette), optionally send
#   :new|n [message]     start a fresh session, optionally send
#   :retry|r             resend the last message
#   :model|m [name]      pick or set model (haiku, sonnet, opus, fable, or a full model id), saved for new shells
#   :effort|e [level]    pick or set effort (low, medium, high, xhigh, max), saved for new shells
#   :agent|a [name|-]    pick or set agent, "-" clears it
#   :open|o              continue this session in the full Claude Code TUI
#   :info|i              show session, model, effort, agent
#   :help|h              show this list
#
# The right prompt shows model · effort (and agent): dim when idle, highlighted once this shell has a live session.

typeset -g _CC_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/clash/settings.zsh"
typeset -g _CC_MODEL="haiku"
typeset -g _CC_EFFORT="medium"
[[ -f "$_CC_CONFIG" ]] && source "$_CC_CONFIG"
typeset -g _CC_AGENT=""
typeset -g _CC_SESSION=""
typeset -g _CC_STARTED=0
typeset -g _CC_LAST=""
typeset -ga _CC_AGENTS_CACHE
typeset -g _CC_PLUGIN_FILE="${(%):-%x}"

# "value<TAB>description" lists shared by the pickers and Tab completion
typeset -ga _CC_COMMANDS=(
  $'new\tstart a fresh session'
  $'retry\tresend the last message'
  $'model\tpick or set model'
  $'effort\tpick or set effort'
  $'agent\tpick or set agent'
  $'open\tcontinue in the full Claude Code TUI'
  $'info\tshow session, model, effort, agent'
  $'help\tlist commands'
)
typeset -ga _CC_MODELS=(
  $'haiku\tClaude Haiku 5.5'
  $'sonnet\tClaude Sonnet 5.5'
  $'opus\tClaude Opus 5.5'
  $'fable\tClaude Fable 5.1'
)
typeset -ga _CC_EFFORTS=(low medium high xhigh max)

_cc_log() { print -P -- "%F{${1}}${2}%f" }

_cc_save_config() {
  mkdir -p "${_CC_CONFIG:h}"
  print -r -- "_CC_MODEL=${(q)_CC_MODEL}"$'\n'"_CC_EFFORT=${(q)_CC_EFFORT}" >| "$_CC_CONFIG"
}

_cc_new_session() {
  _CC_SESSION="${(L)$(uuidgen)}"
  _CC_STARTED=0
}

# Claude prints the available agents when --agent is unknown; it fails before any model call.
_cc_agents() {
  if (( ! ${#_CC_AGENTS_CACHE} )); then
    _CC_AGENTS_CACHE=(${(s:,:)${$(claude -p --agent __cc_list__ x 2>&1 | sed -n 's/.*Available agents: //p' | tr -d ' ')}})
  fi
  print -l -- $_CC_AGENTS_CACHE
}

_cc_is_agent() { (( ${${(f)"$(_cc_agents)"}[(Ie)$1]} )) }

# Shared flags for both one-shot and TUI runs
_cc_flags() {
  reply=(--model "$_CC_MODEL" --effort "$_CC_EFFORT" --dangerously-skip-permissions)
  [[ -n "$_CC_AGENT" ]] && reply+=(--agent "$_CC_AGENT")
  if (( _CC_STARTED )); then
    reply+=(--resume "$_CC_SESSION")
  else
    reply+=(--session-id "$_CC_SESSION")
  fi
}

_cc_send() {
  local msg="$1"
  [[ -z "$_CC_SESSION" ]] && _cc_new_session
  _CC_LAST="$msg"
  local -a reply; _cc_flags

  # Stream so long agentic runs show progress: tool calls dimmed, assistant text as it arrives
  claude -p "${reply[@]}" --output-format stream-json --verbose -- "$msg" </dev/null 2>/dev/tty \
    | jq -rj --unbuffered '
        select(.parent_tool_use_id == null) |
        if .type == "assistant" then
          .message.content[] |
          if .type == "text" then .text + "\n"
          elif .type == "tool_use" then
            "\u001b[2m⏺ \(.name) \((.input.command // .input.file_path // .input.pattern // .input.url // .input.description // "") | tostring | gsub("\n"; " ") | .[0:100])\u001b[0m\n"
          else empty end
        elif .type == "result" and .is_error then "\u001b[31m\(.result // .subtype)\u001b[0m\n"
        else empty end' >/dev/tty
  local claude_status=${pipestatus[1]}
  (( claude_status == 0 )) && _CC_STARTED=1
  return $claude_status
}

# fzf picker drawn inline under the prompt, like forge's :model. Sets REPLY to the first column of the choice.
# Usage: _cc_pick <label> <current or ""> <"value<TAB>description">...
_cc_pick() {
  local label="$1" current="$2"; shift 2
  local choice
  choice=$(print -l -- "$@" | fzf --height=~40% --reverse --no-multi --delimiter=$'\t' \
    --prompt="$label> " ${current:+--header="current: $current"}) || return 1
  REPLY="${choice%%$'\t'*}"
}

_cc_info() {
  _cc_log 8 "session ${_CC_SESSION:-<none yet>}$( (( _CC_STARTED )) || [[ -z $_CC_SESSION ]] || print ' (not started)')"
  _cc_log 8 "model $_CC_MODEL · effort $_CC_EFFORT · agent ${_CC_AGENT:-default}"
}

_cc_help() { sed -n '/^#   :/s/^#   //p' "$_CC_PLUGIN_FILE" }

_cc_dispatch() {
  local action="$1" input="$2"
  case "$action" in
    "")
      _cc_send "$input" ;;
    new|n)
      _cc_new_session
      _cc_log 8 "new session $_CC_SESSION"
      [[ -n "$input" ]] && _cc_send "$input" ;;
    retry|r)
      if [[ -z "$_CC_LAST" ]]; then _cc_log red "nothing to retry"; return 1; fi
      _cc_send "$_CC_LAST" ;;
    model|m)
      if [[ -z "$input" ]]; then
        _cc_pick model "$_CC_MODEL" $_CC_MODELS || return 0
        input="$REPLY"
      fi
      _CC_MODEL="$input"
      _cc_save_config
      _cc_log 8 "model $_CC_MODEL" ;;
    effort|e)
      if [[ -z "$input" ]]; then
        _cc_pick effort "$_CC_EFFORT" $_CC_EFFORTS || return 0
        input="$REPLY"
      fi
      if (( ! ${_CC_EFFORTS[(Ie)$input]} )); then
        _cc_log red "effort must be low, medium, high, xhigh or max"; return 1
      fi
      _CC_EFFORT="$input"
      _cc_save_config
      _cc_log 8 "effort $_CC_EFFORT" ;;
    agent|a)
      if [[ -z "$input" ]]; then
        _cc_pick agent "${_CC_AGENT:-default}" $'-\tdefault (no agent)' ${(f)"$(_cc_agents)"} || return 0
        input="$REPLY"
      fi
      if [[ "$input" == "-" ]]; then
        _CC_AGENT=""
      else
        if ! _cc_is_agent "$input"; then
          _cc_log red "agent '$input' not found. Available: ${(j:, :)${(f)"$(_cc_agents)"}}"; return 1
        fi
        _CC_AGENT="$input"
      fi
      _cc_log 8 "agent ${_CC_AGENT:-default}" ;;
    open|o)
      [[ -z "$_CC_SESSION" ]] && _cc_new_session
      local -a reply; _cc_flags
      claude "${reply[@]}" </dev/tty >/dev/tty 2>&1
      (( $? == 0 )) && _CC_STARTED=1 ;;
    info|i)
      _cc_info ;;
    help|h)
      _cc_help ;;
    *)
      if ! _cc_is_agent "$action"; then
        _cc_log red "':$action' is not a command or agent. Try :help"; return 1
      fi
      _CC_AGENT="$action"
      if [[ -n "$input" ]]; then
        _cc_send "$input"
      else
        _cc_log 8 "agent $_CC_AGENT"
      fi ;;
  esac
}

_cc_accept_line() {
  local action input
  if [[ "$BUFFER" =~ "^:([a-zA-Z][a-zA-Z0-9_-]*)( (.*))?$" ]]; then
    action="${match[1]}"
    input="${match[3]}"
  elif [[ "$BUFFER" =~ "^: (.+)$" ]]; then
    action=""
    input="${match[1]}"
  else
    zle accept-line
    return
  fi

  print -s -- "$BUFFER"
  CURSOR=${#BUFFER}
  zle redisplay
  print
  _cc_dispatch "$action" "$input"
  local action_status=$?

  # Same order as forge's _forge_reset: pad for multi-line buffers so ZLE clears blank lines
  # rather than our output, then clear the buffer and invalidate the display before redrawing
  local pad="${BUFFERLINES:-1}" _i
  for ((_i=1; _i<pad; _i++)); do print; done
  BUFFER=""
  CURSOR=0
  zle -I
  zle reset-prompt
  return $action_status
}

# Tab: complete ":mo" -> ":model ", ":model so" -> ":model sonnet ". One match fills in, several open
# a picker, none falls back to fuzzy matching. Any other line goes to the previous Tab widget (fzf-completion).
_cc_complete_word() {
  local keep="$1" partial="$2" label="$3"; shift 3
  local -a matches=(${(M)@:#${(b)partial}*})
  (( ${#matches} )) || matches=(${(f)"$(print -l -- "$@" | fzf --filter="$partial" --delimiter=$'\t' --nth=1)"})
  if (( ${#matches} == 0 )); then
    zle -M "no match for '$partial'"; return 1
  elif (( ${#matches} == 1 )); then
    REPLY="${matches[1]%%$'\t'*}"
  else
    _cc_pick "$label" "" $matches || { zle reset-prompt; return 1 }
    zle reset-prompt
  fi
  BUFFER="$keep$REPLY "
  CURSOR=${#BUFFER}
}

_cc_complete() {
  if (( CURSOR == ${#BUFFER} )) && [[ "$BUFFER" =~ "^:([a-zA-Z-]*)$" ]]; then
    local -a agents=(${^${(f)"$(_cc_agents)"}}$'\tagent')
    _cc_complete_word ":" "${match[1]}" command $_CC_COMMANDS $agents
  elif (( CURSOR == ${#BUFFER} )) && [[ "$BUFFER" =~ "^:(model|m|effort|e|agent|a) ([^ ]*)$" ]]; then
    local cmd="${match[1]}" partial="${match[2]}"
    case "$cmd" in
      model|m)  _cc_complete_word ":$cmd " "$partial" model $_CC_MODELS ;;
      effort|e) _cc_complete_word ":$cmd " "$partial" effort $_CC_EFFORTS ;;
      agent|a)  _cc_complete_word ":$cmd " "$partial" agent $'-\tdefault (no agent)' ${(f)"$(_cc_agents)"} ;;
    esac
  else
    zle "$_CC_TAB_FALLBACK"
  fi
}

# Remember what Tab did before (guarding against re-sourcing this file)
if [[ "$(bindkey '^I')" != *_cc_complete* ]]; then
  typeset -g _CC_TAB_FALLBACK="${${(z)$(bindkey '^I')}[2]:-expand-or-complete}"
fi

zle -N _cc_accept_line
zle -N _cc_complete
bindkey '^M' _cc_accept_line
bindkey '^J' _cc_accept_line
bindkey '^I' _cc_complete

# Right prompt, like forge's rprompt: dim until this shell's session has started, then highlighted
setopt PROMPT_SUBST
_cc_prompt_info() {
  local label="${_CC_AGENT:+$_CC_AGENT · }$_CC_MODEL · $_CC_EFFORT"
  if (( _CC_STARTED )); then
    print -r -- "%F{208}● $label%f"
  else
    print -r -- "%F{8}○ $label%f"
  fi
}
if [[ -z "$_CC_THEME_LOADED" ]]; then
  RPROMPT='$(_cc_prompt_info)'"${RPROMPT:+ ${RPROMPT}}"
  typeset -g _CC_THEME_LOADED=1
fi
