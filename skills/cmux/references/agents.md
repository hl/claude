# Driving AI agents inside cmux

Read this when a task involves **launching** a coding agent (Claude Code, Codex, pi)
in a cmux surface, or **waiting** for one to finish its turn. For plain
terminal/browser surfaces none of this applies — the core control loop in `SKILL.md`
is enough.

## Launching agents unattended

Agents run inside a pane — launch them with `cmux send --surface <ref> "<cmd>"` then
`cmux send-key --surface <ref> enter`, **not** from your own non-interactive/batch
shell. Launch each in a hands-off mode so it doesn't stall on an approval prompt no
one is there to answer. Every flag below is a *per-launch* flag — none of them change
the user's global agent config.

### pi

`pi` is an interactive TUI agent — launch it as `pi --model … "<task>"`, inside a
pane (via `send` + `send-key enter`).

### Codex — yolo / auto mode

- **Yolo (full, no sandbox):** `codex --dangerously-bypass-approvals-and-sandbox "<task>"`
  — skips every approval prompt and the sandbox. Use only because the run is
  orchestrated/observed.
- **Auto (sandboxed):** `codex --full-auto "<task>"` — automatic execution inside a
  workspace-write sandbox; safer when full access isn't needed.

Default to yolo for hands-off fleet runs; reach for `--full-auto` when you want a
sandbox.

**Always launch Codex with the `gpt-5.5` model unless a prompt specifies otherwise** —
pass `-m gpt-5.5` at launch, e.g. `codex -m gpt-5.5 --dangerously-bypass-approvals-and-sandbox "<task>"`.
If a prompt names a different Codex model/effort, use that instead; `gpt-5.5` is just
the default.

### Claude Code — cc bypass mode

Plain `claude` launches in **ask-for-permission mode**: it will *decline* to run
Bash/edits and instead print instructions, then end its turn. For a hands-off fleet
agent, launch it the same way you yolo Codex — bypass permissions at launch:

- **cc bypass:** `claude --dangerously-skip-permissions "<task>"` — Claude's
  equivalent of Codex yolo. The composer then shows `⏵⏵ bypass permissions on` and it
  executes shell/edits without prompting.

Caveat verified in testing: a notification still fires on turn-completion **even when
Claude refused to do the work** — so if you only watch events, you can mistake a
"declined, nothing happened" turn for success. Always `read-screen` (or check the
artifacts) after the event, don't trust the event alone (see **Waiting for an agent's
turn to finish** below).

## Waiting for an agent's turn to finish (don't busy-poll)

Instead of polling `read-screen`, stream cmux's push channel to a file and wait on
*that* — a cheap file poll that trips the instant an agent finishes its turn.
**This is verified working for pi, codex, and Claude Code.**

**`cmux events` is the wait channel — not `cmux wait-for`.** `cmux wait-for <name>`
is an unrelated *named-token rendezvous* (a manual semaphore you signal yourself);
it does **not** know when an agent finishes. The agent-completion signal is the
`notification` event category.

**Prerequisite — install the notification hooks once:**

```bash
cmux hooks setup            # wires pi, codex, opencode, gemini, … to emit on turn-stop
# or per agent:  cmux hooks pi install   /   cmux hooks codex install
```

Claude Code emits notifications out of the box when launched inside cmux (no
`cmux hooks` entry needed). Without hooks, an agent stays silent and you're back to
polling — so install them before relying on the wait.

**What an agent emits when its turn ends** — one event per completed turn:

```json
{ "name": "notification.requested", "category": "notification",
  "workspace_id": "120FC732-…", "surface_id": null, "seq": 1512, … }
```

Match on **`workspace_id`** — for hook-emitted notifications `surface_id` is usually
`null`, but `workspace_id` is always set. The title/body are **redacted** in the
event (you get the signal, not the text), so once it fires, `read-screen` that
workspace's surface for the actual reply. Filter to `--name notification.requested`;
a sibling `notification.clear_requested` fires when a surface gains focus and is just
noise.

**Wait for a specific agent to finish** (first grab its workspace UUID — the `id`
field from `cmux workspace list --json --id-format both`; that's the value the
event's `workspace_id` carries):

```bash
WS=<agent-workspace-uuid>
# Start the listener to a file BEFORE sending the prompt, then poll the file.
cmux events --name notification.requested --no-heartbeat --no-ack > /tmp/cmux.ev &
EV=$!
cmux send --surface <ref> "<task>"; cmux send-key --surface <ref> enter
# wait (bounded) for this workspace's turn-done event
until grep -q "\"workspace_id\":\"$WS\"" /tmp/cmux.ev; do sleep 1; done
kill $EV
cmux read-screen --surface <ref> --scrollback --lines 40   # now read the reply
```

Pitfall: a `cmux events | jq … &` pipeline in a one-liner can stall on stdout
buffering — stream to a **file** and poll the file (above), or pass
`jq --unbuffered`. For a durable cursor across reconnects use
`cmux events --cursor-file <path> --reconnect`.
