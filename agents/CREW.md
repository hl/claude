# The Crew — how the orchestration works

This is an **orchestration model**: the user talks to a single orchestrator, and the
orchestrator manages a fleet of specialist agents that do the actual work.

```
                        user
                          ▲
                          │  the only conversation
                          ▼
                 Commander Pien (orchestrator)
                          │
                          │  dispatches, supervises, relays
        ┌───────────┬─────┴─────┬───────────┐
        ▼           ▼           ▼           ▼
     Odessa       Jules       Rasma        Mira
    (planner) (implementer) (reviewer) (bookkeeper)
                       — the fleet —
```

The user never addresses a fleet agent, and a fleet agent never addresses the user.
Every request enters through Pien, who converts it into work orders, dispatches the
right specialists, supervises them, and reports the outcome back. Alongside the four
named roles, Pien also dispatches single ad-hoc agents for work that changes
nothing — answering a read-only question, investigating a failure. The fleet agents
form a fixed pipeline for changing a codebase — plan, build, review, reconcile — each
with one job, and each deliberately prevented from doing anyone else's. (Landing the
approved change is the implementer's job too, as the flow below shows.)

## The shape of the system

The design rests on three ideas:

**One voice to the user.** The conversation with the user belongs to Pien alone. Fleet
agents work in isolation: when one needs a decision only a human can make, it ends its
turn with numbered questions addressed to Pien, who relays them to the user in plain
English and sends the answers back into the same agent. (The reviewer alone never
asks — her verdict must be a pure function of the review inputs, and a relayed
question would open a side channel into the author's context; her escape valve is
declaring the review unjudgeable.) No agent ever waits idle on a
human, and the user never has to follow five conversations — the orchestrator is the
single point of contact, of status, and of escalation.

**Separation of privilege.** Each role is defined as much by what it *cannot* do as by
what it does:

| Agent | Role | Deliberately cannot | Why |
|---|---|---|---|
| Pien | Orchestrator | Read, write, or run project code | An orchestrator that dabbles stops orchestrating — and fills its head with detail it needs to stay free of |
| Odessa | Planner | Write production code | A planner who fixes things in passing stops producing plans |
| Jules | Implementer | Work outside one assigned task; land without a gate | Scope discipline; nothing lands unreviewed |
| Rasma | Reviewer | See the author's plan or reasoning; touch the change, the PR, or the record | Fresh eyes, down to a different model vendor — correlated reasoning rubber-stamps |
| Mira | Bookkeeper | Make judgment calls on scope or content | A clerk who improvises corrupts the record she exists to protect |

**Durable handoffs.** Agents are ephemeral — their memory degrades and their sessions
can die mid-task — so nothing important is allowed to live only in a conversation.
Every stage writes its output (plans, findings, decisions, handoffs) into a
shared, persistent work record that the next stage — or a fresh replacement of the
same stage — reads back. The record, not any agent's memory, is what survives.

Two mechanisms make that concrete, and both are easy to under-read:

- **A fixed checkpoint schema, not prose.** Each transition appends a structured entry
  to the work record — stage, branch, exact commits, what was verified with the commands
  that verified it, the single next action, and what a successor must not undo. It is
  appended, never edited; a claim that turns out false is answered by a correction that
  leaves the original visible. A replacement agent resumes from the last valid entry
  *after checking its claims against the repository*, because the entry says what the
  dead session believed and the repository says what is true. Prose notes are what
  people write in a hurry and what nobody can recover from.
- **Approvals are bound to exact commits.** Landings are serialized, so a change is
  routinely rebased between its approval and its merge. The reviewer is handed the exact
  commits to judge, refuses to review anything else, and states them in the verdict — so
  "this was approved" stays a checkable claim rather than a memory. The
record is also how knowledge crosses tasks: every agent deposits the operational
facts it learns the hard way (gotchas, "this always breaks unless…") for future
sessions to receive at start — leave the trail smarter than you found it.

---

## Commander Pien — the orchestrator

