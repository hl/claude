# ~/.claude — the starship crew pipeline

Personal Claude Code configuration, centered on a multi-agent orchestration setup:
one orchestrator you talk to, and a fixed pipeline of named agents that plan,
implement, review, and bookkeep every change before it lands on a default branch.
Inspired by [Steve Yegge's "The Shape of Things to Come"](https://yegge.ai/essays/the-shape-of-things-to-come/)
(producers/consumers matched through an issue-tracker spine) and its sequel
["Model Welfare"](https://yegge.ai/essays/model-welfare/) (handoffs over compaction,
recognition, blamelessness).

## How it works

You run `pien` (zshrc alias) from `~/Projects` inside a [herdr](https://herdr.dev)
pane and say things like *"start an agent in builder_os and do X"*. Pien never
touches code — she conducts:

```
you ──► Pien (Commander / orchestrator, fable)
           │ creates a task workspace, converts your chat into a work order
           ▼
        Odessa (Navigator / planner, fable) ── investigates the repo, apportions the
           │                                   work into beads (bd issues) with
           │                                   acceptance criteria
           ▼
        Jules (Engineer / worker, opus) ────── one per ready bead, each in her own git
           │                                   worktree: implement, PR, foreground CI
           │                                   watch
           ▼
        Rasma (Auditor / reviewer, GPT/codex) ─ fresh eyes: sees only the diff and the
           │                                    bead's criteria; APPROVE / CHANGES /
           ▼                                    BLOCKED (CHANGES loops back to Jules)
        merge under a blast-radius gate, bead closed
           ▼
        Mira (Quartermaster / clerk, sonnet) ── reconciles bead states, mirrors,
                                                stale claims
```

The **bead is the handoff artifact**: every stage reads and writes the bd issue, so
dispatch prompts collapse to `Implement <bd-id>.`, pipeline state survives context
compaction, and the ledger doubles as provenance. The bead dependency graph *is* the
dispatch plan — independent beads run as parallel workers, `bd ready` says what can
start now.

Standing rules:

- **You talk only to Pien.** Stage agents never block on a human; they end their
  turn with numbered questions and Pien relays them.
- **Reviews are cross-vendor by design** — codex/GPT judging Claude's work avoids
  correlated blind spots, and the reviewer never sees the author's reasoning.
- **Workspaces are task-scoped, not directory-scoped**: one objective = one labeled
  herdr workspace with every stage as a tab, torn down as a unit. Pien's own
  workspace stays empty.
- **Jira (or any tracker) is an opt-in, one-way visibility mirror** — a project asks
  for it in its own CLAUDE.md/AGENTS.md, beads stay the source of truth.
- **Backlog is fuel** — when `bd ready` runs dry while an objective has unplanned
  scope, Pien dispatches Odessa for the next tranche *before* workers idle, so a
  long run self-feeds.
- **Handoffs beat compaction** — a deep-context Jules writes a handoff note on her
  bead and a fresh session resumes the same worktree, instead of grinding through a
  mid-bead compaction. Failures get blameless postmortem beads that feed the doctrine
  loop; genuine praise gets relayed to the agent (and kept as `Laurel:` memories),
  never stripped as fluff; workers are never misled to shape behavior.

## What survives a session

Project knowledge is layered (the essay's "brain architecture"), each tier with its
own retention and delivery:

| Tier | Lives in | How it reaches an agent |
|---|---|---|
| Work units + specs | beads (`.beads/`) | `bd show` — the bead is the work order |
| Operational facts / gotchas | `bd remember` | pushed into every session by `bd prime` |
| Standing rules (the constitution) | `.claude/rules/*.md` | auto-loaded by Claude Code into every claude-run stage |
| Design doctrine (the *why*) | `brain/*.md` | pulled on demand by Odessa at planning |
| Recurring procedures | `.claude/skills/` | auto-loaded on match |

Every stage feeds the tiers as it works: Odessa and Jules `bd remember` gotchas and
file beads proposing skills; Pien's judgment calls (blast-radius rulings, design
resolutions) are recorded verbatim on the bead by Mira under the `ruling` label.
Precedent that keeps getting cited doesn't stay archaeology: Pien dispatches
Odessa for a **compaction pass** — gather by the `ruling` label, distill into
`.claude/rules/` (with provenance back to the originating bead) or `brain/`, `bd rules
audit`/`compact` to keep the rule set coherent, commit to the default branch. Two
scope limits: doctrine binds workers only once committed (worktrees branch from
committed state), and the codex-run Rasma loads none of it — Pien relays a rule
into her prompt when it bears on a verdict.

## Unattended machinery

- **The janitor** (`bin/beads-janitor.sh` + `launchd/ai.crew.janitor.plist`,
  installed in `~/Library/LaunchAgents`) — "crons watch, models act": launchd fires at
  08/12/16/20 (silent overnight to conserve tokens), the script finds `~/Projects`
  repos with `in_progress` beads and runs a headless Mira sweep in each — close
  beads whose PR merged, note stale claims, tag dead PRs `needs-human`. Writes are
  signed `--actor janitor`; each sweep has a hard deadline and the lock self-heals if
  a run dies uncleanly. It only flags and closes — it never unblocks work — so
  overnight silence costs nothing but latency.
- **The decision docket** — a decision parked on the user is durable state, not a
  toast: the bead carries the `needs-human` label (tagged by Jules on out-of-bounds
  merges, by the janitor, or by Mira for anything Pien surfaces). The
  fleet-overview skill renders the docket as a "Waiting on you" list across *all*
  beads repos — parked decisions deliberately outlive their workspaces. When you
  rule, Mira drops the label and records the ruling.

## The names

Previous generations were named for the tool they drove (claudia ↔ cmux, hera ↔
herdr); the generation before this one was the **Moirai (the Fates)**, named for
role via Greek mythology. This generation keeps the role-first naming but trades the
loom for a bridge: a **starship crew**, each agent a rank whose duty is the role.

| Agent | Rank | Why the fit |
|---|---|---|
| **Pien** | Commander | The orchestrator: runs the bridge, conducts the crew, touches no code herself |
| **Odessa** | Navigator | The planner: charts the course — apportions an objective into beads, each a measured, PR-sized leg |
| **Jules** | Engineer | The worker: builds the actual thing, one thread (worktree/branch) per bead |
| **Rasma** | Auditor | The reviewer: the final, independent word before anything lands |
| **Mira** | Quartermaster | The bookkeeper: keeps the bead ledger — the pipeline's memory — honest |

## Pieces

In this repo:

| Path | What it is |
|---|---|
| `agents/pien.md` | Orchestrator: pipeline state machine, herdr dispatch/wait mechanics, focus discipline, gates. The only agent whose tool surface is deliberately just Bash (`herdr` + `jq` + read-only `bd`) |
| `agents/odessa.md` | Planner role: bead conventions, `bd init` bootstrap, `brain/` doctrine, rulings compaction into `.claude/rules/`, optional tracker mirroring |
| `agents/jules.md` | Worker role: claim → implement → PR → foreground CI watch → rework → gated merge; hands off via bead notes before compaction, tags `needs-human` on out-of-bounds merges |
| `agents/mira.md` | Clerk role: mechanical bd operations, reconciliation sweeps, ruling/laurel recording — no judgment calls |
| `agents/rasma.md` | Reviewer role, written agent-agnostic (fresh-eyes verdict rules: APPROVE / CHANGES / BLOCKED). Driven today by codex/GPT via the `rasma` profile (`~/.codex/rasma.config.toml`); the `~/.codex/AGENTS.md` shim on `Rasma:` prompts is the fallback |
| `agents/orla.md` | The simple fleet orchestrator — dispatch, watch, report; no pipeline, no issue tracker. The starting point before the full crew is warranted |
| `skills/fleet-overview/` | One-glance fleet status table for Pien, plus the `needs-human` decision docket (herdr + jq + read-only bd) |
| `bin/beads-janitor.sh` | The janitor: per-repo headless Mira sweeps with deadline and self-healing lock |
| `launchd/ai.crew.janitor.plist` | Canonical copy of the janitor's launchd unit (install: copy to `~/Library/LaunchAgents`, `launchctl bootstrap gui/$UID`) |
| `hooks/`, `settings.json`, `statusline-command.sh`, `CLAUDE.md` | General Claude Code config (herdr agent-state hook, formatting hooks, statusline) |

Outside this repo, but part of the system:

- `~/.zshrc` — the `pien` alias: `cd ~/Projects && CLAUDE_CONFIG_DIR=~/.claude-api
  claude --agent pien --dangerously-skip-permissions`. Identity and permissions live
  in the launch; each agent's model and effort live in its file's frontmatter.
- `~/.codex/rasma.config.toml` — the codex profile that loads Rasma's role file and
  pins her model/effort (`codex -p rasma`); `~/.codex/AGENTS.md` carries a shim that
  points codex at `agents/rasma.md` when a prompt opens with `Rasma:`, as fallback
  (codex has no agent files of its own; the role text stays in this repo).
- `~/.claude-api/` — a second, independently authenticated Claude identity ("fable").
  Its `agents/` and `skills/` are symlinks into this repo, so both identities resolve
  the same files. Pien and Odessa run on this identity; Jules and Mira on
  the main one — the two heavy stages split across the two accounts.
- `~/.agents/skills/herdr` (symlinked into `skills/`) — the external herdr operating
  manual, preloaded for Pien. Maintained upstream, never edited here.
- Tools: [herdr](https://herdr.dev) (agent terminal multiplexer), `bd`
  ([beads](https://github.com/gastownhall/beads), git-backed issue tracker), `claude`,
  `codex`.

## Usage

```
pien                                  # from a herdr pane
> start an agent in builder_os and fix the flaky webhook tests
```

Pien creates the task workspace, dispatches Odessa, and reports back as each
stage settles. Ask her "what's going on" for a fleet overview at any time.
