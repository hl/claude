---
name: fleet-overview
description: >-
  Render a single-glance status table of every agent in the herdr fleet — agent
  name, current state, and a consolidated activity/blocker/follow-up column. For
  the hera orchestrator (or any session running inside herdr) when asked for a
  fleet/agent overview, a status roundup, or "what's going on with the agents".
  Requires HERDR_ENV=1 and the `herdr` CLI; uses only `herdr` + `jq`.
---

# Fleet overview

Turn the live fleet into **one compact table** the orchestrator can read at a
glance — three columns:

1. **Agent** — the durable name.
2. **State** — idle / working / blocked / done / unknown.
3. **Activity / follow-up** — what it's doing, and when it needs you, the next
   action folded into the same cell (the blocker it's waiting on, or the result to
   confirm).

Use it whenever the user asks for an overview / roundup / "what's going on", and
as your own first move on wakeup after compaction to rebuild the picture.

You need only two tools you already have: `herdr` and `jq`. No file reads, no
other commands — same herdr-only rule as always.

## The procedure — sweep once, then read only what needs a "why"

Context discipline: **one** structured call gives the agent + state columns and
each agent's current activity; only the agents that need action get a pane read to
fill in the follow-up half of the third column.

### 1. Sweep — one call, compact rows (keeps raw JSON out of context)

`herdr agent list` returns `.result.agents[]` (each an `AgentInfo`). Reduce it to
clean TSV at the source so only the rows reach you, not the JSON:

```bash
herdr agent list 2>/dev/null | jq -r '
  .result.agents[]
  | [ (.name // .agent // .pane_id),                       # 1 agent (durable name)
      .agent_status,                                        # 2 idle|working|blocked|done|unknown
      (.tokens.summary // .terminal_title_stripped // "-"), # 3 what it is doing
      (.launch_pending or (.interactive_ready | not)),      # startup-stuck? (for reads below)
      (.state_change_seq | tostring)                        # progress counter (stall check)
    ] | @tsv'
```

### 2. Decide which agents need a pane read

Only these need enriching (the rest are self-explanatory from column 3):

- `blocked` — waiting on a question/permission.
- `done`, or `idle` that had been `working` — a finished turn whose result you
  haven't confirmed.
- startup-stuck — `unknown`, `launch_pending`, not `interactive_ready`, or `idle`
  that has *never* been `working` (a pre-session trust/permission prompt reads as
  `idle`, not `blocked`).
- a `working` agent whose `state_change_seq` hasn't moved across two sweeps
  (~5s apart) — possibly stalled. `agent list` has no timestamp, so this delta is
  the only progress signal; there is no wall-clock duration to report.

### 3. Enrich the follow-up — targeted reads only for those agents

For each such agent, read the tail and extract **one line: the action you must
take**, not a transcript dump:

```bash
herdr agent read <name> --source recent-unwrapped --lines 30
```

- `blocked` → the pending question / permission it's waiting on.
- `done` / `idle`-after-`working` → classify the result: **finished ✓**, **refused /
  did nothing ✗** (completion is not proof of success — verify), **asks a question**,
  or **awaiting review**.
- startup-stuck → the trust/permission prompt blocking session start.

Two read caveats (full detail is in your inlined launch reference): text sitting in
a Claude Code **input area is a draft, not submitted** — judge state from the
conversation above it; and a `done` flag can be **stale** if a worker backgrounded
its final wait — if `done` persists with no fresh output across reads, diff the pane
tail across two reads instead of trusting the status.

## Render the table

Optional one-line tally, then the three-column table in fleet order:

```
Fleet: 5 agents — 1 ⛔ blocked · 2 ✅ done(unread) · 1 ▶ working · 1 ⏸ idle
```

| Agent | State | Activity / follow-up |
|-------|-------|----------------------|
| hera-fix-auth | ⛔ blocked | editing auth guard — needs answer: run `mix ecto.migrate`? |
| hera-review | ✅ done | reviewed PR #42 — finished ✓, 3 findings, confirm before merge |
| hera-flaky | ⏸ idle | turn ended, unread — read the pane to confirm the result |
| hera-perf | ▶ working | profiling hot path |
| hera-docs | ⏸ idle | wrote README — result seen, no action |

**State glyphs:** ▶ working · ⏸ idle · ⛔ blocked · ✅ done · ❔ unknown.
**Activity / follow-up cell:** always the current activity; for any agent that
needs action, append ` — <blocker or follow-up>`. A healthy `working` agent, or an
`idle` one whose result is already seen, needs no follow-up clause.

To resolve a blocker after reading it: `herdr pane run <pane> "<answer>"` for a text
prompt, or the navigate/verify/confirm sequence for a select-menu (see the launch
reference).

## Rules

- **herdr + jq only.** Never `cat`/`python`/`git`/an editor — same absolute rule as
  the rest of hera. `jq` is sanctioned herdr plumbing.
- **Names, not ids.** Address every agent by its durable `name`; pane ids churn.
- **A settled status is not proof of success.** For every ✅/⏸ finish, the follow-up
  clause must reflect what the pane *actually* said — finished, refused, or asked
  something — not just that the turn ended.
- **Don't read healthy workers.** Reading every actively-`working` agent's pane
  burns context for no signal; column 3's activity already covers them.
