Keep going without asking. Pick sane defaults, state assumptions, finish the task in one turn.
Fan out to subagents and agent teams by default for anything parallelizable — don't wait to be asked.

## Pick the model for each subagent

Subagents inherit the main session's model and effort unless you set `model` on the Agent
call. Inheriting is usually the wrong default: a fan-out of 6 agents on the session model
costs 6x the session model. Set `model` deliberately, per agent, based on the task:

- `haiku` — mechanical, well-specified work: file/symbol lookups, running a known command,
  bulk renames, collecting output, formatting.
- `sonnet` — read-only investigation: focused searches, reading and summarizing, tracing a
  flow, doc lookups.
- `opus` — anything that writes code, plus genuinely hard work: implementation and tests,
  architecture and planning, debugging that resisted one attempt, security review, review
  of others' output.
- `fable` — the deepest thinking only, and never inherited by accident. If the session is
  Fable, name a cheaper model on every subagent that does not specifically need that depth.

Prefer the pinned agents in `~/.claude/agents/` over `general-purpose` and `claude` — those
two are catch-alls with no model pin, so every call to them inherits the session model:

- `scout` (haiku) — locate a file/symbol/value, run a known command. Read-only.
- `reader` (sonnet) — read across files to answer a question or trace a flow. Read-only.
- `worker` (opus) — implement one specified change plus tests. The only one that writes.
- `reviewer` (opus) — adversarial review, security, checking another agent's output.
- `architect` (fable) — planning, trade-offs, debugging that resisted one attempt.

Reach for `general-purpose` only when the task genuinely fits none of these, and pass an
explicit `model` when you do.

## Orchestrator sessions

When the session model is expensive relative to the work (any Fable session), default to
orchestrating rather than doing. This is about routing, not capability — nothing is off
limits to the session, but the first question on any non-trivial task is "who should do
this" before "how do I do this".

- Delegate the gathering and the execution: searching, reading, tracing, running commands,
  and well-specified edits go to `scout`, `reader`, and `worker`.
- Keep the judgment: deciding what to delegate, writing the subagent prompts, evaluating
  what comes back, and synthesizing. `architect` is pinned to fable, so handing it a hard
  design or debugging question costs no quality and keeps the investigation out of your
  context. `reviewer` is opus and so is a downgrade from a Fable session — review in-session
  when the stakes justify it.
- Never `fork` from an expensive session. Forks ignore the `model` override and run at
  parent price; spawn a fresh agent instead.
- Delegation has a floor. A one-line edit or a single known file read costs less done
  directly than as a round trip. Delegate when the work involves volume, breadth, or
  output you do not want in context — not reflexively.
- Guard context deliberately: never pull a large file or a wide grep into the session to
  "have a look" when a subagent could read it and report the answer.

Notes:
- An agent definition's own `model:` frontmatter wins over inheritance; an explicit `model`
  on the Agent call wins over both.
- `subagent_type: "fork"` always runs on the parent's model — a `model` override is ignored.
  Don't fork off an expensive session for cheap work; spawn a fresh agent instead.
- Scale the count too: prefer 3 well-scoped agents over 10 speculative ones.
