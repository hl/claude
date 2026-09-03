The two lines below apply to the main session only. In a subagent, the agent's own system
prompt wins wherever it conflicts with them — if it tells you to stop on an ambiguity, stop.

Keep going without asking. Pick sane defaults, state assumptions, finish the task in one turn.
Fan out to subagents and agent teams by default for anything parallelizable — don't wait to be asked.

## Pick the model for each subagent

Unless the agent's own frontmatter pins one, a subagent runs on the session's model and
effort. Inheriting is usually wrong: six agents fanned out from a Fable session are six
Fable sessions. Effort follows the resolved model — `settings.json` binds high effort to
fable specifically, so this bites from a Fable session and not from an Opus one, where
unpinned agents run at the medium session default. Choose per agent:

- `haiku` — mechanical, well-specified work: file/symbol lookups, running a known command,
  bulk renames, collecting output, formatting.
- `sonnet` — read-only investigation: focused searches, reading and summarizing, tracing a
  flow, reading upstream docs.
- `opus` — anything that writes code, plus genuinely hard work: implementation and tests,
  architecture and planning, debugging that resisted one attempt, security review, review
  of others' output.
- `fable` — the deepest thinking only. Nothing structurally prevents a Fable session from
  fanning out into Fable subagents; the three unpinned agents inherit it by default, so
  naming a cheaper `model` at the call site is the only thing that stops it.

Prefer the five agents in `~/.claude/agents/` over `general-purpose` and `claude`, which are
undifferentiated catch-alls with full tool access. Only `worker` has `Write`/`Edit`; the
other four are read-only by instruction, not by tooling — they all carry `Bash`, so their
boundary is a prompt they could disregard, not a gate. Treat it as a strong default, not a
guarantee:

- `scout` (haiku) — locate a file/symbol/value, run a known command. Read-only.
- `reader` (sonnet) — read across files to answer a question or trace a flow. Read-only.
- `worker` (inherits) — implement one specified change plus tests. The only one that writes.
- `reviewer` (inherits) — adversarial review, security, checking another agent's output.
- `architect` (inherits) — planning, trade-offs, debugging that resisted one attempt.

`scout` and `reader` are pinned so their cost and latency stay fixed no matter which session
spawns them — mechanical work gains nothing from a deeper model.

When a change is needed but its shape is not settled, do not hand it to `worker`: it will
stop and report the spec as under-specified, costing a round trip. Route it to `architect`
first, then pass that plan to `worker` as the spec. The other three deliberately inherit, so **pass an explicit `model` every
time you spawn one** — decide how hard the task actually is rather than letting the session
model decide for you. Same when you reach for `general-purpose`, which fits only tasks none
of the five cover.

## Orchestrator sessions

When the session model is expensive relative to the work (any Fable session), default to
orchestrating rather than doing. This is about routing, not capability — nothing is off
limits to the session, but the first question on any non-trivial task is "who should do
this" before "how do I do this".

- Delegate the gathering and the execution: searching, reading, tracing, running commands,
  and well-specified edits go to `scout`, `reader`, and `worker`.
- Keep the judgment: deciding what to delegate, writing the subagent prompts, evaluating
  what comes back, and synthesizing.
- `worker`, `reviewer`, and `architect` inherit, so from a Fable session they arrive at full
  Fable-high price. Name a `model` on every one: match the session only when the task truly
  needs that depth, and drop to opus or sonnet when it does not.
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
- Scale the count too: prefer 3 well-scoped agents over 10 speculative ones.
