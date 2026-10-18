# ~/.claude

Personal Claude Code configuration.

| Path | What it is |
|---|---|
| `settings.json` | Hooks, permissions, statusline, model |
| `agents/` | Personal subagents (`claudette` orchestrator) |
| `hooks/` | Formatting on edit, silent-bash wrapper, herdr agent-state reporting, Jev routing, session ledger and compaction (`hooks/jev/`) |
| `statusline-command.sh` | Statusline renderer |
| `tools/beads-status/` | Small TUI for `bd` status (source only; `go build -o ~/.claude/bin/beads-status .`) |
| `tools/clash/` | zsh plugin: `: <message>` at the prompt talks to Claude Code, forgecode-style (`source` it from `~/.zshrc`; `:help` lists commands) |

## Conventions

There is deliberately no global `CLAUDE.md`. The harness defaults already cover autonomy and
delegation, and a file here is read by every runner (it sits in an ancestor `.claude/` and
loads regardless of `CLAUDE_CONFIG_DIR`). If one is ever added, keep it provider-neutral: no
model names, no config-dir paths. Per-runner specifics live in that runner's own config dir.

## Jev hooks

`hooks/jev/` uses Jev, TypeSafe AI's decision model, to stop long sessions wasting work: retries after a too-light model, research done twice, and state lost at compaction.

- **Model choice.** `route.sh` picks haiku, sonnet or opus for a brief, plus a reviewer model and whether to investigate first. It routes to opus unless Jev is confident a lower tier suffices; the thresholds were tuned on 451 real Agent calls from local transcripts, labelled blind (0 opus tasks under-routed, 35% over-routed). Claudette calls it with `--context`; a PreToolUse hook on `Agent` raises an explicit haiku or sonnet when Jev is sure it falls short.
- **Long sessions.** A Stop hook keeps a per-session ledger of important facts, turn by turn, and marks the ones later corrected. At compaction the hooks re-inject the live `.orchestrator.md` sections, the index of saved artifacts and the facts the summary dropped. `artifact.sh` saves deliverables to disk, and every subagent result over 2,000 characters is saved automatically.

To enable the hooks, set `TYPESAFE_API_KEY` in the environment or in `~/.zshenv`. To disable them, set `JEV_DISABLED=1` (`JEV_LEDGER=0` and `JEV_ROUTE_MODE=off` switch off single parts).

**What leaves the machine:** each turn's new facts and up to 20k characters of that turn's text, the compaction summary, and each Agent call's prompt go to `api.typesafe.ai`, all redacted first (keys, tokens, Authorization headers, secret-named variables, emails, IPs; paths and hostnames are kept). Ledger, artifacts and logs stay in `~/.claude/jev/`. Every hook fails open. `hooks/jev/README.md` documents the design, the knobs, the observed hook payloads, the limits and the tests (`hooks/jev/test/run.sh`).
