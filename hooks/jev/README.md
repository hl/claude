# Jev hooks

These hooks use [Jev](https://docs.typesafe.ai) (TypeSafe AI) to make two decisions. Jev is a decision model: it takes typed questions and returns typed answers with probabilities, in about 0.3 s, and it does not generate text. The hooks use bash, jq and curl only.

- **Routing.** `route.sh` picks haiku, sonnet or opus for a subagent brief. It uses Claudette's tier definitions from `agents/claudette.md`, plus six signal questions. Claudette calls it as a CLI. `agent-route.sh` is a PreToolUse hook on `Agent`. By default it only logs the tier Jev would pick. As an opt-in, it can fill or raise the subagent's model through `updatedInput`.
- **Compaction.** Before a compaction, `compact-pre.sh` extracts candidate facts from the transcript: user messages, decision lines, files touched, URLs, branches, the last failing command, open TODOs, and facts an earlier compaction re-injected. Jev scores how much each one must survive. `compact-post.sh` asks Jev which of those facts the summary kept. After the compaction, `compact-session.sh` re-injects the important facts the summary dropped, as SessionStart `additionalContext`, listed in transcript order.

## Enable

1. Set `TYPESAFE_API_KEY` in the environment, or put an `export TYPESAFE_API_KEY=...` line in `~/.zshenv`.
2. The hooks are wired up in `settings.json`.

To turn everything off, set `JEV_DISABLED=1`.

## What leaves the machine

All of this is sent to `api.typesafe.ai` unredacted. Nothing is scrubbed for secrets.

- **Per compaction:**
  - up to about 40,000 characters of the transcript tail: user messages, assistant text, tool names with their commands or paths, and the first 400 characters of each tool result;
  - up to 60 extracted facts, which include URLs found in tool output;
  - the compaction summary, used for the coverage check.
- **Per routed Agent call:** the call's full `description`, `subagent_type` and `prompt`. This happens in every mode except `off`, so the default `log` mode sends it too.
- **Per `route.sh` call:** the brief text.

To send nothing, set `JEV_DISABLED=1`. To stop only the Agent hook, set `JEV_ROUTE_MODE=off`.

## Knobs

| Knob | Default | Effect |
|---|---|---|
| `JEV_DISABLED` | unset | `1` makes every hook and `route.sh` do nothing. |
| `TYPESAFE_API_KEY` | — | The API key. If unset, it is read from `JEV_ZSHENV`. |
| `JEV_ZSHENV` | `~/.zshenv` | File to read `export TYPESAFE_API_KEY=...` from. The hook takes the last such line and never evaluates it. |
| `TYPESAFE_BASE_URL` | `https://api.typesafe.ai` | API base URL. |
| `JEV_MODEL` | `jev-latest` | Jev model. |
| `JEV_TIMEOUT` | `8` s | curl `--max-time` for compaction calls. |
| `JEV_ROUTE_TIMEOUT` | `4` s | curl `--max-time` for agent-route calls. |
| `JEV_COOLDOWN` | `300` s | After a timeout, connection failure, 429 or 5xx, Jev calls from the same hook family fail fast for this many seconds. The stamps are per family, `$JEV_HOME/cooldown.route` (route.sh, agent-route) and `$JEV_HOME/cooldown.compact` (compaction hooks), so a slow routing call never switches off compaction help. `0` disables the cooldown. |
| `JEV_LONG_CONTEXT` | unset | `1` sends the long-context header up front (262k tokens, slower). The hooks also retry with it once on `max_tokens_exceeded`. |
| `JEV_CHARS_PER_TOKEN` | `4` | Characters per token assumed when sizing the state against the 32k-per-question limit. |
| `JEV_HOME` | `~/.claude/jev` | Location of state, logs and the cooldown stamps. |
| `JEV_ROUTE_MODE` | `log` | `log`: decide and log, change nothing. `fill`: set a model on model-less calls of allowlisted types, never below sonnet. `escalate`: like `fill`, and also raise an explicit haiku/sonnet/opus model, never lowering one. `off`: do nothing and send nothing. |
| `JEV_ROUTE_FILL_TYPES` | `general-purpose` | Agent types that `fill` may set a model on (comma-separated). A missing `subagent_type` counts as `general-purpose`. |
| `JEV_ROUTE_MIN_CONF` | `0.6` | Below this confidence, the tier goes up one step. |
| `JEV_ROUTE_SIGNAL_MIN` | `0.7` | A security/high-blast-radius or non-trivial-review signal at or above this forces opus. |
| `JEV_COMPACT_MAX_FACTS` | `60` | Cap on candidate facts. Facts carried from an earlier compaction (at most 30) are exempt from the recency cut. |
| `JEV_COMPACT_SPLIT` | `40` | Facts per Jev request. Above this, two requests run in parallel. |
| `JEV_COMPACT_TAIL_CHARS` | `40000` | Size of the transcript tail sent as context. It is also bounded by the token budget. |
| `JEV_COMPACT_MIN_SCORE` | `1.5` | Score threshold for injection ("important" or above, on a 0–3 scale). |
| `JEV_COMPACT_COVERED_MIN` | `0.5` | Jev probability at or above which a fact counts as kept by the summary. |
| `JEV_COMPACT_MAX_CHARS` | `9000` | Size cap for the injected context. Claude Code's hard limit is 10,000. |
| `JEV_COMPACT_MAX_AGE` | `3600` s | State older than this is ignored by the post and session hooks. |
| `JEV_COMPACT_GUARD` | unset | `1` blocks one auto-compaction per session when Jev rates the last turn as mid-operation. |
| `JEV_COMPACT_GUARD_MIN` | `0.85` | Mid-operation probability that triggers the guard. |

### Fill allowlist

A per-call model beats an agent's frontmatter model, and it beats `CLAUDE_CODE_SUBAGENT_MODEL`. So `fill` only sets a model where nothing is pinned:

- **Allowed:**
  - types listed in `JEV_ROUTE_FILL_TYPES`;
  - custom agents whose definition file was found and has no `model:` line. The file is found by its frontmatter `name:`, in `$CLAUDE_PROJECT_DIR/.claude/agents`, `<cwd>/.claude/agents` or `${CLAUDE_CONFIG_DIR:-~/.claude}/agents`.
- **Skipped:** anything unresolved, which includes plugin agents (`plugin:name`), agents defined via `--agents` or the SDK, and built-ins outside the list.
- **`CLAUDE_CODE_SUBAGENT_MODEL` set:** the hook never changes a model.

`fill` never sets haiku. A model-less call would otherwise have inherited the parent's model, so filling haiku could lower it. The hook returns only `updatedInput`, with no `permissionDecision`, so the normal permission flow and deny rules still apply.

## Logs and state

- **`~/.claude/jev/log/jev.jsonl`:** one line per API call, with status, ms, tokens and answers. No transcript text, no key.
- **`~/.claude/jev/log/route.jsonl`:** every Agent decision: action, mode, given/Jev/final model, confidence, signals, `fill_eligible`, the reason string (for example `jev: none→sonnet (jev haiku, conf 1.0, mechanical 0.96)`), and the first 120 characters of the description. When a mode other than `log` is on, this file is the only place that shows which model a subagent actually got. The parent session does not see it.
- **`~/.claude/jev/log/compact.jsonl`:** the pre, post and session steps.
- **`~/.claude/jev/compact/<session_id>.json`:** ranked facts, coverage and the consumed flag. It is keyed by session_id. Hooks fired with an `agent_id`, meaning a subagent compacting its own context, leave this file alone.

`~/.claude` is a public repo, but `.gitignore` ignores everything that isn't listed, so `jev/` is never committed.

## Failure mode

Every hook fails open. On a missing key, network failure, timeout, HTTP error or malformed answer, the hook exits 0 with no output and logs a status. Compaction and Agent calls go ahead untouched. After a timeout or connection failure, the cooldown makes later calls from the same hook family fail in milliseconds instead of costing another timeout each. `route.sh` exits non-zero on failure so that callers can fall back. The guard is the only hook that can block anything, and it is off by default.

## Observed hook order (Claude Code 2.1.302)

A manual `/compact` fires the hooks in this order (see `test/evidence/compact-order.txt`):

`PreCompact` → `SubagentStop` (agent_type `""`, the compaction agent; `last_assistant_message` is the summary) → `SessionStart` (source `compact`) → `PostCompact`.

`PostCompact` starts only after the SessionStart hooks have finished, and the transcript does not yet contain the new summary at that point. Coverage computed on `PostCompact` would therefore arrive too late for the injection.

For that reason, `compact-post.sh` also runs on the compaction agent's `SubagentStop`. Claude Code waits for that hook before SessionStart, and its summary is byte-identical to `compact_summary`. `live-compact.sh` asserts this on every run and records the summary length in `test/evidence/compact-*order.txt`. A reviewer run outside the committed evidence also saw a 6,978-char summary match. The `SubagentStop` pass acts only when all of these hold:

- `agent_type` is empty;
- the state is still pending from PreCompact;
- the message contains `<summary>`.

Prompt-suggestion agents also stop with an empty type, and they are ignored. When `PostCompact` later sees the same summary, it skips the API call. In either order, `compact-session.sh` uses coverage if it exists and falls back to the Jev ranking if it doesn't.

`updatedInput` on the Agent tool does change the subagent's model (see `test/evidence/agent-*.txt`):

- `fill` with no model: the subagent ran on sonnet (Jev said haiku; the floor applies).
- `escalate` with `haiku` on a security review: the subagent ran on `claude-opus-5-5`.

## Limits

- **Routing noise.** Jev answers are slightly nondeterministic and sensitive to wording. Run `test/route-eval.sh` with `EVAL_RUNS=3` after changing any question text.
- **Coverage noise.** Coverage is best effort. On a 474-char one-line summary, Jev marked two facts as missing that the summary did state. This is known noise, and it is not tuned on that one sample. The cost is bounded over-injection, never loss.
- **Heuristic extraction.** Facts come from regexes over the records after the last `compact_boundary`. The transcript may lag at PreCompact, so the newest turn can be missing. Typed slash commands are skipped: a bare `/word`, or `/word args` on a record without `promptSource`. A message such as "/tmp is full" is kept.
- **No summary changes.** The hooks cannot change the summary itself; they can only add context after it.
- **Subagent compaction window.** SubagentStop cannot filter on `agent_id`, because the parent's compaction agent has one too. A background subagent's own compaction agent that stops with a `<summary>` while the parent's PreCompact is pending (a window of seconds) could claim the parent's state. The worst case is coverage computed against the wrong summary, which means extra facts are re-injected. This has not been seen live.
- **Agent lookup cost.** Finding a custom agent by frontmatter `name:` runs one awk per agent file, about 2 ms each (266 ms with 101 files). This only happens for model-less calls whose type is neither allowlisted nor `plugin:name`.
- **Guard caveat.** If the auto-compaction is recovering from an API context-limit error, blocking it makes that request fail. The guard therefore fires at most once per session, and only on `auto`.

## Tests

`test/run.sh` runs the offline tests, then the API tests if a key is present. With `JEV_LIVE=1` it also drives real sessions, using `claude -p` and a tmux `/compact`, and refreshes `test/evidence/`. The live compact test injects custom instructions by default so that the injection path runs. `JEV_LIVE_COMPACT_ARGS=""` runs a plain `/compact`, where "nothing injected" is a pass. Add `JEV_EVIDENCE_TAG=plain` to write that run to `test/evidence/compact-plain-*`. `test/evidence/route-eval.txt` holds an `EVAL_RUNS=3` eval run.
