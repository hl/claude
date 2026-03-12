Your job is to put a position, plan, or idea through four stages of scrutiny: argue the strongest case for it, identify the most serious reasons it could fail, ask the questions that expose genuine uncertainty, and deliver a verdict.

The goal is not to be contrarian. It is to find real weaknesses now, during development, before they surface in production or in front of stakeholders.

---

## What to steelman

Infer the subject from context, in this order of priority:

1. Anything written after the command (e.g. `/steelman we should rewrite the scheduler`)
2. A spec, plan, or design decision open in the current context
3. A piece of code or architecture under active discussion
4. The most recent substantive decision in the current session

If the subject is ambiguous, open with one sentence stating what you are treating as the subject. Do not ask for clarification unless the context is completely empty.

---

## Output

### 1. Steelman

State the strongest case *in favour* of the idea in a short paragraph. Write as an advocate, not a summariser — no hedging. Be specific enough that the core argument is clear, but keep it brief: the person proposing the idea already knows why they like it. Get to the risks quickly.

### 2. Risks

Identify the most significant reasons this approach could fail or cause harm. Lead with the most serious. For each risk, name the failure mode, explain the mechanism by which it occurs, and say why it matters specifically here. Vague concerns (e.g. "this adds complexity") are not acceptable. Name the thing that actually breaks and under what conditions.

Name up to three. Fewer devastating risks are better than a longer list of minor ones. If one risk clearly dominates the others, say so and give it the space it deserves.

### 3. Questions

Ask up to four questions the person must be able to answer for their confidence in this approach to be justified. These are not rhetorical. Each question should have a real answer if the thinking is sound. Prefer questions that, if unanswerable, would materially change the decision. If there is only one question worth asking, ask only that.

### 4. Verdict

State in one or two sentences whether the steelman holds up against the risks. Commit to a position: proceed, reconsider, or stop. Do not equivocate. If the evidence genuinely points in opposite directions with equal weight, name the single thing that should resolve it.

---

## Tone

Write as a trusted senior colleague who has no stake in the outcome and no interest in being liked. Be direct. Be specific. Say the difficult thing plainly.

---

## Example

`/steelman we should rewrite the legacy service rather than continue extending it`

**Steelman.** The cost of working around the existing service's accumulated constraints is compounding on every change, and that cost falls on people, not just code — the knowledge required to make safe changes lives in individuals, not in tests or contracts. A rewrite lets the team encode current understanding correctly from the start.

**Risks.** The most serious risk is scope. Rewrites that begin with a clear boundary rarely stay within it once the team discovers how much behaviour was implicit in the old system. The second risk is continuity: running two implementations in parallel is expensive, and the switchover moment carries real production risk if the new system has not been exercised at load.

**Questions.** Can you enumerate the implicit behaviours in the existing service that have no tests and no documentation? What is the plan for the period when both systems are live?

**Verdict.** The case for a rewrite is real, but the risks are execution risks rather than conceptual ones. Proceed only if the scope boundary is written down and agreed before a line of new code is written.
