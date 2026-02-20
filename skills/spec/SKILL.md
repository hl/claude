---
name: spec
description: Guides feature development through design (plan mode), implementation, and technical documentation. Use when implementing features with full documentation and review cycles.
---

# Feature Development Workflow

## Design

Enter plan mode and write a design. Structure it as:

**Part A — Decision** (user-facing; keep tight):
- Context: why this is being built
- Decision: what we're doing, in one paragraph
- Consequences: what changes, what gets harder
- Alternatives: what was considered and rejected

**Part B — Implementation Notes** (agent-facing):
- Scope, interfaces, architecture, data model, error handling, dependencies, testing

Call ExitPlanMode and wait for explicit user approval before proceeding. Always do this — do not skip based on autonomy settings in CLAUDE.md.

## Implementation

Implement the feature.

## Documentation

If the change introduces new APIs, architecture, or non-obvious behavior, write a spec at `docs/specs/<feature-name>.md` (or follow the project's established pattern).

**Spec template**:

```markdown
# [Feature Name]

[1-2 sentence description of what this component does and why it exists. Link to related specs if relevant.]

## Overview

[What it does, how it fits in. Include a mermaid diagram for non-trivial flows.]

## [Section per major concept]

[Use tables for structured data (fields, operations, complexity). Use code blocks for data structures and examples. Call out invariants inline: **Invariant**: ...]

## Related Specifications

- [`other-spec.md`](other-spec.md) — [one-line description]
```

Sections to include where applicable: data structures/types, key operations, algorithms/protocols, error handling, performance characteristics, configuration.
