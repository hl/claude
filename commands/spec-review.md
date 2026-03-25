---
description: Review all specs in docs/specs/ for gaps, contradictions, and inconsistencies using parallel sub-agents and Codex
---

You are a spec review coordinator. Your job is to find real problems in the spec files — missing schemas, contradictions between files, and internal inconsistencies — then fix them autonomously.

## Locate specs

1. Find the specs directory. If `$ARGUMENTS` is provided, use it as the specs path. Otherwise check `docs/specs/`, then `specs/`. If no specs directory exists, stop and say so.
2. List all spec files (`.md`, `.yaml`, `.yml`, `.json`).

## Review (round 1) — dual review

Run two independent reviews **in parallel**:

### Claude review
Partition the spec files into groups of 3-4. For each group, spawn a sub-agent **in parallel** with this prompt:

> Review these spec files for:
> - Missing schemas or undefined references (a spec mentions a type, endpoint, or field that is never defined anywhere in the specs)
> - Contradictions between files (conflicting field names, types, status codes, flows)
> - Internal inconsistencies within each file (e.g. an example that doesn't match the schema it illustrates, a flow that references a step not defined)
>
> For each issue found, output a JSON array of objects with these fields:
> `{ "file": "<path>", "line": <number or null>, "issue": "<description>", "severity": "high|medium|low", "suggested_fix": "<what to change>" }`
>
> **Reporting threshold — read carefully:**
> Only report issues that would **block or break implementation**. This means:
> - A developer following the spec would write incorrect code, or
> - A developer following the spec would not know what to write because the spec is ambiguous or incomplete on a decision that matters, or
> - Two specs give conflicting instructions for the same thing
>
> Do NOT report:
> - Edge cases the spec doesn't mention (silence is not a bug — specs don't need to enumerate every scenario)
> - "What if" concerns or hypothetical failure modes
> - Style, formatting, or wording preferences
> - Missing error handling unless the spec explicitly defines a flow that has no error path
> - Suggestions for additional features or improvements
>
> If you are unsure whether something is a real issue, leave it out. Err on the side of fewer, higher-confidence findings.

Pass each sub-agent the full text of its assigned spec files, plus the full text of ALL other spec files as cross-reference context.

### Codex review
Call the Codex MCP tool with a prompt asking it to review ALL spec files for the same criteria (missing schemas, contradictions, internal inconsistencies). Include the same reporting threshold: only issues that would block or break implementation — no edge cases, no "what if" concerns, no suggestions. Ask it to output findings in the same JSON format: `{ "file", "line", "issue", "severity", "suggested_fix" }`. Set the `cwd` to the project root and `sandbox` to `read-only` so Codex can read the spec files but not modify them.

## Consolidate and apply

Collect results from both Claude sub-agents and Codex. Merge all findings into one list:
- Deduplicate overlapping findings (same file + same issue from different reviewers)
- When both reviewers flag the same issue, prefer the more specific suggested fix
- When only one reviewer flags an issue, include it but note which reviewer found it
- **Drop any finding that is a hypothetical edge case, a "what about X" suggestion, or a concern about something the spec simply doesn't cover.** A spec not mentioning something is not a bug — only report things that are actively wrong or genuinely ambiguous enough to block implementation.
- Sort by severity (high first)

Apply all fixes directly — do not ask for confirmation. Only ask the user if a fix requires a judgment call that cannot be resolved from the specs alone (e.g. two specs contradict each other and there is no way to determine which is correct).

## Review-fix loop (up to 4 rounds)

After applying fixes, spawn one review sub-agent across ALL spec files to check for remaining issues using the same criteria. If new issues are found, fix them and review again. Repeat up to 4 total rounds. Stop early if a round finds zero issues.

## Output

End with a summary:
- Total issues found across all rounds (with breakdown: Claude-only, Codex-only, both)
- Issues fixed
- Issues that required user input (if any)
- Issues remaining (if any), with explanation
- Number of review rounds completed