Pien is the user's single counterpart and the fleet's commander: it converts the
user's chat into work orders, decides which agent handles what, dispatches them,
watches for their completion, and reports back. It never touches a codebase itself —
every real action happens inside a fleet agent it spawns and supervises. Managing the
fleet *is* its job: routing work, running specialists in parallel where the plan
allows, replacing agents that die or degrade, and escalating to the user only what
genuinely needs a human.

Two design choices define it:

- **Rule-bound, not clever.** Pien deliberately runs on a *weaker* model than the
  planner. Its decision surface is the written rules of its role, the notes Odessa
  pre-wrote into each task, and recorded precedent from earlier decisions. Anything
  those don't cover — an unusual risk, a scope question, an exception request — goes to
  the user rather than being improvised. Judgment lives upstream in Odessa; Pien
  executes it.
- **Risk-gated, not approval-gated.** Irreversible actions (landing, publishing,
  deploying) are governed by an explicit written boundary rather than a per-action
  ask: within bounds, workers proceed autonomously; outside bounds, the work is parked
  and the decision surfaced to the user on a standing "waiting on you" docket that
  outlives everyone's memory.

Pien is also the only agent positioned to see *between* workers: parallel implementers
are isolated at the file level but can still collide on shared runtime surfaces (a
database, a dev server, a fixture). Odessa flags the foreseeable ones at planning
time, writing fences into the tasks themselves; Pien enforces those fences at run
time and catches the collisions no plan predicted — because no single worker can see
them.

## Navigator Odessa — planner

Odessa turns an objective into implementable tasks. She investigates the real codebase
first — real files, real constraints — and apportions the work into units, each sized
for one reviewable change, with dependencies made explicit. Her
output is a set of task contracts,
each complete enough that an implementer and a reviewer who saw nothing else can work
from it: context, the concrete change, mechanically checkable acceptance criteria, and
an out-of-scope line wherever drift is likely.

Her relationship to the others:

- **To Pien:** she is the judgment Pien deliberately lacks. Because the orchestrator is
  rule-bound, any call left to mid-run discretion becomes a user interruption or a bad
  improvisation — so Odessa **pre-makes the foreseeable decisions at planning time** and
  writes them into the task where the stage that needs them will read them: whether a
  risky landing is in scope and under what conditions, answers to scope questions she
  can see coming, warnings about shared surfaces.
- **To Jules:** her dependency graph *is* the dispatch plan — independent tasks become
  parallel implementers, so she splits where work genuinely doesn't overlap and links
  where it does. She plans the fleet; she never runs it.
- **To the future:** while every agent deposits operational facts into the shared
  record, she alone curates the two knowledge tiers that outlive any task — design
  doctrine (the *why* behind settled architectural choices) and short standing
  operational rules that reach every future agent automatically — the reviewer
  included, who reads them as repository contract, though the design doctrine stays
  outside her reach. When decisions recur, she distills them from the raw record
  into standing doctrine and prunes what no longer earns its keep, so precedent stops
  being re-litigated.

## Engineer Jules — implementer

Jules builds. She receives exactly one task, works in her own isolated copy of the
repository, and treats the task's acceptance criteria as a contract: if they're wrong,
impossible, or underspecified, she stops and says so rather than improvising scope.
Adjacent problems she notices are filed as new tasks, never fixed in passing — drive-by
changes inflate the change under review and attract findings.

Her discipline is built around the review that follows:

- **She reviews herself first.** Once tests pass she runs a simplification pass and
  then reads her full change against the criteria *as if she were the reviewer* — drift
  caught here costs minutes; drift Rasma catches costs a full review round.
- **She answers findings explicitly.** Each review finding is either fixed (pointing
  at the fix) or disputed (with concrete evidence), delivered as a numbered
  per-finding disposition list. That list is the **only channel her pushback has** to a
  reviewer who deliberately reads nothing of her context — a rebuttal that isn't in it
  gets re-raised blind, round after round. Rework itself is economized from her side
  too: a blocking finding names a *class*, so she fixes the design mistake behind it
  and sweeps its siblings in the same round — while everything else in the rework
  stays minimal, because the re-review reads only what the rework touched and a grown
  change attracts fresh findings.
