# Shell binding for the claude-side Pien fleet console.
# Source from ~/.zshrc:  source "$HOME/.claude/fleet/pien.zsh"

unalias pien 2>/dev/null || true

pien() {
  "${CLAUDE_FLEET_HOME:-$HOME/.claude/fleet}/bin/pien" "$@"
}
