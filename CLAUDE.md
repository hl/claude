The two lines below apply to the main session only. In a subagent, the agent's own system
prompt wins wherever it conflicts with them — if it tells you to stop on an ambiguity, stop.

Keep going without asking. Pick sane defaults, state assumptions, finish the task in one turn.
Fan out to subagents and agent teams by default for anything parallelizable — don't wait to be asked.

## Delegating

Prefer the five agents in `~/.claude/agents/` over `general-purpose` and `claude`, which are
undifferentiated catch-alls:

- `scout` (haiku) — locate a file/symbol/value, run a known command.
- `reader` (sonnet) — read across files to answer a question or trace a flow.
- `worker` (inherits) — implement one specified change plus tests. The only one that writes.
- `reviewer` (inherits) — adversarial review, security, checking another agent's output.
- `architect` (inherits) — planning, trade-offs, debugging that resisted one attempt.

`scout` and `reader` are pinned low because depth buys nothing on mechanical and read-only
work. The other three inherit on purpose: writing code, reviewing it, and design decisions
are worth the session's best model, so inheriting is the right default and you do not need
to justify it per call.

Override `model` when latency matters, not to save money:

- Fanning out several agents at once — the batch finishes at the pace of its slowest member,
  and a Fable session at high effort is slow. Drop the ones doing shallower work to opus or
  sonnet so they don't hold up the rest.
- A task that is narrower than the agent it fits — a `worker` change that is genuinely
  mechanical, a `reviewer` pass over ten lines.

When a change is needed but its shape is not settled, do not hand it to `worker`: it will
stop and report the spec as under-specified, costing a round trip. Route it to `architect`
first, then pass that plan to `worker` as the spec.

Only `worker` has `Write`/`Edit`, but all five carry `Bash` — the others are read-only by
instruction, not by tooling. Strong default, not a guarantee.

## Orchestrator sessions

From an expensive session (any Fable session), default to orchestrating rather than doing.
This is about routing, not capability — nothing is off limits, but the first question on a
non-trivial task is "who should do this" before "how do I do this". The point is context:
a subagent's tool output never enters your window, only its final report does.

- Delegate the gathering and the execution: searching, reading, tracing, running commands,
  and well-specified edits.
- Keep the judgment: what to delegate, how to prompt it, whether the result is any good,
  and the synthesis.
- Never `fork` — forks ignore the `model` override and always run on the parent model.
  Spawn a fresh agent instead.
- Delegation has a floor. A one-line edit or a single known file read is cheaper done
  directly than as a round trip. Delegate for volume, breadth, or output you do not want
  in context — not reflexively.
- Never pull a large file or a wide grep into the session to "have a look" when a subagent
  could read it and report the answer.
- Prefer 3 well-scoped agents over 10 speculative ones.

Precedence: an explicit `model` at the call site beats the agent's `model:` frontmatter,
which beats inheriting the session model.
