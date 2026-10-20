# Jev hooks

These hooks use [Jev](https://docs.typesafe.ai) (TypeSafe AI) to help long Claude Code sessions in two ways: they pick the model for a subagent, and they keep the facts that compaction would lose. Jev is a decision model. It takes typed questions and returns typed answers with probabilities in about 0.3 s, and it does not generate text. The hooks use only bash, jq and curl.

The loss they optimise is wasted work, not spend. Wasted work means a retry after a too-light model, research done twice, or a session that forgets a correction after compaction. So routing is opus-first. Jev is asked only where its answer can change something, and never on a routine turn.

## What calls Jev, and when

Jev is called only in **Claudette sessions**, meaning sessions whose `$CLAUDE_PROJECT_DIR` has an `.orchestrator.md`, or anywhere if `JEV_SCOPE=all` is set. Everything else is local and works in every session.

| What | When it calls Jev | Requests |
|---|---|---|
| `route.sh` (CLI, Claudette runs it) | each time it is run | 1 |
| `agent-route.sh` (PreToolUse `Agent`) | an explicit `haiku` or `sonnet` whose prompt carries no route id | 1 per such spawn, else 0 |
| `compact-pre.sh` (PreCompact) | every compaction | 1 |
| `compact-post.sh` (SubagentStop / PostCompact) | once per compaction, on whichever event sees the summary first | 1 |
| `artifact-hook.sh`, `compact-session.sh`, `artifact.sh`, the daily sweep | never | 0 |

A turn with no Agent spawn and no compaction sends nothing. `test/zero-traffic.sh` checks this. It replays 10 turns, 3 Agent spawns and a compaction through every Jev hook wired in `settings.json`, and expects 0 requests in an ordinary project. In a Claudette project it expects 3 requests, all from spawns and compaction.

```
Claudette ──▶ route.sh --context '{…}' "<brief>" → {id, model, reviewer_model, …} ──▶ brief carries "Route: <id>"
Agent call ──PreToolUse──▶ agent-route.sh: route id? → take route.sh's answer (no call); explicit haiku/sonnet? → Jev
           ──PostToolUse─▶ artifact-hook.sh: "Subagent ran on <model>." [+ "Subagent result (…) saved to <path>"]
/compact or auto ──PreCompact──▶ compact-pre.sh: extract facts, Jev scores them (1 request) → compact/<session>.json
                 ──SubagentStop (compaction agent)──▶ compact-post.sh: Jev "summary keeps fact N?" (1 request)
                 ──SessionStart(compact)──▶ compact-session.sh: live .orchestrator.md sections > artifact index > uncovered facts
                 ──PostCompact──▶ compact-post.sh (skips: already covered)
```

## Enable, scope, disable

Set `TYPESAFE_API_KEY` in the environment, or put an `export TYPESAFE_API_KEY=...` line in `~/.zshenv`. The hooks are already wired in `settings.json`. State lives in `$JEV_HOME`, which defaults to `${XDG_STATE_HOME:-~/.local/state}/jev`. Nothing writes into `~/.claude`.

- `JEV_SCOPE=all`: the Jev-calling hooks act in every session, not only Claudette sessions.
- `JEV_DISABLED=1`: every hook does nothing and `route.sh` exits 3. `artifact.sh` still writes the file it was asked to write.
- `JEV_ROUTE_MODE=off`: only the Agent hook is off.
- `JEV_ARTIFACTS=0`: only the automatic saving of subagent results is off. The "ran on" line stays.

## What leaves the machine

Every request goes to `api.typesafe.ai`. Each request body passes through `redact.jq` inside `jev_call` first, so no caller can skip redaction. It removes:

- API keys and tokens from the common providers, JWTs, and `Authorization` and `Cookie` headers;
- `KEY=value` and JSON or YAML pairs whose name says key, token, secret, password, passphrase or credential;
- credentials in URLs and in `curl -u`, `--password` and `mysql -p`;
- signed query values, PEM private keys, email addresses and IPv4 addresses.

`test/redact.sh` plants 51 secrets and checks every captured request body.

What is sent:

- **`route.sh`:** the brief, minus lines that name a tier, and its `--context`.
- **Agent hook:** the `description`, `subagent_type` and `prompt` of an explicit haiku or sonnet spawn that has no route id.
- **Compaction:** up to 60 facts extracted from the transcript since the last compaction (user messages, decision lines, paths, URLs, branches, the failing command, open items), and up to about 40,000 characters of the transcript tail. Then the `<summary>` part of the compaction summary, together with the same facts.

Artifacts and `.orchestrator.md` are never sent.

Redaction does not catch proprietary code, customer names or business logic. In an employer repo where Claudette runs, briefs, unrouted Agent prompts and compaction text do leave the machine. To keep a repo fully local, set `JEV_DISABLED=1` in its `.claude/settings.local.json` `env`.

## Routing

`route.sh [--context '<json>'] "<brief>"` (or the brief on stdin) prints:

```json
{"id": "r1792491674-30786-23727", "model": "opus", "reviewer_model": "opus", "confidence": 0.79,
 "probabilities": {"haiku": 0, "sonnet": 0.21, "opus": 0.79}, "policy": ["opus: default (P(opus) 0.79)"]}
```

All `--context` fields are optional:

- `attempt`, `prior_model`, `prior_outcome` ("thin", "wrong", "review FAIL x2");
- `files_hint` (a count or a list), `paths`, `diff_size`;
- `kind`: `implement`, `review`, `investigate`, `fix-ci`, `address-comments`, `poll`, `fetch` or `lookup`.

Lines of the brief that already name a tier (`Model: sonnet — …`, `jev: opus/opus …`) are dropped before Jev sees the brief (`anchors.jq`). Each call is logged with its id and context, but not the brief, to `log/route.jsonl`.

The policy (`policy.jq`) is a single decision, and it starts from opus:

- **opus** is the default. It is always the answer when the security/blast-radius signal or the non-trivial-review signal is 0.7 or higher.
- **haiku** is chosen for `kind` poll, fetch or lookup. It is also chosen when P(haiku) ≥ 0.85, mechanical ≥ 0.7 and security < 0.5.
- **sonnet** is chosen only when P(opus) ≤ 0.15 and neither signal reaches 0.5.
- Floors, which can only raise the tier:
  - A retry (`attempt` ≥ 2, or a prior outcome of thin, wrong or fail) goes one tier above the previous attempt.
  - `investigate` and `fix-ci` get at least sonnet.
  - 5 or more files rule out haiku, and 12 or more mean opus.
  - Paths under auth, payments, migrations, infra, CI, hooks or `.claude` count as security 1.0.
- `reviewer_model` is at least the implementer's tier and at least sonnet. It is opus when the change is non-trivial or the security signal is 0.5 or higher.

Evidence (`test/evidence/route-eval-real.txt`, `route-eval.txt`):

- **Real set** (451 Agent tasks from local transcripts, labelled blind):
  - 0 of 114 opus tasks routed lower, and 0 of 186 sonnet tasks routed to haiku.
  - Over-routing is 67.6%.
- **Replay of the stored Jev answers** (9,914 answers, 22 runs):
  - 0 under-routed, both at the nominal values and with every value moved 0.1 toward the cheaper tier.
  - Over-routing is 67.2%. The v2 policy over-routed 46.5% on the same answers.
- **Committed 36-task fixture:** 0 under-routed, with 56–58% over-routed.

The real set was deleted after that run, because raw briefs from work repos are not kept. `route-eval.sh` now uses the fixture, or `JEV_EVAL_SET=<file>`.

### The Agent hook

`agent-route.sh` runs in Claudette sessions only. It can raise a model and never lowers one. It sends nothing when nothing could change. These calls are left alone and only logged:

- no model given (frontmatter and inherit semantics stay);
- `opus`, a full model ID, `fable` or `inherit`;
- `subagent_type` `fork`, or a plugin agent (`x:y`);
- any call while `CLAUDE_CODE_SUBAGENT_MODEL` is set.

When the prompt or description carries a route.sh id (`r<epoch>-<pid>-<n>`, written as `Route: <id>` or `jev: <id>`), Claudette has already decided. The hook looks up that id in `route.jsonl` and raises the model to route.sh's answer if the given model is lower. It never scores the brief a second time.

Only an explicit haiku or sonnet with no route id is sent to route.sh, and it is raised when route.sh picks a higher tier. The hook returns only `updatedInput`, with no `permissionDecision`.

`artifact-hook.sh` then gives the parent a one-line note:

- `Subagent ran on <resolvedModel>.`;
- `… (raised from haiku by the Jev Agent hook).` when the Agent hook raised the model;
- `Background subagent running on <model>.` for a background agent.

This was verified live in `test/evidence/agent-scope.txt`: in a plain project the haiku ran on haiku with 0 Jev calls, and in a Claudette project the same call ran on opus with 1 call. In both, the parent quoted the line back.

## Compaction

`compact-pre.sh` reads the records after the last compact boundary and extracts candidate facts with `extract.jq`. Facts that an earlier compaction re-injected are carried forward. It then asks Jev, in one request, how much each fact must survive. The same request asks whether the last turn is mid-operation.

On the compaction agent's SubagentStop, `compact-post.sh` asks, in one request, which facts the summary kept. PostCompact sees the same summary and skips.

`compact-session.sh` injects up to 9,000 characters, in priority order:

1. the heading, first line and Status line of each live `.orchestrator.md` section (sections marked DONE or BLOCKED are left out);
2. the artifact index;
3. the facts scored important or higher that the summary dropped, in transcript order, plus the path of the full list.

Parts 1 and 2 need neither Jev nor a state file, so they work in any session, and also when Jev is down.

The compaction guard is opt-in. With `JEV_COMPACT_GUARD=1`, `compact-pre.sh` blocks one auto-compaction per session (exit 2) when the last turn is mid-operation with p ≥ 0.85. It never blocks a manual `/compact`, and never blocks twice. It stays off by default because a hook cannot tell a routine auto-compaction from one that is recovering from a context-limit error.

## Artifacts

`artifact-hook.sh` saves every subagent reply whose first line is `Artifact: <name>`, as `<name>.md`, whatever its length. It also saves every other result longer than 2,000 characters, as `agent-<n>-<slug>-<agentId>.md`.

Files go to `$JEV_HOME/artifacts/<session_id>/` and are cut at 512 KB. Foreground agents are saved on PostToolUse, and the parent is told the path. Background agents are saved on SubagentStop and appear in the artifact index after compaction.

`artifact.sh <name> [--from-file <path>] [--session <id>]` does the same by hand. The session comes from `--session`, `$CLAUDE_CODE_SESSION_ID` or `$CLAUDE_SESSION_ID`.

## Observed payloads (Claude Code 2.1.302 and 2.1.304)

- **PostToolUse on Agent, foreground:**
  - `tool_response` has `status: "completed"`, `agentId`, `resolvedModel` (the model that ran), and the report.
  - The report is in `content[]` (2.1.302) or in `handbackReport.text` (2.1.304).
  - `additionalContext` reaches the parent.
- **PostToolUse on Agent, background:** `status: "async_launched"` with `resolvedModel`, and no result.
- **SubagentStop:**
  - The payload has `agent_id`, `agent_type`, `agent_transcript_path` and `background_tasks`.
  - 2.1.304 leaves out `last_assistant_message` for agents that hand back, so the hooks read the transcript.
- **Compaction:** PreCompact → SubagentStop (`agent_type` `""`, whose `last_assistant_message` is the summary) → SessionStart(`compact`) → PostCompact (`test/evidence/compact-order.txt`).

## Knobs

| Knob | Default | Effect |
|---|---|---|
| `JEV_DISABLED` | unset | `1`: every hook does nothing; `route.sh` exits 3. |
| `JEV_SCOPE` | unset | `all`: the Jev-calling hooks act outside Claudette sessions too. |
| `TYPESAFE_API_KEY` / `JEV_ZSHENV` | — / `~/.zshenv` | The key, or the file to read `export TYPESAFE_API_KEY=...` from (never evaluated). |
| `TYPESAFE_BASE_URL`, `JEV_MODEL` | `https://api.typesafe.ai`, `jev-latest` | API base URL and model. |
| `JEV_HOME` | `${XDG_STATE_HOME:-~/.local/state}/jev` | State and logs. |
| `JEV_RETAIN_DAYS` | `30` | The daily sweep deletes compaction state and artifact directories untouched this long. |
| `JEV_TIMEOUT` / `JEV_ROUTE_TIMEOUT` | `8` s / `4` s | curl `--max-time` (`JEV_TIMEOUT` for compaction and the route.sh CLI, `JEV_ROUTE_TIMEOUT` for the Agent hook). |
| `JEV_COOLDOWN` | `300` s | After a timeout, connection failure, 429 or 5xx, calls from the same family (`cooldown.route`, `cooldown.compact`) fail fast for this long. |
| `JEV_LONG_CONTEXT`, `JEV_CHARS_PER_TOKEN` | unset, `4` | Long-context header up front (retried once on `max_tokens_exceeded` anyway); chars per token for sizing. |
| `JEV_ROUTE_MODE` | `escalate` | `off` turns the Agent hook off. |
| `JEV_ROUTE_NO_LOG` | unset | `1`: route.sh does not log (the Agent hook and the eval set it). |
| `JEV_ARTIFACTS`, `JEV_ARTIFACT_MIN_CHARS`, `JEV_ARTIFACT_MAX_BYTES` | `1`, `2000`, `524288` | Automatic saving; length threshold; per-file cap. |
| `JEV_COMPACT_MAX_FACTS`, `JEV_COMPACT_TAIL_CHARS` | `60`, `40000` | Facts scored per compaction (most recent kept); transcript tail sent. |
| `JEV_COMPACT_MIN_SCORE`, `JEV_COMPACT_COVERED_MIN` | `1.5`, `0.5` | Score that counts as important; probability at which the summary keeps a fact. |
| `JEV_COMPACT_MAX_CHARS`, `JEV_COMPACT_ORCH_MAX`, `JEV_COMPACT_ARTIFACT_MAX` | `9000`, `4500`, `2000` | Injection caps: total, `.orchestrator.md` part, artifact index. |
| `JEV_COMPACT_MAX_AGE` | `3600` s | Older compaction state is ignored. |
| `JEV_COMPACT_GUARD`, `JEV_COMPACT_GUARD_MIN` | unset, `0.85` | The opt-in guard above. |

## Logs and state

Everything is under `$JEV_HOME`:

- `log/jev.jsonl` has one line per API call, with the hook, session, status, ms, tokens and answers. It holds no text and no key.
- `log/route.jsonl` holds:
  - route.sh calls (`action: route`, with id and context);
  - Agent-hook decisions (`escalated`, `raised_to_route`, `kept`, `kept_routed`, `kept_opus`, `skip_*`, `route_failed`);
  - `ran` records (`resolved_model` per Agent call).
- `log/compact.jsonl` and `log/artifact.jsonl` have one line per step.
- `compact/<session_id>.json` holds the scored facts, coverage and the consumed flag.
- `artifacts/<session_id>/` holds the saved artifacts.

The first local hook run of each day sweeps the state. It deletes files untouched for 30 days and trims logs over 5 MB. It also deletes what v2 kept: `sessions/`, `tune/` and `eval/`, which held raw briefs harvested from work repos.

## Failure mode and latency

Every hook fails open. On a missing key, a network failure, a timeout, an HTTP error or a malformed answer, it exits 0 with no output and logs a status. `route.sh` and `artifact.sh` exit non-zero, so callers can fall back; for route.sh the fallback is opus.

Latency (`test/latency.sh`, Jev p50 ≈ 0.23 s):

| Hook | Time |
|---|---|
| agent-route with a Jev call | ≈ 0.73 s |
| agent-route outside a Claudette session | ≈ 0.06 s |
| agent-route with no call needed | ≈ 0.14 s |
| compact-pre | ≈ 0.6 s |
| compact-post | ≈ 0.55 s |
| compact-session | ≈ 0.15 s |
| artifact-hook | ≈ 0.17 s |

## Limits

- **Over-routing is deliberate and large.** About two thirds of the real tasks run a tier above the blind label. Most of that is sonnet work done on opus, and haiku is rare unless the brief says `kind: poll`, `fetch` or `lookup`. On the stored answers, no opus task came near a lower tier, even with a 0.1 margin. The labels come from one labeller, and 30% of the briefs named their tier.
- **The scope is a file.** A Claudette session with no `.orchestrator.md` yet (before her first report) is out of scope. The Agent hook then does nothing, and compaction re-injects only the artifact index. `route.sh` still works, because it is run explicitly.
- **Egress in Claudette repos.** See "What leaves the machine": redaction is not an NDA.
- **Coverage noise.** Jev sometimes marks a kept fact as missing. The cost is bounded over-injection, never loss.
- **Heuristic extraction.** Facts come from regexes over transcript records, and a fact is a whole message. A correction is injected next to what it corrects, in transcript order, not in its place. A message that is later partly corrected can be scored down as a whole. In the live test, Jev scored the original "pg-staging-7, never run migrations, branch …" message 1.3 once it had been corrected, so its other facts were not re-injected. Only the correction and the `.orchestrator.md` section came back.
- **Background subagents** are saved, but the parent learns the path only from the next compaction's index.
- **The hooks cannot change the summary**; they can only add context after it.
- **One state location.** Hooks and the Bash tool each work out `$JEV_HOME` from their own environment. Set `XDG_STATE_HOME` and `JEV_HOME` in one place that both read, or leave them unset.

v3 removed the per-turn ledger (Stop hook), autotune, `outcome.sh`, the tuned-thresholds file, route.sh's `deepen` output and the `jev:` telemetry rule. In v2 the ledger made about 90% of the Jev calls, while a compaction happened about once every two days.

## Tests

`test/run.sh` runs the offline tests first: `offline.sh`, `offline-hooks.sh`, `zero-traffic.sh` and `redact.sh`. If a key is present, it then runs the API tests: `route-eval.sh`, `agent-route-api.sh`, `compact-fixture.sh` and `latency.sh`.

With `JEV_LIVE=1`, it also drives real sessions:

- `live-agent.sh`, a `claude -p` run with and without `.orchestrator.md`;
- `live-artifact.sh`, a `claude -p` run in auto mode;
- `live-compact.sh`, a `/compact` driven in tmux.

Every test uses its own `JEV_HOME`. Tests rewrite `test/evidence/` only under `JEV_LIVE=1` or `JEV_EVIDENCE=1`.
