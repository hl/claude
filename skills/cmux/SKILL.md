---
name: cmux
description: Drive cmux from natural language — spawn, prompt, read, and tear down its windows, workspaces, panes, and surfaces, and orchestrate the agent sessions (Claude Code, Codex, pi) running inside them. Use whenever a prompt asks to open, inspect, drive, or close cmux surfaces or run agents in them.
argument-hint: [what to do in cmux]
---

# cmux

## Purpose

You are driving **cmux**, a CLI + socket for controlling terminal surfaces (and the
agents running inside them). Every window, workspace, pane, and surface is a real,
addressable object you can spawn, prompt, read, and close from the command line.

## Instructions

### Discover commands first (`--help`)

Before doing anything, run:

```bash
cmux --help
```

Then drill into any subcommand you intend to use:

```bash
cmux <command> --help     # e.g. cmux workspace --help, cmux send --help
```

cmux evolves; **trust `--help` over memory**. Never guess flags — confirm them.

### Understand the hierarchy

Everything nests in one tree. Learn the boxes and the verbs fall out:

- **Window** → a top-level OS window.
- **Workspace** → a sidebar entry ("tab") inside a window.
- **Pane** → a split region within a workspace.
- **Surface** → a tab within a pane (a terminal or a browser).

Use `cmux tree --all` (or `cmux workspace list` / `cmux list-pane-surfaces`) to see
the current state before you act.

### Create a workspace and inject credentials (`--env-file`)

Create a workspace and capture BOTH refs in one call. `--json` returns the
`workspace_ref` and the initial `surface_ref` — grab and thread them; never guess
positional refs.

```bash
cmux workspace create --name <name> --cwd <dir> --env-file .env --json
```

- **`cmux workspace create` supports `--env-file`, which loads that file's
  environment variables into every surface in the workspace** — so an agent
  launched in a pane (`claude`, `pi`, `codex`, `gemini`) comes up already
  authenticated, no manual `export` needed.
- **Default `--env-file` to `.env`** (the repo's `.env`) unless told otherwise:
  `--env-file .env`. That is the canonical source for `OPENROUTER_API_KEY`,
  `ANTHROPIC_API_KEY`, etc.
- **Inline vars:** `--env KEY=VALUE` (repeatable) sets individual vars without a
  file. `CMUX_*` names are reserved and can't be overridden.
- Pair it with `--layout <compact-json>` to boot a whole multi-pane team
  declaratively in one call (each pane's `command` auto-launches its agent).
- **Don't inject over a working login.** `--env`/`--env-file` apply to *every*
  surface in the workspace — there is no per-pane scoping. If an agent is already
  authenticated (e.g. Claude Code), keep its key out of the env-file, or give it
  its own workspace, rather than pushing a placeholder over the working login.
- **Assume the keys are already set up — and never read their values.** By
  default, just point `--env-file` at `.env` and proceed; do not `cat .env`,
  `echo $OPENROUTER_API_KEY`, or `read-screen` a surface to capture a key. **Only
  if an agent actually fails to authenticate** should you validate, and do it
  *safely*: `cmux workspace env --workspace <ref> --mask` shows that a var is
  present without revealing it, and `[ -n "$VAR" ]` confirms it is non-empty.
  Report the masked/presence result, never the secret itself.

### The control loop

You operate surfaces the way a person would, but over the CLI:

- `cmux send --surface <ref> "<text>"` — type text into a surface.
- `cmux send-key --surface <ref> enter` — submit it (press a key). **`send` types; `send-key` submits — they are separate steps.**
- `cmux read-screen --surface <ref>` — read what's on screen (add `--scrollback` for history). This is your eyes.
- `cmux close-surface --surface <ref>` — end a surface cleanly.

### Driving AI agents inside cmux

cmux surfaces can host coding agents (Claude Code, Codex, pi). Launching them so they
run unattended, and waiting on their turn-completion via notification events, have
agent-specific gotchas — bypass/yolo launch flags, one-time hook setup, and which
event actually signals "done". **Before you launch or wait on any agent, read
[`references/agents.md`](references/agents.md).** Plain terminal/browser surfaces
don't need it.

### Best practices

Beyond the core loop above, these are the non-obvious rules:

- **Refs are positional and renumber.** `surface:N` / `workspace:N` shift as things
  open and close. Re-read the tree right before you act; for anything long-lived,
  anchor to a **stable window/workspace UUID** (`--id-format both`), not a positional ref.
- **Close scoped, never broad.** Close only surfaces you just created or explicitly
  identified. Never loop a close over the whole `tree` — you'll kill things you didn't
  mean to. `close-window` may no-op while a live agent occupies a pane; use
  `close-surface` per pane.
- **One window per team.** Keep a unit of work to a single window so it stays
  monitorable and tearable as a unit.

## Workflows

### Drive a surface end-to-end

The default loop for any single-surface task: discover, inspect, act, verify, report.

1. `cmux --help` (and per-subcommand `--help`) to confirm the verbs.
2. Inspect current state (`tree --all` / `workspace list`).
3. Take the action (create / send + send-key / read).
4. Read back to verify the result.
5. Report concisely what happened, citing the surfaces/refs involved.

## Report Format

Report concisely in plain English: what you did, the surfaces/refs involved, and
what `read-screen` confirmed. Cite refs (e.g. `workspace:2` / `surface:3`) and never
echo secret values.