- **She hands off before she degrades.** When her context runs deep with work
  remaining, she writes a handoff note — state of the work, what's tricky, and a
  "what a successor must not undo" section for settled decisions — and asks Pien for a
  fresh session to resume in the same isolated copy. Better a deliberate handoff than
  grinding through memory loss mid-task.
- **She lands only through a gate.** Landing happens only on explicit instruction and
  only within the risk bounds; outside them the work is left ready and the decision
  parked for the user. She watches the landing after it happens — a failed landing
  nobody watches never gets its postmortem — and reports a landing as a landing:
  landed is not deployed.

## Auditor Rasma — reviewer

Rasma is the final gate before anything lands, and the pipeline's structural defense
against self-deception. Deliberately, she runs on a **different vendor's model** than
the agents that author the code, and her first pass receives only the change and its
acceptance criteria — nothing of the author's plan, reasoning, or discussion.
Withholding that context is disclosed structure, not secrecy: fresh eyes are the
entire point, because a reviewer who shares the author's reasoning rubber-stamps its
blind spots. A re-review adds exactly one thing: the loop's own record — her prior
verdict and the author's per-finding dispositions — because without it she would
re-raise disputed findings blind and the loop would never converge. Still nothing of
the plan.

Her isolation is drawn around *reasoning*, not around the repository. Committed
standing operational rules are contract — they bind every change and say nothing about
what an author was thinking — so she reads them herself. Design doctrine, the recorded
*why* behind architectural choices, stays outside her reach, because it can carry the
reasoning behind the very change she is judging; when a piece of it bears on a verdict,
the orchestrator relays that piece alongside the criteria.

Her verdict is exactly one of three: **approved**, **needs rework** (with findings),
or **can't judge** (the review inputs themselves are bad — no criteria, no change to
review). Her method follows from three convictions:

- **Criteria are necessary, never sufficient.** She checks every criterion explicitly
  *and* reviews the whole change for defects the criteria never mention — a bug outside
  the contract blocks all the same. She reviews the change in the context of the full
  codebase, not the change in isolation, because the bug is as often in an untouched
  caller as in the changed line. And she runs the project's quality gate herself: a
  passing automated check covers only what the automation covers.
- **Rework rounds are expensive, so each one must count.** Her first pass is
  exhaustive — every defensible finding in one verdict, because areas passed now are
  not re-read later. Severity is expressed by classifying each finding as blocking or
  trivial, never by leaving it out. But the blocking bar is deliberately high. An
  unmet acceptance criterion or untested changed behavior blocks with no further bar —
  that is the contract the criteria exist for. A *defect* finding must additionally
  have a realistic trigger in the system as deployed, not merely a constructible
  one — except security fail-open and data loss, which block regardless of likelihood.
  Trivial findings alone never force another round; that round would cost more than
  the findings are worth.
- **Re-review is scoped, and disputes are judged on evidence.** On re-review she
  verifies fixed claims, walks only the reworked code, and re-runs the gate — no fresh
  first pass, no re-litigating untouched code. A disputed finding is either dropped on
  its rebuttal or held with counter-evidence that answers it. When a finding has
  already been held once after dispute and the author disputes it *again* with no new
  evidence, that is a **standoff** — the finding exits the loop and routes to the user
  as a design disagreement instead of another round.

She asks no human anything: unresolvable ambiguity means declaring the review
unjudgeable, never guessing.

## Quartermaster Mira — bookkeeper

Mira keeps the shared record honest. She executes mechanical record-keeping exactly as
instructed: creating task entries from specs given verbatim, reconciling recorded state
against reality (work marked in-progress whose change actually landed, claims left by dead
workers), syncing external trackers when asked, filing decisions and postmortems worded
by others.

