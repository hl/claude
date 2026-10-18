# Jev hooks

These hooks use [Jev](https://docs.typesafe.ai) (TypeSafe AI) for two jobs in long Claude Code sessions: pick the model for each subagent, and keep the state that compaction would lose. Jev is a decision model: it takes typed questions and returns typed answers with probabilities, in about 0.3 s, and it does not generate text. The hooks use bash, jq and curl only.

The loss they optimise is wasted work, not spend: a retry after under-routing, research done twice, and a session that forgets a correction after compaction. A higher tier and a Jev call per turn are cheap by comparison.

- **Routing.** `route.sh` picks haiku, sonnet or opus for a brief, plus a reviewer model and whether to investigate first. The tier is opus unless Jev is confident a lower one suffices; the thresholds were tuned on 451 real Agent calls from local transcripts, labelled blind. `agent-route.sh` (PreToolUse on `Agent`) raises an explicit `haiku`/`sonnet` when Jev is sure it falls short.
- **Ledger.** `ledger.sh` (Stop) reads each new turn, scores candidate facts and notes which earlier facts they correct, into a per-session ledger.
- **Compaction.** `compact-pre.sh` flushes the ledger, `compact-post.sh` checks which facts the summary kept, and `compact-session.sh` re-injects the live `.orchestrator.md` sections, the artifact index and the facts the summary dropped.
- **Artifacts.** `artifact.sh` saves a deliverable to disk and indexes it; `artifact-hook.sh` saves every subagent result over 2,000 chars automatically.

## How it fits together

```
every turn ──Stop──▶ ledger.sh ── new transcript lines since the cursor
                        │           extract.jq → candidates → Jev: score + "corrects fact M?"
                        ▼
              ~/.claude/jev/ledger/<session>.jsonl   (facts; superseded_by / corrected_by)
                        ▲                                      ▲
artifact.sh / ──────────┘ "artifact" facts                     │
artifact-hook.sh ─▶ ~/.claude/jev/artifacts/<session>/*.md     │
                                                               │
/compact or auto ──PreCompact──▶ compact-pre.sh: ledger flush, snapshot of live facts ─┐
                 ──SubagentStop (compaction agent)──▶ compact-post.sh: Jev "summary keeps fact N?" (coverage)
                 ──SessionStart(compact)──▶ compact-session.sh: inject, ≤ 9,000 chars:
                        (c) live .orchestrator.md sections  >  (b) artifact index  >  (a) uncovered live facts
                        + where the ledger and artifacts live
                 ──PostCompact──▶ compact-post.sh (skips if the SubagentStop pass covered it)

Agent call ──PreToolUse──▶ agent-route.sh ─▶ route.sh ─▶ Jev ─▶ policy.jq ─▶ maybe updatedInput.model
           ──PostToolUse──▶ artifact-hook.sh ─▶ "Subagent result (<description>) saved to <path>"
Claudette ──▶ route.sh --context '{…}' → model, reviewer_model, deepen, id ──▶ outcome.sh <id> when done
```

## Enable

1. Set `TYPESAFE_API_KEY` in the environment, or put an `export TYPESAFE_API_KEY=...` line in `~/.zshenv`.
2. The hooks are wired up in `settings.json`: Stop (`ledger.sh`), PreToolUse/PostToolUse on `Agent`, SubagentStop, PreCompact, PostCompact and SessionStart `compact`.

`JEV_DISABLED=1` turns everything off. `JEV_LEDGER=0` turns off only the ledger (compaction falls back to v1 extraction), `JEV_ROUTE_MODE=off` only the Agent hook, `JEV_ARTIFACTS=0` only the automatic artifact saving.

## What leaves the machine

Everything goes to `api.typesafe.ai`, and every request body passes through `redact.jq` inside `jev_call` first, so no caller can skip it. Redacted: API keys and tokens (`sk-…`, `apik…`, `ghp_…`/`github_pat_…`, `glpat-…`, `xox?-…`, `AKIA…`/`ASIA…`, `AIza…`), JWTs, `Authorization:` headers and bare bearer tokens, `KEY=value` / `"key": value` where the name contains key, token, secret, password or credential, long hex/base64 runs after a key-ish word, credentials in URLs, signed query values (`X-Amz-Signature`, `token=`, `sig=`, …), PEM private keys, email addresses (`<email>`) and IPv4 addresses (`<ip>`). Paths, hostnames, git remotes and PR links are kept: they are the facts worth preserving. `test/redact.sh` plants 18 secrets in every hook's input and checks the captured request bodies (`test/evidence/redaction.txt`).

- **Every turn (Stop):** the new candidate facts of that turn (user messages, decision lines, paths, URLs, branches, the failing command, open items), up to 20,000 characters of that turn's transcript text, and the 40 most recent ledger facts.
- **Every compaction:** the compaction summary and the facts being checked against it. In v1 mode (no ledger), up to 40,000 characters of the transcript tail and up to 60 extracted facts, as before.
- **Every Agent call** (all modes except `off`): its `description`, `subagent_type` and `prompt`.
- **Every `route.sh` call:** the brief and its `--context`.

Nothing is sent for artifacts, the artifact index or `.orchestrator.md`.

## Routing

`route.sh [--context '<json>'] "<brief>"` (or the brief on stdin) prints:

```json
{"id": "r1792…", "model": "opus", "reviewer_model": "opus", "deepen": true,
 "policy": ["opus: P(opus) 0.92 > 0.4", "retry (attempt 2, thin): one tier above sonnet"],
 "confidence": 0.79, "probabilities": {…}, "signals": {…}, "above": {"haiku": 1, "sonnet": 0.92}, …}
```

`--context` fields, all optional: `attempt`, `prior_model`, `prior_outcome` ("thin", "wrong", "review FAIL x2"), `files_hint` (a count or a list), `paths`, `kind` (`implement`, `review`, `investigate`, `fix-ci`, `address-comments`, `poll`), `diff_size`. Jev sees `{task, context}`.

Policy (`policy.jq`, shared with `tune.sh`):

- **haiku** when P(haiku) ≥ 0.5, ambiguous ≤ 0.9 and the security/blast-radius and non-trivial-review signals are below 0.7;
- **sonnet** when P(opus) ≤ 0.4 and the same two signals are below 0.7;
- **opus** otherwise.
- Then: a retry (attempt ≥ 2, or a prior outcome of thin/wrong/fail) goes at least one tier above the previous attempt; `investigate` and `fix-ci` are at least sonnet; 5+ files rule out haiku and 12+ mean opus; paths under auth, sessions, permissions, secrets, payments, billing, migrations, infra/terraform/k8s/deploy, CI workflows, hooks or `.claude` count as security/blast radius 1.0 (not for `poll` or `investigate`).
- `reviewer_model` is at least the model and at least sonnet; opus when the change is non-trivial to review or the security signal is ≥ 0.5.
- `deepen` is true when ambiguous or needs-research is ≥ 0.6: send an investigator first.
- `above` is how sure Jev is that a cheaper tier falls short; the Agent hook uses it.

The thresholds are `tune.sh`'s choice on the real set: 451 Agent calls harvested from local transcripts, labelled by one opus agent that saw Claudette's tier text and not the model that ran, 3 Jev runs each, with every Jev value moved 0.1 toward the cheaper tier when counting under-routing. On that set: 0 opus-labelled tasks routed lower, 0 sonnet-labelled tasks routed to haiku (also in a fresh 3-run eval and both halves of a two-fold holdout), and 35% over-routed (mostly sonnet-labelled work going to opus). The mechanical and confidence gates came out at 0: on this data they never beat P(opus) and the two signals. For comparison, Jev's raw choice under-routed 3 of 342 opus rows; v1's policy under-routed none but over-routed 42%; the models that actually ran under-routed 8 of 429 tasks. Details: `test/evidence/route-eval-real.txt`.

`outcome.sh <id> '{"rounds":2,"escalated":false,"verdict":"PASS","final_model":"sonnet"}'` records how a routed task went; `tune.sh` treats an escalated or failed one as "the routed tier was too low".

### The Agent hook

`JEV_ROUTE_MODE`:

- `escalate` (default): raises an explicit `haiku` or `sonnet` to route.sh's tier when `above[given]` ≥ `JEV_ROUTE_MIN_ESCALATE_CONF` (0.7). It never lowers and never touches a model-less call (frontmatter and inherit semantics stay), a full model ID, `fable`, `inherit`, `subagent_type` `fork`, a plugin agent (`x:y`), or anything while `CLAUDE_CODE_SUBAGENT_MODEL` is set. Model-less calls are still routed and logged.
- `fill`: escalate, plus a model on model-less calls of allowlisted types (`JEV_ROUTE_FILL_TYPES`, default `general-purpose`, or a custom agent found by frontmatter `name:` with no `model:`), never below sonnet.
- `log`: decide and log only. `off`: nothing, and nothing is sent.

The hook returns only `updatedInput` (no `permissionDecision`), so permission rules apply as usual. The parent session is not told: `~/.claude/jev/log/route.jsonl` is where the model that ran is recorded, with the reason.

## Ledger

`~/.claude/jev/ledger/<session_id>.jsonl`, one fact per line, in transcript order:

```json
{"id": "f14", "ts": "…", "kind": "user", "text": "User said: Correction: staging moved to pg-staging-7 …",
 "score": 2.71, "supersedes": ["f4", "f5"], "corrects": [], "superseded_by": null, "corrected_by": [], "source_uuid": "…"}
```

- Kinds: `user`, `decision`, `todo`, `file`, `url` (PR links kept at "important" or above), `branch`, `error`, `artifact`.
- Scores: 0 irrelevant, 1 nice to have, 2 important, 3 critical. Facts at ≥ 1.5 are kept, plus lower-scored ones that correct an important fact.
- Corrections: each candidate is checked against the 20 most recent live facts of its family (statements, errors, branches; a statement can also retire an error). A full correction sets `superseded_by` and the old fact is never injected again. A partial one (the old message also said other things that still hold) adds to `corrected_by`; the old fact stays live and is injected with `[later corrected: …]` attached, so a multi-fact message is not lost because one of its facts changed.
- The cursor is in `<session_id>.meta.json`: byte offset of the next unprocessed line and the uuid of the last processed record. Only complete lines are read. A session with no cursor starts at its last compact boundary, so sessions that began before the ledger still get one.
- A Stop that arrives while a step holds `<session_id>.lock` is skipped (the lock is broken after 60 s). If Jev fails, the cursor stays put and the next turn retries; `compact-pre.sh` waits up to 8 s for the lock instead of skipping.

## Artifacts

`artifact.sh <name> [--from-file <path>] [--session <id>]` (content on stdin otherwise) writes `~/.claude/jev/artifacts/<session_id>/<name>.md`, prints the path and adds an `artifact` fact to the ledger. Saving the same name again replaces the file and supersedes the old fact. The session id comes from `--session`, `$CLAUDE_CODE_SESSION_ID` (exported to Bash tool commands and hooks by Claude Code 2.1.302, inside subagents too, so subagent artifacts land in the parent's session), `$CLAUDE_SESSION_ID`, or a pointer `ledger.sh` writes per `CLAUDE_PID` and per directory.

`artifact-hook.sh` saves subagent results over `JEV_ARTIFACT_MIN_CHARS` (2,000) as `agent-<n>-<slug>.md`:

- **Foreground agents** (PostToolUse on `Agent`, `tool_response.status` `completed`): saved, and the parent gets one line of `additionalContext`, `Subagent result (<description>) saved to <path>`. Verified live: the parent quoted the path back (`test/evidence/artifact-live.txt`).
- **Background agents** (`tool_response.status` `async_launched`, no result): saved on SubagentStop from `last_assistant_message`. The parent is not told (SubagentStop output goes to the subagent); the file is in the artifact index after compaction.

## Observed payloads (Claude Code 2.1.302)

Captured live by `test/live-artifact.sh` (`test/evidence/payload-*.json`, sanitised):

- **Stop:** `session_id`, `transcript_path`, `cwd`, `stop_hook_active`, `last_assistant_message`, `background_tasks`, `session_crons`; no `agent_id` on the main session. Subagents fire SubagentStop, not Stop.
- **PostToolUse on Agent, foreground:** `tool_response` is an object: `status: "completed"`, `content: [{type: "text", text}]`, `agentId`, `agentType`, `resolvedModel` (the model that actually ran), usage and durations. `additionalContext` is accepted and reaches the parent.
- **PostToolUse on Agent, background:** `tool_response.status` is `async_launched`, with `agentId`, `description`, `resolvedModel` and `outputFile`; no result.
- **SubagentStop:** `agent_id`, `agent_type`, `agent_transcript_path`, `last_assistant_message`, and `background_tasks` (which lists background agents, so a foreground agent's stop can be told apart). For a foreground agent SubagentStop fires before its PostToolUse.
- **Compaction** (`test/evidence/compact-order.txt`): `PreCompact` → `SubagentStop` (agent_type `""`, the compaction agent; `last_assistant_message` is the summary, byte-identical to PostCompact's `compact_summary`) → `SessionStart` (source `compact`) → `PostCompact`. Coverage therefore runs on that SubagentStop; PostCompact sees the same summary and skips the call. The SubagentStop pass acts only when `agent_type` is empty, the state is still pending and the message contains `<summary>`.

## Knobs

| Knob | Default | Effect |
|---|---|---|
| `JEV_DISABLED` | unset | `1` makes every hook and the CLIs do nothing. |
| `TYPESAFE_API_KEY` | — | The API key. If unset, read from `JEV_ZSHENV`. |
| `JEV_ZSHENV` | `~/.zshenv` | File to read `export TYPESAFE_API_KEY=...` from (last assignment wins, never evaluated). |
| `TYPESAFE_BASE_URL` | `https://api.typesafe.ai` | API base URL. |
| `JEV_MODEL` | `jev-latest` | Jev model. |
| `JEV_HOME` | `~/.claude/jev` | Ledger, artifacts, state, logs, cooldown stamps. |
| `JEV_TIMEOUT` | `8` s | curl `--max-time` for compaction calls. |
| `JEV_ROUTE_TIMEOUT` | `4` s | curl `--max-time` for Agent-hook calls. |
| `JEV_LEDGER_TIMEOUT` | `6` s | curl `--max-time` for ledger calls. |
| `JEV_COOLDOWN` | `300` s | After a timeout, connection failure, 429 or 5xx, calls from the same family fail fast for this long: `cooldown.route` (route.sh, agent-route) and `cooldown.compact` (ledger and compaction). `0` disables it. |
| `JEV_LONG_CONTEXT` | unset | `1` sends the long-context header up front. The hooks retry with it once on `max_tokens_exceeded` anyway. |
| `JEV_CHARS_PER_TOKEN` | `4` | Used to size state under the 32k-tokens-per-question limit. |
| `JEV_ROUTE_MODE` | `escalate` | `escalate`, `fill`, `log` or `off` (see above). |
| `JEV_ROUTE_MIN_ESCALATE_CONF` | `0.7` | How sure Jev must be that an explicit tier falls short before the hook raises it. |
| `JEV_ROUTE_FILL_TYPES` | `general-purpose` | Agent types `fill` may set a model on. |
| `JEV_ROUTE_HAIKU_P` | `0.5` | P(haiku) needed for haiku. |
| `JEV_ROUTE_HAIKU_MECH` | `0` | Mechanical signal needed for haiku (off: tuned to 0). |
| `JEV_ROUTE_HAIKU_AMB` | `0.9` | Haiku only at or below this ambiguity. |
| `JEV_ROUTE_SONNET_POPUS` | `0.4` | Sonnet only at or below this P(opus). |
| `JEV_ROUTE_SONNET_CONF` | `0` | Choice confidence needed for sonnet (off: tuned to 0). |
| `JEV_ROUTE_SIGNAL_MIN` | `0.7` | Security/blast-radius or non-trivial-review signal at or above this means opus. |
| `JEV_ROUTE_REVIEWER_OPUS` | `0.5` | Non-trivial-change or security signal at or above this makes the reviewer opus. |
| `JEV_ROUTE_DEEPEN` | `0.6` | Ambiguous or needs-research at or above this sets `deepen`. |
| `JEV_ROUTE_NO_LOG` | unset | `1`: route.sh does not log (the Agent hook and the eval set it). |
| `JEV_LEDGER` | `1` | `0` turns the ledger off; compaction uses v1 extraction. |
| `JEV_LEDGER_SUPERSEDE_MIN` | `0.6` | P(fully) for superseded; P(partly)+P(fully) for corrected. |
| `JEV_LEDGER_MAX_CANDIDATES` | `JEV_COMPACT_MAX_FACTS` (60) | Candidates per step (most recent kept). |
| `JEV_LEDGER_TAIL_CHARS` | `20000` | Transcript text of the turn sent as context. |
| `JEV_LEDGER_PER_REQ` | `60` | Questions per request; more run as parallel requests. |
| `JEV_LEDGER_MAX_PAIRS` | `120` | Correction questions per step, highest word overlap first. |
| `JEV_LEDGER_LOCK_WAIT` | `8` s | How long the compaction flush waits for a running step. |
| `JEV_ARTIFACTS` | `1` | `0` turns off automatic saving of subagent results. |
| `JEV_ARTIFACT_MIN_CHARS` | `2000` | Results longer than this are saved. |
| `JEV_COMPACT_MAX_FACTS` | `60` | Facts in the compaction snapshot (critical first, then most recent) or v1 extraction. |
| `JEV_COMPACT_SPLIT` | `40` | Facts per coverage request; above this two run in parallel. |
| `JEV_COMPACT_TAIL_CHARS` | `40000` | v1 mode: transcript tail sent. |
| `JEV_COMPACT_MIN_SCORE` | `1.5` | "Important" or above is kept and injected. |
| `JEV_COMPACT_COVERED_MIN` | `0.5` | Jev probability at which the summary counts as keeping a fact. |
| `JEV_COMPACT_MAX_CHARS` | `9000` | Injection cap (Claude Code's limit is 10,000). |
| `JEV_COMPACT_ORCH_MAX` | `4500` | Cap for the `.orchestrator.md` part; the newest live sections are kept. |
| `JEV_COMPACT_ARTIFACT_MAX` | `2000` | Cap for the artifact index; the newest files are kept. |
| `JEV_COMPACT_MAX_AGE` | `3600` s | Older snapshots are ignored. |
| `JEV_COMPACT_GUARD` | unset | `1` blocks one auto-compaction per session when the last turn looks mid-operation. |
| `JEV_COMPACT_GUARD_MIN` | `0.85` | Mid-operation probability that triggers the guard. |

`JEV_ROUTE_MIN_CONF` from v1 is gone: the inverted policy has no confidence bump. Test knobs (`JEV_EVAL_SET`, `JEV_EVAL_DIR`, `EVAL_RUNS`, `EVAL_FIXTURE`, `JEV_TUNE_MARGIN`, `JEV_TUNE_SPLIT`, `JEV_LAT_*`, …) are documented in each script's header.

### Compaction guard (opt-in)

With `JEV_COMPACT_GUARD=1`, `compact-pre.sh` asks Jev whether the last turn is mid-operation (an edit, command or review without a recorded result) and, at `JEV_COMPACT_GUARD_MIN` or above, blocks one auto-compaction per session (exit 2). Never a manual `/compact`, never twice. If the auto-compaction is recovering from a context-limit error, blocking it makes that request fail, which is why it is off by default.

## Logs and state

All under `~/.claude/jev/`, which `.gitignore` keeps out of this public repo.

- `log/jev.jsonl`: one line per API call (status, ms, tokens, answers; no text, no key).
- `log/route.jsonl`: route.sh calls (`action: route`, with id and context), Agent-hook decisions (action, mode, given/final model, reviewer, confidence, `above`, reason, the first 120 characters of the description) and `outcome` records.
- `log/ledger.jsonl`, `log/compact.jsonl`, `log/artifact.jsonl`: one line per step.
- `ledger/`, `artifacts/`, `compact/<session_id>.json` (the snapshot, coverage and consumed flag), `sessions/` (pointers for artifact.sh), `eval/` (the local harvest, labels and results).

## Failure mode

Every hook fails open: on a missing key, network failure, timeout, HTTP error or malformed answer it exits 0 with no output and logs a status. The cooldown makes later calls from the same family fail in milliseconds. `route.sh` and `artifact.sh` exit non-zero so that callers can fall back. The compaction injection of `.orchestrator.md` and the artifact index needs no Jev call and still happens when Jev is down. `test/offline.sh` checks every hook with no key, an unreachable port, a hanging listener, a blackholed address, a bad key, `JEV_DISABLED=1` and `JEV_LEDGER=0`.

Latency (`test/latency.sh`, Jev p50 ≈ 0.3 s): ledger Stop per turn p50 ≈ 0.5 s on the fixture and ≈ 0.65 s (p95 ≈ 0.8 s) replaying 20 turns of a 16 MB real transcript; the first ledger run over that transcript's 14 MB history took ≈ 2 s once. compact-pre with a current ledger ≈ 0.1 s; compact-post ≈ 0.45 s; compact-session ≈ 0.1 s; agent-route ≈ 0.45 s; artifact-hook ≈ 0.12 s.

## Limits

- **Over-routing is deliberate.** About a third of tasks go a tier higher than the blind label. Tuning favoured zero under-routing with a margin; a nondeterministic Jev answer near a threshold should not cost a retry.
- **The labels come from one labeller.** One opus agent labelled the real set; its prompts sometimes named the model the author had picked. The weak redo/escalate labels are noisy (route.sh picked a higher tier for 27 of 93 such rows; 33 of them already ran on opus or fable).
- **Short or truncated briefs drift.** In the committed fixture, a brief whose sanitised version had lost its goal section landed at P(opus) 0.39 against a threshold of 0.4. Complete briefs route better.
- **The Agent hook only acts on aliases.** Model-less calls keep their frontmatter/inherit semantics unless `fill` is on; the hook does not know the parent's model.
- **Background subagents** are saved but the parent is not told the path until the next compaction's index.
- **Ledger egress is per turn.** Each turn's new text (redacted, at most 20,000 characters) goes to Jev, more often than v1's once per compaction.
- **Coverage noise.** Coverage is best effort: Jev sometimes marks a kept fact as missing. The cost is bounded over-injection, never loss.
- **Heuristic extraction.** Facts come from regexes over transcript records (`extract.jq`). Typed slash commands are skipped. A fact is a whole user message or assistant line, which is why partial corrections exist.
- **No summary changes.** The hooks cannot change the summary, only add context after it.
- **Subagent compaction window.** SubagentStop cannot filter on `agent_id` (the parent's compaction agent has one), so a background subagent's own compaction agent that stops with a `<summary>` while the parent's PreCompact is pending (seconds) could claim the parent's snapshot. The worst case is coverage against the wrong summary, which over-injects. Not seen live.
- **Agent lookup cost (fill mode only).** Finding a custom agent by frontmatter `name:` costs about 2 ms per agent file.
- **Guard caveat.** See above.

## Tests

`test/run.sh` runs the offline tests (`offline.sh`, `offline-v2.sh`, `redact.sh`), then the API tests if a key is present (`route-eval.sh`, `agent-route-api.sh`, `compact-fixture.sh`, `ledger-fixture.sh`, `latency.sh`). With `JEV_LIVE=1` it also drives real sessions (`live-agent.sh`, `live-artifact.sh`, `live-compact.sh` in tmux) and refreshes `test/evidence/`.

The routing eval uses the local real set when `~/.claude/jev/eval/labelled.jsonl` exists (or `JEV_EVAL_SET=<file>`), else `test/fixtures/route-eval-real.jsonl` (36 real tasks with every name, path, person and ticket rewritten). To rebuild the real set: `test/harvest.sh`, `test/label-batches.sh`, label the batches with one blind agent into `~/.claude/jev/eval/labels/`, `test/label-batches.sh --merge`, then `EVAL_RUNS=3 test/route-eval.sh` and `JEV_TUNE_SPLIT=1 test/tune.sh`.
