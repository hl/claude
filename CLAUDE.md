The two lines below apply to the main session only. In a subagent, the agent's own system
prompt wins wherever it conflicts with them — if it tells you to stop on an ambiguity, stop.

Keep going without asking. Pick sane defaults, state assumptions, finish the task in one turn.
Fan out to subagents and agent teams by default for anything parallelizable — don't wait to be asked.

Every runner reads this file, including ones pointed at a non-Anthropic provider: it sits in
an ancestor `.claude/` directory, so it is loaded regardless of `CLAUDE_CONFIG_DIR`. It
therefore names no models and no config-dir paths. Per-runner specifics live in that runner's
own config dir.

## Orchestrator sessions

From an expensive session (on Anthropic, any Fable session), default to orchestrating rather
than doing. This is about routing, not capability — nothing is off limits, but the first
question on a non-trivial task is "who should do this" before "how do I do this". The point
is context: a subagent's tool output never enters your window, only its final report does.

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