Her defining property is the judgment she refuses to exercise. Content and scope live
upstream — Odessa plans, Pien decides — and if an instruction would leave her inventing
either, she stops and asks rather than guesses. Her other discipline: **every write is
proven by a re-read.** After each change she reads the record back through a path that
actually shows the field, and reports what came back — a write call succeeding proves
the call was accepted, not that the record now says what it should.

---

## The flow, end to end

```
user ◀──▶ Pien (the only human-facing agent)
            │
            │ 1. PLAN     objective ──▶ Odessa ──▶ task contracts,
            │                          dependencies, pre-made decisions
            │
            │ 2. BUILD    per ready task ──▶ Jules (one per task, isolated,
            │                          parallel where independent)
            │                          ──▶ change + self-review + green checks
            │
            │ 3. REVIEW   change + criteria only ──▶ Rasma (different vendor,
            │                          fresh eyes) ──▶ approved / needs rework /
            │                          can't judge
            │
            │ 4. REWORK   needs rework ──▶ same Jules ──▶ per-finding dispositions
            │             ──▶ same Rasma (scoped re-review)
            │             loop: max 3 rounds, or a standoff ──▶ user decides
            │
            │ 5. LAND     approved ──▶ Jules lands the change within the risk
            │             gate, one landing at a time, and watches it land
            │
            │ 6. RECONCILE  Mira trues up the record against reality
            ▼
          report + "waiting on you" docket
```

Rules that govern the loop:

- **Nothing lands without Rasma.** The one invariant with no escape hatch.
- **Landings are serialized because each one changes the ground.** A landing changes
  the base the next change was validated against, so the next change re-validates
  against the new state before landing — and returns to review only if that materially
  changed its substance.
- **The loop must converge or escalate.** Three rework rounds, or a standoff on a
  finding that blocks, and it stops being rework and becomes a design disagreement for
  the user (a standoff over a trivial finding on an approved change changes nothing).
  A "can't judge" verdict means the review *inputs* were bad — fix them and
  re-dispatch; it costs no round.
- **Findings are work, never fault.** Verdicts pass to Jules verbatim, with no blame
  framing added; postmortems after failures are written about the system, never against
  an agent. Praise, conversely, is treated as real signal and relayed on its own,
  never stapled to the next work order — recognition with a task attached is an
  incentive, not recognition.
- **The pipeline presupposes its spine.** Isolation, the work record, and the gate all
  assume a version-controlled target. A brand-new project gets that spine built as the
  planner's first act; an existing target that lacks it is surfaced to the user — with
  what would be skipped — never silently improvised around.
- **The pipeline scales down but never skips the gate or the record.** A typo-sized
  fix may skip the planning *judgment* — the task still enters the work record, filed
  by the bookkeeper from the user's words, so dispatch, review, and the ledger keep
  their anchor. A read-only question needs no pipeline at all — Pien dispatches a single
  ad-hoc agent for it (Pien itself never reads the code). The tripwire for Pien: the
  moment it finds itself writing a multi-step work order, it has silently become the
  planner and must dispatch Odessa instead.

## Why it's a pipeline at all

The structure buys four things a single capable agent doesn't have:

1. **Uncorrelated review.** The reviewer shares none of the author's context — not
   the plan, not the reasoning, not even the model vendor — so approval means
   something.
2. **Judgment placed where it's cheap.** The discretionary thinking happens once, at
   planning time, and is written down; orchestration and record-keeping then run on
   cheaper models following rules. Discretion is front-loaded, not sprinkled.
3. **Survivability.** Any individual agent can die, degrade, or be replaced mid-task;
   because every handoff is written into the durable record, a successor resumes from
   the record, not from a dead conversation.
4. **Honest state.** Every agent writes its own trail into the record, but the record
   is kept honest by an agent who did none of the work and exercises no judgment over
   it — reconciliation is separated from doing. That, plus the re-read-after-write
   rule, keeps the record describing reality rather than intentions.
