# Jev hooks

These hooks use [Jev](https://docs.typesafe.ai) (TypeSafe AI) for two jobs in long Claude Code sessions: pick the model for each subagent, and keep the state that compaction would lose. Jev is a decision model: it takes typed questions and returns typed answers with probabilities, in about 0.3 s, and it does not generate text. The hooks use bash, jq and curl only.

The loss they optimise is wasted work, not spend: a retry after under-routing, research done twice, and a session that forgets a correction after compaction. A higher tier and a Jev call per turn are cheap by comparison.

- **Routing.** `route.sh` picks haiku, sonnet or opus for a brief, plus a reviewer model and whether to investigate first. The tier is opus unless Jev is confident a lower one suffices; the thresholds were tuned on 451 real Agent calls from local transcripts, labelled blind. `agent-route.sh` (PreToolUse on `Agent`) raises an explicit `haiku`/`sonnet` when Jev is sure it falls short.
- **Ledger.** `ledger.sh` (Stop) reads each new turn, scores candidate facts and notes which earlier facts they correct, into a per-session ledger.
- **Compaction.** `compact-pre.sh` flushes the ledger, `compact-post.sh` checks which facts the summary kept, and `compact-session.sh` re-injects, per live `.orchestrator.md` section, its heading, first line and Status line, then the artifact index and the facts the summary dropped.
- **Artifacts.** `artifact-hook.sh` saves every subagent deliverable (a reply whose first line is `Artifact: <name>`) and every result over 2,000 chars, and tells the parent where; `artifact.sh` does the same by hand for the user or the main session.
- **Autotune.** Once a day the ledger checks whether 50 new `outcome.sh` records exist; if so, `autotune.sh` re-tunes the routing thresholds and applies the result only when it is provably safer.

## How it fits together

```
every turn ──Stop──▶ ledger.sh ── new transcript lines since the cursor
                        │           extract.jq → candidates → Jev: score + "corrects fact M?"
                        ▼
              ~/.local/state/jev/ledger/<session>.jsonl   (facts; superseded_by / corrected_by)
                        ▲                                      ▲
artifact.sh / ──────────┘ "artifact" facts                     │
artifact-hook.sh ─▶ ~/.local/state/jev/artifacts/<session>/*.md     │
                                                               │
/compact or auto ──PreCompact──▶ compact-pre.sh: ledger flush, snapshot of live facts ─┐
                 ──SubagentStop (compaction agent)──▶ compact-post.sh: Jev "summary keeps fact N?" (coverage)
                 ──SessionStart(compact)──▶ compact-session.sh: inject, ≤ 9,000 chars:
                        (c) live .orchestrator.md headings  >  (b) artifact index  >  (a) uncovered live facts
                        + where the ledger and artifacts live
                 ──PostCompact──▶ compact-post.sh (skips if the SubagentStop pass covered it)

Agent call ──PreToolUse──▶ agent-route.sh ─▶ route.sh ─▶ Jev ─▶ policy.jq ─▶ maybe updatedInput.model
           ──PostToolUse──▶ artifact-hook.sh ─▶ "Subagent result (<description>) saved to <path>"
Claudette ──▶ route.sh --context '{…}' → model, reviewer_model, deepen, id ──▶ outcome.sh <id> when done
```

## Enable

Set `TYPESAFE_API_KEY` in the environment, or put an `export TYPESAFE_API_KEY=...` line in `~/.zshenv`. That is the only step. The hooks are wired up in `settings.json` (Stop `ledger.sh` async, PreToolUse/PostToolUse on `Agent`, SubagentStop, PreCompact, PostCompact, SessionStart `compact`), and the first hook run sets up its own state: it creates `$JEV_HOME` (default `${XDG_STATE_HOME:-~/.local/state}/jev`) and, if an older version left `~/.claude/jev`, moves it there and leaves a one-line pointer file in its place (only hook runs do this, never a CLI; if the new home already exists, the two merge, logs concatenated and the newer copy of any other file kept). The move is one-way: a checkout of an older version would start with empty state at `~/.claude/jev`. To undo it: `rm ~/.claude/jev && mv ~/.local/state/jev ~/.claude/jev`. Nothing writes into `~/.claude` (a protected directory for Claude Code, and a public repo here).

`JEV_DISABLED=1` turns every hook off and makes `route.sh` exit 3. Two CLIs keep their local part, because they were asked for explicitly: `artifact.sh` still writes the file (but adds nothing to the ledger, so nothing about it can reach Jev), and `outcome.sh` still appends to `route.jsonl`. `JEV_LEDGER=0` turns off only the ledger (compaction falls back to v1 extraction), `JEV_ROUTE_MODE=off` only the Agent hook, `JEV_ARTIFACTS=0` only the automatic artifact saving.

## What leaves the machine

Everything goes to `api.typesafe.ai`, and every request body passes through `redact.jq` inside `jev_call` first, so no caller can skip it. Redacted: API keys and tokens (`sk-…`, `sk_live_…`/`rk_live_…`/`sk_test_…`, `whsec_…`, `apik…`, `ghp_…`/`ghs_…`/`github_pat_…`, `glpat-…`, `xox?-…`, `npm_…`, `hf_…`, `dop_v1_…`, `shpat_…`, `AKIA…`/`ASIA…`, `AIza…`), JWTs, `Authorization:` and `Cookie:` headers and bare bearer tokens, Slack webhook URLs, `curl -u user:pass`, `--password x` / `--password=x`, `mysql -p<pw>` / `-p <pw>`, `KEY=value` / `"key": value` where the name contains key, token, secret, password, passphrase or credential, the same names in `{"name": …, "value": …}` pairs and YAML `- name:` / `value:` env lists, long hex/base64 runs after a key-ish word, credentials in URLs, signed query values (`X-Amz-Signature`, `token=`, `sig=`, …), PEM private keys, email addresses (`<email>`) and IPv4 addresses (`<ip>`). Not caught: secrets in prose ("the pass is Tr0ub4dor&3"), short values after a key name that look like numbers, IPv6. Paths, hostnames, git remotes and PR links are kept: they are the facts worth preserving. `test/redact.sh` plants 51 secrets in every hook's input and checks the captured request bodies (`test/evidence/redaction.txt`).

- **Every turn (Stop):** the new candidate facts of that turn (user messages, decision lines, paths, URLs, branches, the failing command, open items), up to 20,000 characters of that turn's transcript text, and the 40 most recent ledger facts.
- **Every compaction:** the compaction summary and the facts being checked against it. In v1 mode (no ledger), up to 40,000 characters of the transcript tail and up to 60 extracted facts, as before.
- **Every Agent call** (all modes except `off`): its `description`, `subagent_type` and `prompt`.
- **Every `route.sh` call:** the brief and its `--context`.

Artifact contents and `.orchestrator.md` are never sent. An artifact's ledger fact (its name, local path and title or subagent description) is, like every ledger fact: the 40 most recent live facts go along as context on each turn.

## Routing

`route.sh [--context '<json>'] "<brief>"` (or the brief on stdin) prints:

```json
{"id": "r1792…", "model": "opus", "reviewer_model": "opus", "deepen": true,
 "policy": ["opus: P(opus) 0.92 > 0.35", "retry (attempt 2, thin): one tier above sonnet"],
 "confidence": 0.79, "probabilities": {…}, "signals": {…}, "above": {"haiku": 1, "sonnet": 0.92}, …}
```

`--context` fields, all optional: `attempt`, `prior_model`, `prior_outcome` ("thin", "wrong", "review FAIL x2"), `files_hint` (a count or a list), `paths`, `kind` (`implement`, `review`, `investigate`, `fix-ci`, `address-comments`, `poll`), `diff_size`. Jev sees `{task, context}`. Before that, route.sh drops lines of the brief that already name a tier (`Model: sonnet — …`, `jev: opus/opus …`, `— opus because …`, `model haiku — …`; `anchors.jq`), so Jev is not anchored on the author's guess, and the Agent hook does not re-read the line Claudette wrote from route.sh's own answer. `anchors_stripped` in the output counts them.

Policy (`policy.jq`, shared with `tune.sh`):

- **haiku** when P(haiku) ≥ 0.6, ambiguous ≤ 0.9 and the security/blast-radius and non-trivial-review signals are below 0.7;
- **sonnet** when P(opus) ≤ 0.35 and the same two signals are below 0.7 (a design choice: security-sensitive work and non-trivial reviews go to opus);
- **opus** otherwise.
- Then: a retry (attempt ≥ 2, or a prior outcome of thin/wrong/fail) goes at least one tier above the previous attempt; `investigate` and `fix-ci` are at least sonnet; 5+ files rule out haiku and 12+ mean opus; paths under auth, sessions, permissions, secrets, payments, billing, migrations, infra/terraform/k8s/deploy, CI workflows, hooks or `.claude` count as security/blast radius 1.0 (not for `poll` or `investigate`).
- `reviewer_model` is at least the model and at least sonnet; opus when the change is non-trivial to review or the security signal is ≥ 0.5.
- `deepen` is true when ambiguous or needs-research is ≥ 0.6: send an investigator first.
- `above` is how sure Jev is that a cheaper tier falls short; the Agent hook uses it.

The thresholds come from `tune.sh` on the real set: 451 Agent calls harvested from local transcripts, labelled by one opus agent that saw Claudette's tier text and not the model that ran (`test/label-prompt.txt`), 3 Jev runs each on briefs with their model-naming lines stripped, in two independent sessions, with a two-fold holdout split by task and every Jev value moved 0.1 toward the cheaper tier when counting under-routing. The folds disagreed (P(haiku) 0.5–0.6, P(opus) 0.35–0.6), so the shipped point takes the most conservative value of each: P(haiku) 0.6, P(opus) 0.35.
  - *Out of sample* (one fold's own choice, scored on the half it never saw): the fold that chose P(haiku) 0.55 / P(opus) 0.35, next to the shipped point, under-routed none of 180 opus and 261 sonnet rows, also at the margin; the fold that chose 0.5 / 0.6 under-routed 3 of 162 opus rows (18 at the margin). A single fold's tune is not safe; the conservative combination is the rule.
  - *In sample* (the conservative combination of both folds, scored on the data it came from): 0 of 342 opus rows routed lower and 0 of 558 sonnet rows routed to haiku in both sessions, also at the margin and on the briefs that name no tier; 48% over-routed overall and 43% on those briefs. The suite's fresh 1-run evals since agree (0 under-routed, 47–49% over-routed). The security/review gate (0.7) is a design choice, not tuned. The mechanical and confidence gates came out at 0. For comparison, on the same answers Jev's raw choice under-routed 5 of 342 opus rows, v1's policy under-routed none but over-routed 54%, and the models that actually ran under-routed 8 of 429 tasks. Details: `test/evidence/route-eval-real.txt`.

`outcome.sh <id> '{"rounds":2,"escalated":false,"verdict":"PASS","final_model":"sonnet"}'` records how a routed task went; `tune.sh` treats an escalated or failed one as "the routed tier was too low".

### The Agent hook

`JEV_ROUTE_MODE`:

- `escalate` (default): raises an explicit `haiku` or `sonnet` to route.sh's tier when `above[given]` ≥ `JEV_ROUTE_MIN_ESCALATE_CONF` (0.7). It never lowers and never touches a model-less call (frontmatter and inherit semantics stay), a full model ID, `fable`, `inherit`, `subagent_type` `fork`, a plugin agent (`x:y`), or anything while `CLAUDE_CODE_SUBAGENT_MODEL` is set. Model-less calls are still routed and logged.
- `fill`: escalate, plus a model on model-less calls of allowlisted types (`JEV_ROUTE_FILL_TYPES`, default `general-purpose`, or a custom agent found by frontmatter `name:` with no `model:`), never below sonnet.
- `log`: decide and log only. `off`: nothing, and nothing is sent.

The 0.7 gate is a noise filter, not a selector: it stops one jittery Jev sample from overriding an explicit choice, but because `above.haiku` includes `1 - mechanical`, almost any brief the router would not send to haiku clears it (on the real set, 98% of non-haiku routes). In practice escalate raises any explicit haiku the router would not pick, and an explicit sonnet when P(opus) or a signal is high.

The hook returns only `updatedInput` (no `permissionDecision`), so permission rules apply as usual. The parent session is not told. `~/.local/state/jev/log/route.jsonl` has both halves, joined by `tool_use_id`: the hook's decision (with the reason) and, from `artifact-hook.sh` on PostToolUse, an `action: "ran"` record with `resolved_model`, the model that actually ran (verified live, `test/evidence/artifact-live.txt`).

## Ledger

`~/.local/state/jev/ledger/<session_id>.jsonl`, one fact per line, in transcript order:

```json
{"id": "f14", "ts": "…", "kind": "user", "text": "User said: Correction: staging moved to pg-staging-7 …",
 "score": 2.71, "supersedes": ["f4", "f5"], "corrects": [], "superseded_by": null, "corrected_by": [], "source_uuid": "…"}
```

- Kinds: `user`, `decision`, `todo`, `file`, `url` (PR links kept at "important" or above), `branch`, `error`, `artifact`.
- Scores: 0 irrelevant, 1 nice to have, 2 important, 3 critical. Facts at ≥ 1.5 are kept, plus lower-scored ones that correct an important fact.
- Corrections: each candidate is checked against the 20 live facts of its family with the most word overlap, ties to the more recent (statements, errors, branches; a statement can also retire an error). A full correction sets `superseded_by` and the old fact is never injected again. A partial one (the old message also said other things that still hold) adds to `corrected_by`; the old fact stays live and is injected with `[later corrected: …]` attached, so a multi-fact message is not lost because one of its facts changed.
- New candidates are deduplicated against live facts only. A statement that comes back after it was superseded (A, then B, then A again; matched on normalised text) restores A deterministically: it is kept whatever Jev scores it (live, Jev scores a restated A as obsolete, 0.4–0.56), at the old fact's score, and the fact that had replaced A is marked superseded by it (`test/ledger-restore.sh`, 3 of 3 runs for a short and a long restatement). A candidate Jev calls a full correction of an important fact is kept whatever its own score. Open items that are the same item worded as a user line, an "Open item:" line and a checkbox are stored once. An assistant line that restates a statement (over 80% of its content words, no new numbers, paths or names) is not asked whether it corrects it.
- The cursor is in `<session_id>.meta.json`: byte offset of the next unprocessed line and the uuid of the last processed record. Only complete lines are read. A session with no cursor starts at its last compact boundary and keeps the facts an earlier (v1) compaction re-injected there (`carried`, kept whatever Jev scores them), so sessions that began before the ledger lose nothing.
- The Stop entry is `"async": true`: the turn does not wait for it, and its output is ignored (verified live, `test/evidence/async-stop.txt`). A Stop that arrives while a step holds `<session_id>.lock` is skipped; its lines are picked up by the next step. The lock is a `mkdir`; it is broken when its holder's pid is gone or it is over 60 s old (a lock dir whose `at` file is not written yet is judged by its own mtime). A killed step releases it (TERM trap). If Jev fails, the cursor stays put and the next turn retries. `compact-pre.sh` stays synchronous: it waits up to 3 s for a running step, then flushes or, if the step is still running, snapshots what the ledger already has.
- Housekeeping: superseded facts older than 7 days move to `<session_id>.archive.jsonl`; once a day, the first ledger run deletes ledger, snapshot, artifact and pointer files untouched for 30 days (`JEV_RETAIN_DAYS`).

## Artifacts

Subagents do not write files: Claudette's briefs ask for the deliverable as the final reply, first line `Artifact: <name>`, and `artifact-hook.sh` (user-configured hook code, so no permission rule or auto-mode classifier is involved) saves it whatever its length as `<name>.md`, or `<name>-<agentId>.md` if another agent already used the name, and cites it to the parent. Verified live in auto mode with no allow rules (`test/evidence/artifact-live.txt`).

`artifact.sh <name> [--from-file <path>] [--session <id>]` (content on stdin otherwise) is the same by hand, for the user or the main session: it writes `$JEV_HOME/artifacts/<session_id>/<name>.md`, prints the path and adds an `artifact` fact to the ledger. Saving the same name again replaces the file and supersedes the old fact. The session id comes from `--session`, `$CLAUDE_CODE_SESSION_ID` (exported to Bash tool commands and hooks by Claude Code 2.1.302, inside subagents too, so subagent artifacts land in the parent's session), `$CLAUDE_SESSION_ID`, or a pointer `ledger.sh` writes per `CLAUDE_PID` and per directory.

Unmarked subagent results over `JEV_ARTIFACT_MIN_CHARS` (2,000) are saved too, as `agent-<n>-<slug>-<agentId>.md` (the id keeps two agents with the same description apart; each is written to a temporary file in the same directory and renamed). Artifacts over 512 KB (`JEV_ARTIFACT_MAX_BYTES`) are cut, with a note at the end. `artifact.sh` applies the same cap.

- **Foreground agents** (PostToolUse on `Agent`, `tool_response.status` `completed`): saved, and the parent gets one line of `additionalContext`, `Subagent result (<description>) saved to <path>`. Verified live: the parent quoted the path back (`test/evidence/artifact-live.txt`).
- **Background agents** (`tool_response.status` `async_launched`, no result): saved on SubagentStop (from `last_assistant_message`, or the handback in the agent transcript). The parent is not told (SubagentStop output goes to the subagent); the file is in the artifact index after compaction.

## Autotune

`autotune.sh` runs in the background from the ledger's first run of the day and does nothing until 50 new `outcome.sh` records exist (`JEV_AUTOTUNE_MIN`). It then tunes on the newest real eval results in `$JEV_HOME/eval/` plus every outcome joined to its route call (an escalated or failed route says "this tier was too low"), with the same task-split folds and conservative combination as above. It applies the result to `$JEV_HOME/tune/thresholds.json`, which `route.sh` reads (below any `JEV_ROUTE_*` variable; output fields `tuned` and `thresholds`), only if both hold:

- the new point under-routes nothing on the full real set and on its unanchored subset, at Jev's nominal values and with every value moved 0.1 toward the cheaper tier;
- every threshold is a number and is the shipped default or stricter (P(haiku), mechanical and confidence bars at or above it; ambiguity and P(opus) bars at or below it). The baseline is always the shipped defaults, never the current file.

`route.sh` also clamps whatever `thresholds.json` says to the shipped defaults or stricter and never reads the security/review gate from it, so a hand edit or a bad write cannot loosen routing either. Only an explicit `JEV_ROUTE_*` variable can.

Otherwise it writes `$JEV_HOME/tune/proposal.json` with the reason. Every apply, proposal or skip is a line in `log/jev.jsonl`. The security/review gate is never tuned. Without a local real set (`test/harvest.sh` and a labelling pass build one), it logs a skip and changes nothing. `JEV_AUTOTUNE=0` turns it off.

## Observed payloads (Claude Code 2.1.302 and 2.1.304)

Captured live by `test/live-artifact.sh` (`test/evidence/payload-*.json`, sanitised). Claude Code updated to 2.1.304 during this work; the differences are noted:

- **Stop:** `session_id`, `transcript_path`, `cwd`, `stop_hook_active`, `last_assistant_message`, `background_tasks`, `session_crons`; no `agent_id` on the main session. Subagents fire SubagentStop, not Stop.
- **PostToolUse on Agent, foreground:** `tool_response` is an object: `status: "completed"`, `agentId`, `agentType`, `resolvedModel` (the model that actually ran), usage and durations, and the report: in 2.1.302 `content: [{type: "text", text}]`; in 2.1.304 the agent hands back through a `SubagentHandback` tool, `content` holds only a notice and the report is `handbackReport.text`. `additionalContext` is accepted and reaches the parent.
- **PostToolUse on Agent, background:** `tool_response.status` is `async_launched`, with `agentId`, `description`, `resolvedModel` and `outputFile`; no result.
- **SubagentStop:** `agent_id`, `agent_type`, `agent_transcript_path`, and `background_tasks` (which lists background agents, so a foreground agent's stop can be told apart). 2.1.302 also sends `last_assistant_message`; 2.1.304 leaves it out for agents that hand back, and the hook reads the last `SubagentHandback` message (or assistant text) from `agent_transcript_path`. The compaction agent still sends it. For a foreground agent SubagentStop fires before its PostToolUse.
- **Compaction** (`test/evidence/compact-order.txt`): `PreCompact` → `SubagentStop` (agent_type `""`, the compaction agent; `last_assistant_message` is the summary, byte-identical to PostCompact's `compact_summary`) → `SessionStart` (source `compact`) → `PostCompact`. Coverage therefore runs on that SubagentStop; PostCompact sees the same summary and skips the call. The SubagentStop pass acts only when `agent_type` is empty, the state is still pending and the message contains `<summary>`.

## Knobs

| Knob | Default | Effect |
|---|---|---|
| `JEV_DISABLED` | unset | `1` makes every hook do nothing and `route.sh` exit 3; `artifact.sh` still writes its file without a ledger fact, `outcome.sh` still logs. |
| `TYPESAFE_API_KEY` | — | The API key. If unset, read from `JEV_ZSHENV`. |
| `JEV_ZSHENV` | `~/.zshenv` | File to read `export TYPESAFE_API_KEY=...` from (last assignment wins, never evaluated). |
| `TYPESAFE_BASE_URL` | `https://api.typesafe.ai` | API base URL. |
| `JEV_MODEL` | `jev-latest` | Jev model. |
| `JEV_HOME` | `${XDG_STATE_HOME:-~/.local/state}/jev` | Ledger, artifacts, state, logs, cooldown stamps, tuned thresholds. An old `~/.claude/jev` is moved here on the first run. |
| `JEV_MIGRATE` | `1` | `0` leaves an old `~/.claude/jev` where it is (the tests set this). |
| `JEV_AUTOTUNE` | `1` | `0` turns the daily autotune check off. |
| `JEV_AUTOTUNE_MIN` | `50` | New outcome records needed before autotune runs. |
| `JEV_TIMEOUT` | `8` s | curl `--max-time` for compaction calls. |
| `JEV_ROUTE_TIMEOUT` | `4` s | curl `--max-time` for Agent-hook calls. |
| `JEV_LEDGER_TIMEOUT` | `6` s | curl `--max-time` for ledger calls. |
| `JEV_COOLDOWN` | `300` s | After a timeout, connection failure, 429 or 5xx, calls from the same family fail fast for this long: `cooldown.route` (route.sh, agent-route) and `cooldown.compact` (ledger and compaction). `0` disables it. |
| `JEV_LONG_CONTEXT` | unset | `1` sends the long-context header up front. The hooks retry with it once on `max_tokens_exceeded` anyway. |
| `JEV_CHARS_PER_TOKEN` | `4` | Used to size state under the 32k-tokens-per-question limit. |
| `JEV_ROUTE_MODE` | `escalate` | `escalate`, `fill`, `log` or `off` (see above). |
| `JEV_ROUTE_MIN_ESCALATE_CONF` | `0.7` | How sure Jev must be that an explicit tier falls short before the hook raises it (a noise filter, see above). |
| `JEV_ROUTE_FILL_TYPES` | `general-purpose` | Agent types `fill` may set a model on. |
| `JEV_ROUTE_HAIKU_P` | `0.6` | P(haiku) needed for haiku. |
| `JEV_ROUTE_HAIKU_MECH` | `0` | Mechanical signal needed for haiku (off: tuned to 0). |
| `JEV_ROUTE_HAIKU_AMB` | `0.9` | Haiku only at or below this ambiguity. |
| `JEV_ROUTE_SONNET_POPUS` | `0.35` | Sonnet only at or below this P(opus). |
| `JEV_ROUTE_SONNET_CONF` | `0` | Choice confidence needed for sonnet (off: tuned to 0). |
| `JEV_ROUTE_SIGNAL_MIN` | `0.7` | Security/blast-radius or non-trivial-review signal at or above this means opus. A design choice, not tuned. |
| `JEV_ROUTE_REVIEWER_OPUS` | `0.5` | Non-trivial-change or security signal at or above this makes the reviewer opus. |
| `JEV_ROUTE_DEEPEN` | `0.6` | Ambiguous or needs-research at or above this sets `deepen`. |
| `JEV_ROUTE_NO_LOG` | unset | `1`: route.sh does not log (the Agent hook and the eval set it). |
| `JEV_LEDGER` | `1` | `0` turns the ledger off; compaction uses v1 extraction. |
| `JEV_LEDGER_SUPERSEDE_MIN` | `0.6` | P(fully) for superseded; P(partly)+P(fully) for corrected. |
| `JEV_LEDGER_MAX_CANDIDATES` | `JEV_COMPACT_MAX_FACTS` (60) | Candidates per step (most recent kept). |
| `JEV_LEDGER_TAIL_CHARS` | `20000` | Transcript text of the turn sent as context. |
| `JEV_LEDGER_PER_REQ` | `60` | Questions per request; more run as parallel requests. |
| `JEV_LEDGER_MAX_PAIRS` | `120` | Correction questions per step, highest word overlap first. |
| `JEV_LEDGER_LOCK_WAIT` | `3` s | How long the compaction flush waits for a running step before snapshotting what is there. |
| `JEV_RETAIN_DAYS` | `30` | Ledger, snapshot, artifact and pointer files untouched this long are deleted (checked once a day). |
| `JEV_ARTIFACTS` | `1` | `0` turns off automatic saving of subagent results. |
| `JEV_ARTIFACT_MIN_CHARS` | `2000` | Results longer than this are saved. |
| `JEV_ARTIFACT_MAX_BYTES` | `524288` | Artifacts are cut to this size, with a note. |
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

With `JEV_COMPACT_GUARD=1`, `compact-pre.sh` asks Jev whether the last turn is mid-operation (an edit, command or review without a recorded result) and, at `JEV_COMPACT_GUARD_MIN` or above, blocks one auto-compaction per session (exit 2). Never a manual `/compact`, never twice. Everything else here runs on its own; this is the one place autonomy yields to safety: a hook cannot tell a routine auto-compaction from one that is recovering from a context-limit error, and blocking the latter makes the request fail. So it stays off unless you turn it on.

## Logs and state

All under `$JEV_HOME`, default `${XDG_STATE_HOME:-~/.local/state}/jev`, outside `~/.claude`.

- `log/jev.jsonl`: one line per API call (status, ms, tokens, answers; no text, no key).
- `log/route.jsonl`: route.sh calls (`action: route`, with id and context), Agent-hook decisions (action, mode, `tool_use_id`, given/final model, reviewer, confidence, `above`, reason, the first 120 characters of the description), `ran` records (`tool_use_id`, `agent_id`, `resolved_model`, status) and `outcome` records.
- `log/ledger.jsonl`, `log/compact.jsonl`, `log/artifact.jsonl`: one line per step.
- `ledger/`, `artifacts/`, `compact/<session_id>.json` (the snapshot, coverage and consumed flag), `sessions/` (pointers for artifact.sh), `eval/` (the local harvest, labels and results), `tune/` (applied thresholds, proposals).

## Failure mode

Every hook fails open: on a missing key, network failure, timeout, HTTP error or malformed answer it exits 0 with no output and logs a status. The cooldown makes later calls from the same family fail in milliseconds. `route.sh` and `artifact.sh` exit non-zero so that callers can fall back. The compaction injection of `.orchestrator.md` and the artifact index needs no Jev call and still happens when Jev is down. `test/offline.sh` checks every hook with no key, an unreachable port, a hanging listener, a blackholed address, a bad key, `JEV_DISABLED=1` and `JEV_LEDGER=0`.

Latency (`test/latency.sh`, Jev p50 ≈ 0.3 s): ledger Stop per turn p50 ≈ 0.5 s on the fixture and ≈ 0.65 s (p95 ≈ 0.8 s) replaying 20 turns of a 16 MB real transcript; the first ledger run over that transcript's 14 MB history took ≈ 2 s once. compact-pre with a current ledger ≈ 0.1 s; compact-post ≈ 0.45 s; compact-session ≈ 0.1 s; agent-route ≈ 0.45 s; artifact-hook ≈ 0.12 s.

## Limits

- **Over-routing is deliberate and large.** About 48% of real tasks go a tier higher than the blind label (43% of the briefs that name no tier). Tuning required zero under-routing with a 0.1 margin and took the more conservative fold on every threshold; a nondeterministic Jev answer near a threshold should not cost a retry.
- **The opus guarantee is thin at the bottom.** On stripped briefs the lowest P(opus) among opus-labelled tasks are 0.17 (security 0.88), 0.47 (security 0.75), 0.56 and 0.64, against the 0.35 bar: the first is kept on opus only by the 0.7 security gate, the next ones by the gate or by a 0.1–0.2 margin. The gate is a design choice, not tuned: in the review, a holdout fold that was allowed to tune it switched it off and under-routed 3 opus rows.
- **The labels are anchored.** One opus agent labelled the real set (`test/label-prompt.txt`). 30% of the briefs (136 of 451; 47% of the haiku labels) carried a "Model: <tier>" line naming the tier that ran, and the labeller agreed with that line 93% of the time, against 70% agreement with the tier that ran where there was no line. route.sh strips those lines, so its own answer is not anchored, but the labels it is measured against partly are; the unanchored-subset figures are the cleaner ones. The weak redo/escalate labels are noisy.
- **Short or truncated briefs drift.** In the committed fixture, a brief whose sanitised version had lost its goal section landed at P(opus) 0.39. Complete briefs route better.
- **Vague reverts.** "Go back to what we had before" (A, then B, then a revert that names neither) supersedes both A and B, and the only live fact is the vague revert. Restating A (the same words, give or take case and punctuation) restores it; a paraphrased revert that names the old choice ("Back to advisory locks …") worked in the live test because Jev called it a full correction of B; a vague one does not, and no extra Jev question is asked for it.
- **The Agent hook only acts on aliases.** Model-less calls keep their frontmatter/inherit semantics unless `fill` is on; the hook does not know the parent's model.
- **Background subagents** are saved but the parent is not told the path until the next compaction's index.
- **artifact.sh under auto mode.** The classifier can refuse running `~/.claude/hooks/jev/artifact.sh` as "self-modification" (seen once in three live runs). Subagents therefore never call it (they return a marked reply for the hook), and no permission rule ships; the user or the main session can still run it.
- **Ledger egress is per turn.** Each turn's new text (redacted, at most 20,000 characters) goes to Jev, more often than v1's once per compaction.
- **Coverage noise.** Coverage is best effort: Jev sometimes marks a kept fact as missing. The cost is bounded over-injection, never loss.
- **Heuristic extraction.** Facts come from regexes over transcript records (`extract.jq`). Typed slash commands are skipped. A fact is a whole user message or assistant line, which is why partial corrections exist.
- **No summary changes.** The hooks cannot change the summary, only add context after it.
- **Subagent compaction window.** SubagentStop cannot filter on `agent_id` (the parent's compaction agent has one), so a background subagent's own compaction agent that stops with a `<summary>` while the parent's PreCompact is pending (seconds) could claim the parent's snapshot. The worst case is coverage against the wrong summary, which over-injects. Not seen live.
- **Agent lookup cost (fill mode only).** Finding a custom agent by frontmatter `name:` costs about 2 ms per agent file.
- **Guard caveat.** See above.
- **Autotune needs a local real set.** Without `$JEV_HOME/eval/results-*.jsonl` it only logs a skip; outcomes alone are not enough to tune on.

## Tests

`test/run.sh` runs the offline tests (`offline.sh`, `offline-v2.sh`, `redact.sh`), then the API tests if a key is present (`route-eval.sh`, `agent-route-api.sh`, `compact-fixture.sh`, `ledger-fixture.sh`, `ledger-restore.sh`, `latency.sh`). With `JEV_LIVE=1` it also drives real sessions (`live-agent.sh`, `live-artifact.sh` in auto mode, `live-compact.sh` and `live-async-stop.sh` in tmux). Every test uses its own `JEV_HOME` and sets `JEV_MIGRATE=0`, so nothing touches this machine's real state. Tests rewrite `test/evidence/` only under `JEV_LIVE=1` or `JEV_EVIDENCE=1`, so a plain run leaves the tree clean.

The routing eval uses the local real set when `~/.local/state/jev/eval/labelled.jsonl` exists (or `JEV_EVAL_SET=<file>`), else `test/fixtures/route-eval-real.jsonl` (36 real tasks with every name, path, person and ticket rewritten). On the real set it writes the raw answers to a new `~/.local/state/jev/eval/results-<UTC time>.jsonl`, which `tune.sh` takes as its argument (default: the newest). Optional, to rebuild the real set (autotune uses it when present): `test/harvest.sh`, `test/label-batches.sh`, label the batches with one blind agent using `test/label-prompt.txt`, `test/label-batches.sh --merge`, then `EVAL_RUNS=3 test/route-eval.sh` and `JEV_TUNE_SPLIT=1 test/tune.sh <results file>`.
