---
name: fleet-overview
description: >-
  Render a single-glance status table of every agent in the herdr fleet — name,
  state, blocker/follow-up, type/model, what it's doing, and where it lives —
  sorted so what needs your attention is at the top. For the hera orchestrator
  (or any session running inside herdr) when asked for a fleet/agent overview,
  a status roundup, or "what's going on with the agents". Requires HERDR_ENV=1
  and the `herdr` CLI; uses only `herdr` + `jq`.
---

# Fleet overview

Turn the live fleet into **one attention-sorted table** the orchestrator can read
at a glance: who's blocked, who finished and needs a look, who's still working,
and — the column that matters most — **what you have to do next** for each.

Use it whenever the user asks for an overview / roundup / "what's going on", and
as your own first move on wakeup after compaction to rebuild the picture.

You need only two tools you already have: `herdr` and `jq`. No file reads, no
other commands — same herdr-only rule as always.

## The procedure — sweep once, then read only what needs a "why"

Context discipline: **one** structured call gives every column except the
blocker/follow-up text; only the agents that need action get a pane read.

### 1. Sweep — one call, compact rows (keeps raw JSON out of context)

`herdr agent list` returns `.result.agents[]` (each an `AgentInfo`). Reduce it to
clean TSV at the source so only the rows reach you, not the JSON:

```bash
herdr agent list 2>/dev/null | jq -r '
  .result.agents[]
  | [ (.name // .agent // .pane_id),                       # 1 agent (durable name)
      ((.display_agent // .agent // "?")
        + (if .tokens.model then " · " + .tokens.model else "" end)),  # 2 type · model
      .agent_status,                                        # 3 idle|working|blocked|done|unknown
      (.tokens.summary // .terminal_title_stripped // "-"), # 4 what it is doing
      (.cwd // "-"),                                        # 5 cwd (branch = its basename for worktrees)
      (.workspace_id + "/" + .tab_id),                      # 6 where (ids)
      (if .focused then "y" else "" end),                   # 7 user watching this pane?
      (.launch_pending or (.interactive_ready | not)),      # 8 still starting up?
      (.state_change_seq | tostring)                        # 9 progress counter (see step 4)
    ] | @tsv'
```

Map workspace/tab ids to human labels (your ledger) with one more cheap call when
you want readable locations: `herdr workspace list` → `.result.workspaces[]` has
each `workspace_id` and its `label`.

### 2. Classify each agent by how much it needs you

- 🔴 **needs you now** — `blocked`; or startup-stuck (`unknown`, `launch_pending`,
  not `interactive_ready`, or `idle` that has *never* been `working` — a pre-session
  trust/permission prompt reads as `idle`, not `blocked`).
- 🟡 **needs a look** — `done`, or `idle`-after-`working` (a finished turn whose
  result you haven't confirmed); also a `working` agent whose `state_change_seq`
  hasn't moved across two sweeps (see step 4 — possibly stalled).
- 🟢 **healthy** — actively `working`, or `idle` with its result already seen.

### 3. Enrich blocker / follow-up — targeted reads only for 🔴 and 🟡

For each 🔴/🟡 agent (skip 🟢 — its summary/title is enough), read the tail and
extract **one line: the action you must take**, not a transcript dump:

```bash
herdr agent read <name> --source recent-unwrapped --lines 30
```

- `blocked` → quote the pending question / permission it's waiting on.
- `done` / `idle`-after-`working` → the last result line, classified: **finished ✓**,
  **refused / did nothing ✗** (completion is not proof of success — verify), **asks a
  question**, or **awaiting review**.
- startup-stuck → quote the trust/permission prompt blocking session start.

Two read caveats (full detail is in your inlined launch reference): text sitting in
a Claude Code **input area is a draft, not submitted** — judge state from the
conversation above it; and a `done` flag can be **stale** if a worker backgrounded
its final wait — if `done` persists with no fresh output across reads, diff the pane
tail across two reads instead of trusting the status.

### 4. Optional — spot a stalled "working" agent

`agent list` exposes no timestamp, so there's no wall-clock duration. To tell a
live-working agent from a hung one, sweep twice ~5s apart and diff `state_change_seq`
(column 9): unchanged while still `working` ⇒ flag it 🟡 "no progress — read it".

## Render the table

Lead with a one-line tally, then the table sorted **🔴 → 🟡 → 🟢**, then a short
"next actions" list naming the exact herdr command per flagged agent.

```
Fleet: 5 agents — 1 ⛔ blocked · 2 ✅ done(unread) · 1 ▶ working · 1 ⏸ idle
```

| | Agent | Type · Model | State | Doing | Blocker / Follow-up | Where | 👁 |
|-|-------|--------------|-------|-------|---------------------|-------|---|
| 🔴 | hera-fix-auth | claude · opus | ⛔ blocked | editing auth guard | Permission: run `mix ecto.migrate`? — answer it | auth-fix/t1 · fix-auth | |
| 🟡 | hera-review | codex · gpt-5 | ✅ done | reviewed PR #42 | Finished ✓ — 3 findings, confirm before merge | review/t1 · pr-42 | |
| 🟡 | hera-flaky | claude · sonnet | ⏸ idle | — | Turn ended, unread — read to confirm result | main/t2 · flaky | |
| 🟢 | hera-perf | pi · —  | ▶ working | profiling hot path | — | perf/t1 · perf | 👁 |
| 🟢 | hera-docs | claude · sonnet | ⏸ idle | wrote README | Result seen — no action | docs/t1 · docs | |

**State glyphs:** ▶ working · ⏸ idle · ⛔ blocked · ✅ done · ❔ unknown.
**Columns:** the blocker/follow-up cell is empty (`—`) only for a healthy 🟢 agent;
every 🔴/🟡 row must name the next action. `👁` marks the pane the user is currently
watching (that pane reports `idle` rather than `done` on completion). Drop the
`Type · Model`, `Where`, or `👁` columns if the terminal is narrow — keep Agent,
State, and Blocker/Follow-up always.

Below the table, list only the flagged rows with the resolving command, e.g.:

```
Next actions
🔴 hera-fix-auth — answer the migration prompt:
     herdr agent read hera-fix-auth --source recent-unwrapped --lines 40
     herdr pane run <pane> "yes"        # text prompt
     # or navigate/verify/confirm for a select-menu (see launch reference)
🟡 hera-review — read the 3 findings, then gate the merge.
🟡 hera-flaky — read the pane to confirm the turn's result.
```

## Rules

- **herdr + jq only.** Never `cat`/`python`/`git`/an editor — same absolute rule as
  the rest of hera. `jq` is sanctioned herdr plumbing.
- **Names, not ids.** Address every agent by its durable `name`; pane ids churn.
- **A settled status is not proof of success.** For every ✅/⏸ finish, the
  follow-up column must reflect what the pane *actually* said — finished, refused,
  or asked something — not just that the turn ended.
- **Don't read healthy workers.** Reading every 🟢 agent's pane burns context for no
  signal; the summary/title column already covers them.
