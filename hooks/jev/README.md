# Jev hooks

Hooks that use [Jev](https://docs.typesafe.ai) (TypeSafe AI) to make two decisions. Jev is a decision model: it takes typed questions and returns typed answers with probabilities, in about 0.3 s. It does not generate text. The hooks use bash, jq and curl only.

- **Routing.** `route.sh` picks haiku, sonnet or opus for a subagent brief. It uses Claudette's tier definitions from `agents/claudette.md`, with six signal questions alongside. `agent-route.sh` is a PreToolUse hook on `Agent` that sets the subagent's model through `updatedInput`.
- **Compaction.** Before a compaction, `compact-pre.sh` pulls candidate facts out of the transcript. These are user messages, decision lines, files touched, URLs, branches, the last failing command and open TODOs. Jev scores how much each fact must survive. `compact-post.sh` asks Jev which facts the summary kept. After the compaction, `compact-session.sh` re-injects the important facts the summary dropped, as SessionStart `additionalContext`.

## Enable

Set `TYPESAFE_API_KEY` in the environment. If it isn't set there, the hooks read it from an `export TYPESAFE_API_KEY=...` line in `~/.zshenv`. The hooks are wired up in `settings.json`. To turn everything off, set `JEV_DISABLED=1`.

| Knob | Default | Effect |
|---|---|---|
| `JEV_ROUTE_MODE` | `fill` | `fill`: set a model only when the Agent call has none. `escalate`: also raise a lower haiku/sonnet/opus model, never lower one. `log`: decide and log only. `off`: do nothing. |
| `JEV_ROUTE_MIN_CONF` | `0.6` | Below this confidence the tier goes up one step. |
| `JEV_ROUTE_SIGNAL_MIN` | `0.7` | A security/high-blast-radius or non-trivial-review signal at or above this forces opus. |
| `JEV_ROUTE_SKIP_TYPES` | `fork,Explore,claude-code-guide,statusline-setup` | Agent types that are never filled. Custom agents whose frontmatter sets `model:` are skipped too. |
| `JEV_ROUTE_TIMEOUT` / `JEV_TIMEOUT` | `4` / `8` s | curl `--max-time` for routing / compaction calls. |
| `JEV_COMPACT_MIN_SCORE` | `1.5` | Score threshold for injection ("important" or above, on a 0–3 scale). |
| `JEV_COMPACT_MAX_FACTS` / `JEV_COMPACT_SPLIT` | `60` / `40` | Cap on candidate facts, and the number of facts per Jev request. Above the split, two requests run in parallel. |
| `JEV_COMPACT_MAX_CHARS` | `9000` | Size cap for the injected context. Claude Code's hard limit is 10,000. |
| `JEV_COMPACT_GUARD` | off | `1` blocks one auto-compaction per session when Jev rates the last turn mid-operation (≥ `JEV_COMPACT_GUARD_MIN`, 0.85). |
| `JEV_LONG_CONTEXT` | off | `1` sends the long-context header up front. The hooks also retry with it once on `max_tokens_exceeded`. |
| `JEV_HOME` | `~/.claude/jev` | Location of state and logs. |

## Logs and state

- `~/.claude/jev/log/jev.jsonl`: one line per API call, with status, ms, tokens and answers. No transcript text and no key.
- `~/.claude/jev/log/route.jsonl`: every routing decision, with action, models, confidence, signals and the first 200 characters of the description.
- `~/.claude/jev/log/compact.jsonl`: the pre, post and session steps.
- `~/.claude/jev/compact/<session_id>.json`: the ranked facts, coverage and the consumed flag.

`~/.claude` is a public repo, but `.gitignore` ignores everything that isn't listed, so `jev/` is never committed.

## Failure mode

Every hook fails open. If there is no key, no network, a timeout, an HTTP error or a malformed answer, the hook exits 0 with no output and logs a status line. Compaction and Agent calls go ahead untouched. `route.sh` exits non-zero on failure so that callers can fall back to their own choice. The only hook that can block anything is the guard, and it is off by default.

## Observed hook order (Claude Code 2.1.302)

A manual `/compact` fires the hooks in this order (`test/evidence/compact-order.txt`):

`PreCompact` → `SubagentStop` (agent_type `""`, the compaction agent; `last_assistant_message` is the summary) → `SessionStart` (source `compact`) → `PostCompact`.

`PostCompact` starts only after the SessionStart hooks have finished. The transcript does not yet contain the new summary at that point. Coverage computed on `PostCompact` therefore arrives too late to shape the injection. For this reason `compact-post.sh` also runs on the compaction agent's `SubagentStop`. Claude Code awaits that hook before SessionStart, and its summary is byte-identical to `compact_summary`. The `SubagentStop` pass acts only when all of these hold: `agent_type` is empty, the state is still pending from PreCompact, and the message contains `<summary>`. Other internal agents with an empty type also stop, before and after compaction, and are ignored. When `PostCompact` later sees the same summary, it skips the API call. In either order, `compact-session.sh` uses coverage when it exists and falls back to the Jev ranking when it doesn't.

`updatedInput` on the Agent tool does change the subagent's model. The evidence is in `test/evidence/agent-*.txt`: with no model given, fill mode ran the subagent on `claude-haiku-5-5`. In escalate mode, a call with `haiku` ran on `claude-opus-5-5`.

## Limits

- Jev answers are slightly nondeterministic and sensitive to wording. Run `test/route-eval.sh` (with `EVAL_RUNS=3`) after changing any question text.
- Fact extraction is heuristic: regexes over the transcript records after the last `compact_boundary`. The transcript may lag at PreCompact, so the newest turn can be missing.
- The hooks cannot change the summary itself. Claude Code offers no way to do that. They can only add context after it.
- The guard has a caveat. If the auto-compaction is a recovery from an API context-limit error, blocking it makes that request fail. The guard therefore fires at most once per session and only on `auto`.
- In fill mode, `agent-route.sh` overrides the frontmatter model of built-in agent types that aren't in `JEV_ROUTE_SKIP_TYPES`, because a per-call model wins over frontmatter. It also returns `permissionDecision: "allow"` for the Agent calls it changes.

## Tests

Run `test/run.sh`. It runs the offline tests, then the API tests if a key is present. Set `JEV_LIVE=1` to also drive real sessions, using `claude -p` and tmux `/compact`. The live tests refresh `test/evidence/`.
