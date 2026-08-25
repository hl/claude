# ~/.claude — a two-agent fleet

Personal Claude Code configuration, centered on a small orchestration setup: one console
you talk to, and one task lead per task who owns her work end to end — plan, build,
review, document, merge — before anything lands on a default branch. Inspired by
[Steve Yegge's "The Shape of Things to Come"](https://yegge.ai/essays/the-shape-of-things-to-come/)
(producers/consumers matched through an issue-tracker spine) and its sequel
["Model Welfare"](https://yegge.ai/essays/model-welfare/) (handoffs over compaction,
recognition, blamelessness).

## How it works

You run `pien` from `~/Projects` inside a [herdr](https://herdr.dev) pane and say things
like *"start an agent in builder_os and do X"*. Pien never touches code — she dispatches:

```
you ──► Pien (fleet console, fable)
           │ one task = one herdr workspace + one git worktree;
           │ converts your chat into a self-contained objective
           ▼
        Dea (task lead, opus) ── owns the whole task, and runs each stage as a
           │                     subagent whose context dies with the stage:
           │                       plan     (opus)   → beads with acceptance criteria
           │                       build    (opus)   → one bead, verbatim
           │                       review   (opus)   → fresh eyes, diff + criteria only
           │                       document (sonnet) → what the change invalidated
           │
           │                     plus two read-only second opinions from codex,
           │                     for reasoning that isn't Claude's:
           │                       on the plan   → assumptions, collisions, thin criteria
           │                       on the diff   → an independent second verdict
           ▼
        merge under a blast-radius gate, bead closed
```

The pipeline is gone on purpose: stages that used to be separate sessions handed back to
an orchestrator are now subagents inside Dea's own session. She holds the task; they hold
a stage. One agent owning a task end to end means no stage boundary is also a memory
boundary.

The **bead is the handoff artifact**: Dea reads and writes the bd issue at every stage,
so a dispatch prompt collapses to the bead id, task state survives compaction, and the
ledger doubles as provenance.

Standing rules:

- **You talk only to Pien.** Dea never blocks on a human; she ends her turn with numbered
  questions and Pien relays them.
- **Review gets fresh eyes from isolation, and a second opinion from another vendor.**
  The review subagent runs on the `Explore` agent type (no `Edit`/`Write`, so the easy
  fix-while-reviewing path isn't there) and receives the diff and the acceptance criteria
  — never Dea's plan, her reasoning, the bead's discussion, or `brain/`. It shares a model
  with build, so what decorrelates it is that it never watched the change being built. A
  reviewer who shares the author's reasoning rubber-stamps the author's blind spots.
  Withholding is disclosed structure, not deception.
- **Codex is the decorrelation the account can't otherwise buy.** `codex review` gives a
  second, independent verdict on the same diff, and a `codex exec` pass reads the plan
  before any code is written — otherwise the one stage nothing in the system questions.
  Both are advisory: findings merge into one list and Dea's own blocking bar decides, the
  three-round cap doesn't move, and if codex is unreachable the task proceeds on the Claude
  verdict alone. Neither ever runs the quality gate; their job is to give Dea enough
  information to judge, nothing else.
- **Workspaces are task-scoped, not directory-scoped**: one objective = one labeled herdr
  workspace, torn down as a unit. Pien's own workspace stays empty.
- **Jira (or any tracker) is an opt-in, one-way mirror** — a project asks for it in its
  own CLAUDE.md/AGENTS.md; beads stay the source of truth.
- **Handoffs beat compaction, and the review boundary is where they're cheapest.** Most
  of a task's context goes to review and rework, not to building — so a Dea who reaches
  an open PR already deep in her context checkpoints and asks Pien for a fresh session
  rather than carrying a whole build's worth of memory through three rework rounds. Pien
  confirms the checkpoint landed, closes the tab, and relaunches into the same worktree
  with the same name. Nothing is lost: rework runs off the bead's verdict and disposition
  lists verbatim.
- **Failures get blameless postmortems; praise is relayed, never stripped as fluff;
  agents are never misled to shape their behavior.**

## What survives a session

Project knowledge is layered, each tier with its own retention and delivery:

| Tier | Lives in | How it reaches an agent |
|---|---|---|
| Work units + specs | beads (`.beads/`) | `bd show` — the bead is the work order |
| Task state across sessions | `FLEET_CHECKPOINT v1` bead comments | the contract in `agents/CHECKPOINTS.md` |
| Operational facts / gotchas | `bd remember` | pushed into every session by `bd prime` |
| Standing rules (the constitution) | `.claude/rules/*.md` | auto-loaded by Claude Code, and read by the reviewer as repo contract |
| Design doctrine (the *why*) | `brain/*.md` | pulled on demand at planning; the reviewer never reads it |
| Recurring procedures | `.claude/skills/` | auto-loaded on match |

A dead session and a finished one look identical from outside, so the checkpoint is what
makes the difference legible: Dea appends one before her first edit, at every verdict and
rework round, and at every landing or handoff — and reads it back, because a write
returning success only proves the call was accepted.

Dea feeds the tiers as she works, and curates them when her task lands: `bd remember` for
gotchas, a bead proposing a skill for a recurring procedure, and a compaction pass that
distills precedent cited more than once into `.claude/rules/` or `brain/`. Two scope
limits: doctrine binds nobody until it is committed to the default branch (worktrees
branch from committed state), and the reviewer reads `.claude/rules/` but never `brain/`,
so a rule that must reach review belongs in the former.

## The decision docket

A decision parked on the user is durable state, not a toast: the bead carries the
`needs-human` label, tagged by Dea when a merge falls outside the blast-radius gate —
migrations, CI config, auth/secrets paths, publishing — or when a review standoff becomes
a design disagreement. Pien renders the docket as a "Waiting on you" list across *all*
beads repos on every roundup, because parked decisions deliberately outlive their
workspaces. When you rule, the answer goes back into the same agent verbatim and gets
recorded on the bead under the `ruling` label. Reconciliation is on-demand — no sweep
timers — by diffing `herdr agent list` against `bd list`.

## The two roles

| Agent | Role | Model | Tools |
|---|---|---|---|
| **Pien** | Fleet console — your single counterpart across every project. Converts chat into objectives, launches and rotates Deas, tracks the fleet, keeps the docket. Runs no pipeline of her own | `fable` | `Bash`, `Skill`, `Agent(Explore)` — no file access at all |
| **Dea** | Task lead — owns one task end to end in her own git worktree, running each stage as a subagent | `opus` | all |

Pien is deliberately the cheaper model: she decomposes nothing and rules on nothing. Her
objectives are transcription of your intent, the blast-radius gate is written into Dea's
role file rather than improvised, and anything neither covers goes to you through the
docket instead of being invented mid-run.

## Pieces

In this repo:

| Path | What it is |
|---|---|
| `agents/pien.md` | Console role: herdr dispatch/wait mechanics, focus discipline, rotation, objectives, docket. Her tool surface is deliberately just Bash (`herdr` + `jq` + read-only `bd`) plus one read-only search agent |
| `agents/dea.md` | Task-lead role: the full cycle — subagent crew, bead conventions, build and verification discipline, the reviewer's brief, rework routing and round cap, doctrine curation, the gated merge |
| `agents/CHECKPOINTS.md` | The `FLEET_CHECKPOINT v1` contract: schema, when to write one, how to resume from one |
| `fleet/schemas/` | JSON Schema pinning the shape of the codex plan critique (`--output-schema`), so it arrives as data rather than prose |
| `fleet/bin/pien`, `fleet/pien.zsh` | The `pien` launcher — requires a herdr pane, `cd`s to `~/Projects`, never passes `--model` (frontmatter owns that) |
| `hooks/`, `settings.json`, `statusline-command.sh`, `CLAUDE.md` | General Claude Code config (herdr agent-state hook, formatting hooks, statusline) |

Outside this repo, but part of the system:

- `~/.zshrc` — sources `fleet/pien.zsh`, which defines the `pien` command. It is sourced
  *after* `~/.codex/fleet/pien.zsh`, so `pien` resolves to this stack and shadows the
  codex console; reach that one by path (`~/.codex/fleet/bin/pien`) while it still exists.
- **Two accounts, split by model.** `~/.claude` (this repo) is the claude.ai enterprise
  identity and runs **Dea** on opus; `~/.claude-api` is the API console identity and is
  used for **fable only**, which is what **Pien** runs on. The enterprise account has no
  fable access under ZDR — which is why every stage inside Dea runs on opus or sonnet.
  `~/.claude-api/agents` and `skills/` are symlinks into this repo, so both identities
  resolve the same role files.
  The split is enforced at two points: the `pien` launcher exports
  `CLAUDE_CONFIG_DIR=~/.claude-api` for itself, and Pien sets it back to `~/.claude` when
  she creates Dea's pane. A pane inherits the environment it was launched from, so
  without that second step Dea's work would silently bill to the wrong account.
- `~/.agents/skills/herdr` (symlinked into `skills/`) — the external herdr operating
  manual, preloaded for Pien. Maintained upstream, never edited here.
- `~/.codex/` — codex is called as a **bare harness**: `codex review` and `codex exec`,
  no `-p`/profile, and never pointed at a role file or prompt inside that folder
  (`fleet/roles/rasma.md` and its descendants included). That stack moves on its own
  schedule, and a second opinion whose instructions changed underneath it is worse than
  none — so what codex is told to do lives in `agents/dea.md`. Note that this means
  reviewed code leaves the ZDR account.
- Tools: [herdr](https://herdr.dev) (agent terminal multiplexer), `bd`
  ([beads](https://github.com/gastownhall/beads), git-backed issue tracker), `claude`.

## Usage

```
pien                                  # from a herdr pane
> start an agent in builder_os and fix the flaky webhook tests
```

Pien creates the task workspace and worktree, launches Dea, and reports as the task
settles. Ask her "what's going on" for a fleet overview at any time.
