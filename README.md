# ~/.claude

Personal Claude Code configuration.

| Path | What it is |
|---|---|
| `settings.json` | Hooks, permissions, statusline, model |
| `agents/` | Personal subagents (`claudette` orchestrator) |
| `hooks/` | Formatting on edit, silent-bash wrapper, herdr agent-state reporting |
| `statusline-command.sh` | Statusline renderer |
| `tools/beads-status/` | Small TUI for `bd` status (source only; `go build -o ~/.claude/bin/beads-status .`) |
| `tools/clash/` | zsh plugin: `: <message>` at the prompt talks to Claude Code, forgecode-style (`source` it from `~/.zshrc`; `:help` lists commands) |

## Conventions

There is deliberately no global `CLAUDE.md`. The harness defaults already cover autonomy and
delegation, and a file here is read by every runner (it sits in an ancestor `.claude/` and
loads regardless of `CLAUDE_CONFIG_DIR`). If one is ever added, keep it provider-neutral: no
model names, no config-dir paths. Per-runner specifics live in that runner's own config dir.
