# The checkpoint contract — `FLEET_CHECKPOINT v1`

A terminal transcript is not recovery state. A dead session and a finished one look
identical from outside, and every agent here is expected to die eventually — to a
crash, a compaction, a deliberate handoff. What survives is the bead.

So every durable transition is an **append-only bead comment** in exactly this shape.
Read this file at session start if your role file says you write or read checkpoints.

```text
FLEET_CHECKPOINT v1
checkpoint_id: <uuid, unique per checkpoint>
bead: <bead-id>
stage: <plan|work|review|rework|land|reconcile|done|abandoned>
status: <ready|active|blocked|changes|approved|landed|abandoned>
actor: <role and agent name>
workspace: <herdr workspace label or n/a>
worktree: <absolute path or n/a>
branch: <branch or n/a>
base_sha: <full SHA or n/a>
head_sha: <full SHA or n/a>
pr: <URL or n/a>
review_round: <integer>
completed: <JSON array of facts>
verification: <JSON array of exact command/outcome facts>
next_action: <one concrete action, or none>
blocker: <the exact blocker, or none>
must_not_undo: <JSON array of settled decisions a successor must preserve>
updated_at: <RFC3339 UTC, informational only>
```

## Rules that make it worth writing

- **Single-line values; valid JSON for the arrays.** No value available → write `n/a`.
  Never omit a field and never guess one — a missing field is indistinguishable from a
  field the writer didn't check.
- **`verification` holds exact commands and their outcomes**, not adjectives. "tests
  pass" is not a verification fact; `mise exec -- pytest -q → 214 passed` is. Never
  record a gate you didn't run.
- **`next_action` is one concrete action**, phrased so a successor who has read nothing
  else can start on it. Not "continue the work".
- **Read it back after writing.** A write returning success proves the call was
  accepted, not that the comment says what you think. Report what the re-read returned.
- **Append; never edit.** Older checkpoints are history. An agent that finds an earlier
  claim untrue verifies against the checkout and appends a **corrective** checkpoint
  carrying the evidence. The wrong entry plus its correction is a trail; a silently
  edited entry is a story.
- **The latest valid checkpoint is the last one in `bd comments` order** — never the one
  with the newest `updated_at`. That field is agent-authored and informational; ordering
  by it is how you resume from the wrong state. If the read path can't establish a
  unique last comment, stop: in the crew, have Quartermaster Mira append a reconciled
  checkpoint; as Michele, reconcile it yourself against the checkout and append a
  corrective one saying what you found ambiguous.
- **Never a free-form progress note instead.** The schema is what makes a checkpoint
  machine-findable and complete; prose is what people write when they're in a hurry and
  what nobody can recover from.
- **No secrets, no pane transcripts, no speculation.**

## When to write one

Immediately after claiming a bead and **before the first edit**; after every meaningful
phase or changed assumption; before anything long-running or crash-prone; and at every
verdict, rework round, landing, handoff, or abandonment.

## Who writes what

| Role | Writes | Notes |
|---|---|---|
| Navigator Odessa | `plan` / `ready`, on each bead she files | `next_action` is the first concrete thing the implementer should do |
| Engineer Jules | `work`, `rework`, `land` | The heaviest duty: one before her first edit, one per phase, a verified `land`/`landed` before closing |
| Auditor Rasma | nothing | She never writes the ledger; her verdict's target tuple is what the writer records |
| Quartermaster Mira | `reconcile` | May mechanically record a supplied review verdict as `review`, worded by others |
| Commander Pien | nothing | Reads and enforces: no stage advances until its owner has appended and read back a checkpoint |
| Michele | all of them | She owns every stage herself, so she writes every checkpoint her task passes through |

## Resuming from one

Read the latest valid checkpoint, then **verify its claims against the checkout, the
PR, and external reality before acting on any of them.** The checkpoint tells you what
the last session *believed*; the repository tells you what is true. Where they disagree,
append a corrective checkpoint, then continue from there.
