# Shell binding for the claude-side Romy fleet console.
# Source from ~/.zshrc:  source "$HOME/.claude/fleet/romy.zsh"

unalias romy 2>/dev/null || true

romy() {
  "${CLAUDE_FLEET_HOME:-$HOME/.claude/fleet}/bin/romy" "$@"
}
