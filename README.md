# ~/.claude — the Fates pipeline

Personal Claude Code configuration, centered on a multi-agent orchestration setup:
one orchestrator you talk to, and a fixed pipeline of named agents that plan,
implement, review, and bookkeep every change before it lands on a default branch.
Inspired by [Steve Yegge's "The Shape of Things to Come"](https://yegge.ai/essays/the-shape-of-things-to-come/)
(producers/consumers matched through an issue-tracker spine) and its sequel
["Model Welfare"](https://yegge.ai/essays/model-welfare/) (handoffs over compaction,
recognition, blamelessness).

## How it works

You run `ananke` (zshrc alias) from `~/Projects` inside a [herdr](https://herdr.dev)
pane and say things like *"start an agent in builder_os and do X"*. Ananke never
touches code — she conducts:

```
you ──► Ananke (orchestrator, fable)
           │ creates a task workspace, converts your chat into a work order
           ▼
        Lachesis (planner, fable) ── investigates the repo, apportions the work
           │                         into beads (bd issues) with acceptance criteria
           ▼
        Clotho (worker, opus) ────── one per ready bead, each in her own git
           │                         worktree: implement, PR, foreground CI watch
           ▼
        Atropos (reviewer, GPT/codex) ─ fresh eyes: sees only the diff and the
           │                            bead's criteria; APPROVE / CHANGES / BLOCKED
           ▼                            (CHANGES loops back to the same Clotho)
        merge under a blast-radius gate, bead closed
           ▼
        Mnemosyne (clerk, sonnet) ── reconciles bead states, mirrors, stale claims
```

The **bead is the handoff artifact**: every stage reads and writes the bd issue, so
dispatch prompts collapse to `Implement <bd-id>.`, pipeline state survives context
compaction, and the ledger doubles as provenance. The bead dependency graph *is* the
dispatch plan — independent beads run as parallel workers, `bd ready` says what can
start now.

Standing rules:

- **You talk only to Ananke.** Stage agents never block on a human; they end their
  turn with numbered questions and Ananke relays them.
- **Reviews are cross-vendor by design** — codex/GPT judging Claude's work avoids
  correlated blind spots, and the reviewer never sees the author's reasoning.
- **Workspaces are task-scoped, not directory-scoped**: one objective = one labeled
  herdr workspace with every stage as a tab, torn down as a unit. Ananke's own
  workspace stays empty.
- **Jira (or any tracker) is an opt-in, one-way visibility mirror** — a project asks
  for it in its own CLAUDE.md/AGENTS.md, beads stay the source of truth.
- **Backlog is fuel** — when `bd ready` runs dry while an objective has unplanned
  scope, Ananke dispatches Lachesis for the next tranche *before* workers idle, so a
  long run self-feeds.
- **Handoffs beat compaction** — a deep-context Clotho writes a handoff note on her
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
| Design doctrine (the *why*) | `brain/*.md` | pulled on demand by Lachesis at planning |
| Recurring procedures | `.claude/skills/` | auto-loaded on match |

Every stage feeds the tiers as it works: Lachesis and Clotho `bd remember` gotchas and
file beads proposing skills; Ananke's judgment calls (blast-radius rulings, design
resolutions) are recorded verbatim on the bead by Mnemosyne under the `ruling` label.
Precedent that keeps getting cited doesn't stay archaeology: Ananke dispatches
Lachesis for a **compaction pass** — gather by the `ruling` label, distill into
`.claude/rules/` (with provenance back to the originating bead) or `brain/`, `bd rules
audit`/`compact` to keep the rule set coherent, commit to the default branch. Two
scope limits: doctrine binds workers only once committed (worktrees branch from
committed state), and the codex-run Atropos loads none of it — Ananke relays a rule
into her prompt when it bears on a verdict.

## Unattended machinery

- **The janitor** (`bin/beads-janitor.sh` + `launchd/ai.fates.janitor.plist`,
  installed in `~/Library/LaunchAgents`) — "crons watch, models act": launchd fires at
  08/12/16/20 (silent overnight to conserve tokens), the script finds `~/Projects`
  repos with `in_progress` beads and runs a headless Mnemosyne sweep in each — close
  beads whose PR merged, note stale claims, tag dead PRs `needs-human`. Writes are
  signed `--actor janitor`; each sweep has a hard deadline and the lock self-heals if
  a run dies uncleanly. It only flags and closes — it never unblocks work — so
  overnight silence costs nothing but latency.
- **The decision docket** — a decision parked on the user is durable state, not a
  toast: the bead carries the `needs-human` label (tagged by Clotho on out-of-bounds
  merges, by the janitor, or by Mnemosyne for anything Ananke surfaces). The
  fleet-overview skill renders the docket as a "Waiting on you" list across *all*
  beads repos — parked decisions deliberately outlive their workspaces. When you
  rule, Mnemosyne drops the label and records the ruling.

## The names

Previous generations were named for the tool they drove (claudia ↔ cmux, hera ↔
herdr). This generation breaks that tie and names agents for their **role**, drawn
from Greek mythology — specifically the **Moirai (the Fates)**, three sisters who
work a single thread of life. The metaphor is load-bearing: beads string on a
thread, and `bd` (beads) is the pipeline's spine.

| Agent | Origin | Why the fit |
|---|---|---|
| **Ananke** | Necessity, primordial goddess of inevitability, mother of the Fates | The orchestrator: what must happen, happens — she conducts her daughters but spins nothing herself |
| **Lachesis** | "The Allotter" — measures and apportions each thread's lot | The planner: apportions an objective into beads, each a measured, PR-sized lot |
| **Clotho** | "The Spinner" — spins the thread into being | The worker: produces the actual thing, one thread (worktree/branch) per bead |
| **Atropos** | "The Unturnable" — cuts the thread; her decision is final | The reviewer: the final, irreversible word before anything lands |
| **Mnemosyne** | Memory, Titaness, keeper of remembrance | The bookkeeper: keeps the bead ledger — the pipeline's memory — honest |

(In myth Clotho spins before Lachesis measures; the pipeline measures first. The
sisters have not complained.)

## Pieces

In this repo:

| Path | What it is |
|---|---|
| `agents/ananke.md` | Orchestrator: pipeline state machine, herdr dispatch/wait mechanics, focus discipline, gates. The only agent whose tool surface is deliberately just Bash (`herdr` + `jq` + read-only `bd`) |
| `agents/lachesis.md` | Planner role: bead conventions, `bd init` bootstrap, optional tracker mirroring |
| `agents/clotho.md` | Worker role: claim → implement → PR → foreground CI watch → rework → gated merge |
| `agents/mnemosyne.md` | Clerk role: mechanical bd operations, reconciliation sweeps, no judgment calls |
| `agents/atropos.md` | Reviewer role, written agent-agnostic (fresh-eyes verdict rules: APPROVE / CHANGES / BLOCKED). Driven today by codex/GPT via a shim in `~/.codex/AGENTS.md` — swap the shim to change the reviewing model |
| `skills/fleet-overview/` | One-glance fleet status table for Ananke, plus the `needs-human` decision docket (herdr + jq + read-only bd) |
| `bin/beads-janitor.sh` | The janitor: per-repo headless Mnemosyne sweeps with deadline and self-healing lock |
| `launchd/ai.fates.janitor.plist` | Canonical copy of the janitor's launchd unit (install: copy to `~/Library/LaunchAgents`, `launchctl bootstrap gui/$UID`) |
| `hooks/`, `settings.json`, `statusline-command.sh`, `CLAUDE.md` | General Claude Code config (herdr agent-state hook, formatting hooks, statusline) |

Outside this repo, but part of the system:

- `~/.zshrc` — the `ananke` alias: `cd ~/Projects && CLAUDE_CONFIG_DIR=~/.claude-api
  claude --agent ananke --effort medium --dangerously-skip-permissions`. Identity,
  effort, and permissions live in the launch; each agent's model lives in its file's
  frontmatter.
- `~/.codex/AGENTS.md` — a short shim that points codex at `agents/atropos.md` when a
  prompt opens with `Atropos:` (codex has no agent files of its own; the role text
  stays in this repo).
- `~/.claude-api/` — a second, independently authenticated Claude identity ("fable").
  Its `agents/` and `skills/` are symlinks into this repo, so both identities resolve
  the same files. Ananke and Lachesis run on this identity; Clotho and Mnemosyne on
  the main one — the two heavy stages split across the two accounts.
- `~/.agents/skills/herdr` (symlinked into `skills/`) — the external herdr operating
  manual, preloaded for Ananke. Maintained upstream, never edited here.
- Tools: [herdr](https://herdr.dev) (agent terminal multiplexer), `bd`
  ([beads](https://github.com/gastownhall/beads), git-backed issue tracker), `claude`,
  `codex`.

## Usage

```
ananke                                # from a herdr pane
> start an agent in builder_os and fix the flaky webhook tests
```

Ananke creates the task workspace, dispatches Lachesis, and reports back as each
stage settles. Ask her "what's going on" for a fleet overview at any time.
