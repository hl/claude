# ~/.claude

Personal Claude Code configuration.

| Path | What it is |
|---|---|
| `settings.json` | Hooks, permissions, statusline, model |
| `agents/` | Personal subagents (`claudette` orchestrator) |
| `hooks/` | Formatting on edit, silent-bash wrapper, herdr agent-state reporting, Jev model routing, compaction help and artifacts (`hooks/jev/`) |
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

- **Model choice.** `route.sh` picks the model for a brief, plus a reviewer model, starting from opus:
  - haiku for `kind` poll, fetch or lookup, or when Jev is sure the task is mechanical and safe;
  - sonnet only when Jev is sure it is routine and low-risk;
  - opus otherwise.

  On 451 real Agent tasks labelled blind, no opus task was routed lower, and about two thirds of the tasks ran a tier above their label. Claudette calls `route.sh` and puts its id in the brief. In Claudette sessions, a PreToolUse hook on `Agent` raises an explicit haiku or sonnet that carries no route id when Jev would pick higher. A PostToolUse hook tells the parent which model ran.
- **Compaction.** The hooks re-inject the live `.orchestrator.md` sections and the index of saved artifacts after every compaction, in any session. In Claudette sessions they also re-inject the facts the summary dropped. Every subagent result over 2,000 characters is saved to disk, and `artifact.sh` saves deliverables by hand.

Jev is called only in Claudette sessions (an `.orchestrator.md` at the project root):

- once per `route.sh` call;
- once per Agent spawn that is an explicit haiku or sonnet with no route id;
- at most twice per compaction.

A routine turn sends nothing. `JEV_SCOPE=all` extends this to every session, and `JEV_DISABLED=1` switches everything off. To enable the hooks, set `TYPESAFE_API_KEY` in the environment or in `~/.zshenv`. State lives in `~/.local/state/jev`.

**What leaves the machine:** the brief, an unrouted Agent prompt, or the compaction facts with up to 40k characters of the transcript tail and the summary. All of it goes to `api.typesafe.ai`, redacted first: keys, tokens, Authorization headers, secret-named variables, emails and IPs are removed, while paths and hostnames are kept. Redaction does not hide code or business details. Every hook fails open. `hooks/jev/README.md` documents the design, the knobs, the limits and the tests (`hooks/jev/test/run.sh`).
