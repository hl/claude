# ~/.claude

Personal Claude Code configuration.

| Path | What it is |
|---|---|
| `settings.json` | Hooks, permissions, statusline, model |
| `agents/` | Personal subagents (`claudette` orchestrator) |
| `hooks/` | Formatting on edit, silent-bash wrapper, herdr agent-state reporting, Jev routing and compaction (`hooks/jev/`) |
| `statusline-command.sh` | Statusline renderer |
| `tools/beads-status/` | Small TUI for `bd` status (source only; `go build -o ~/.claude/bin/beads-status .`) |
| `tools/clash/` | zsh plugin: `: <message>` at the prompt talks to Claude Code, forgecode-style (`source` it from `~/.zshrc`; `:help` lists commands) |

## Conventions

There is deliberately no global `CLAUDE.md`. The harness defaults already cover autonomy and
delegation, and a file here is read by every runner (it sits in an ancestor `.claude/` and
loads regardless of `CLAUDE_CONFIG_DIR`). If one is ever added, keep it provider-neutral: no
model names, no config-dir paths. Per-runner specifics live in that runner's own config dir.

## Jev hooks

`hooks/jev/` uses Jev, TypeSafe AI's decision model, for two jobs.

- **Model choice.** It picks haiku, sonnet or opus for each subagent. `route.sh` encodes Claudette's tier table, and a PreToolUse hook on `Agent` fills in the model when a call has none.
- **Compaction.** It keeps important facts across compaction. A PreCompact hook extracts candidate facts and Jev ranks them. Jev then checks which ones the summary kept, and a SessionStart `compact` hook re-injects the ones it dropped.

To enable the hooks, set `TYPESAFE_API_KEY` in the environment or in `~/.zshenv`. To disable them, set `JEV_DISABLED=1`. They fail open: on any error, compaction and Agent calls go ahead untouched. Logs go to `~/.claude/jev/log/`. On Claude Code 2.1.302 the observed order is PreCompact, then the compaction agent's SubagentStop, then SessionStart(compact), then PostCompact. `hooks/jev/README.md` documents the knobs, limits and tests (`hooks/jev/test/run.sh`).
