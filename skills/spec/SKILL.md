---
name: spec
description: Guides spec-driven development through design (plan mode), task creation, implementation, and technical specification writing. Use when implementing features with full documentation and review cycles.
---

# Spec-Driven Development Workflow

This skill guides spec-driven development using plan mode for design and autonomous execution for implementation. The design document is a transient planning artifact; the technical specification is the persisted deliverable.

## Workflow Structure

**Plan Mode (Phase 1)**: Design and get approval

- When this skill is invoked, first perform the pre-workflow check, then call EnterPlanMode to begin the design phase
- Capture "what" (problem, decision, tradeoffs) before "how" (detailed design)
- Use subagent for design review, then call Codex MCP directly for external review
- Exit plan mode via ExitPlanMode when design is ready

**Execution (Phases 2-4)**: Implement after approval

- Create tasks, implement (with TDD when appropriate), commit incrementally
- Technical specification is the only persisted design document
- Spec captures key decisions for long-term reference

**Phase Skipping**: Match workflow complexity to change complexity:

- **Skip Phase 1** (including Codex review) if the change doesn't require design decisions (single-file fixes, obvious implementations)
- **Skip Phase 2 subagent preparation** for simple, well-understood tasks
- **Skip Phase 4** if the change is minor: fewer than 50 lines changed, affects 1-2 files, no API changes, and no architectural decisions

## Operating Principles

- Use the Task tool to launch subagents for review and validation
- **Call MCP tools directly** — never delegate MCP tool calls (like `mcp__codex__codex`) to subagents. Call them in the main conversation.
- Iterate on designs with a maximum of 3 review cycles (see "Review Cycle Definition" below)
- Only use AskUserQuestion when genuine ambiguity cannot be resolved through analysis
- When asking questions, provide a recommended answer with detailed reasoning
- Make decisions confidently based on codebase patterns and best practices
- Use TaskCreate/TaskUpdate/TaskList to track all work
- Commit after each completed task with working code
- Respect risk boundaries: ask before data deletion, destructive git operations, or external network calls not required for the task
- Use the Write tool for file creation (never cat/heredoc in Bash)

**Review Cycle Definition**: A review cycle is a complete subagent review round where feedback is returned and addressed. Minor inline fixes (typos, formatting) made during implementation don't count as cycles. Only full subagent invocations that return substantive feedback count toward the 3-cycle limit.

## Using AskUserQuestion

Only use the AskUserQuestion tool when:

- There are genuinely multiple valid approaches with significantly different tradeoffs
- The decision impacts user-facing behavior or API design in non-obvious ways
- There's ambiguity in requirements that cannot be resolved by examining existing code or specs
- A decision requires domain knowledge that isn't present in the codebase
- Design review iterations have not converged after 3 cycles
- Conflicting review feedback cannot be resolved by examining project patterns

When asking questions:

- Provide a clear recommended answer
- Explain in detail why this is the recommended approach
- Outline the alternatives and why they're less suitable
- Include enough context that the user can make an informed decision quickly
- Reference relevant code, specs, or patterns

Example format:

```
Question: Should we store user preferences in the database or in a separate config file?

Recommended: Database

Reasoning:
- User preferences are user-specific data that changes at runtime
- The existing UserSettings module already has database-backed storage patterns
- Enables preferences to sync across devices (a likely future requirement)
- Fits the existing data access patterns used throughout the codebase
- Transactional updates are important for consistency with other user data

Alternative: Config file (JSON/YAML)
- Would be simpler for single-user scenarios
- Faster reads without database overhead
- But doesn't scale to multi-device usage
- Would require separate backup/sync mechanism
- Inconsistent with how other user data is stored
```

## Pre-Workflow Check

Before calling EnterPlanMode, perform these checks:

1. Search for existing specifications related to the feature or module
2. Review existing specs to understand current architecture and decisions
3. Check for related documentation in README files or module docs
4. Determine the project's specification location convention by examining existing specs
5. Identify any existing patterns or conventions that should be followed
6. Assess test infrastructure and test-appropriateness for this change (see "Test Appropriateness" below)

**Test Appropriateness**: Not all changes warrant TDD. Assess based on:

- **TDD appropriate**: Business logic, algorithms, data transformations, API endpoints, stateful components
- **TDD less appropriate**: Configuration files, documentation, pure refactoring with existing test coverage, UI styling, static content
- **No tests needed**: Trivial changes, typo fixes, comment updates

**Greenfield Projects**: If no specifications exist, the first spec establishes conventions. See "Specification Location" in Phase 4 for directory selection logic.

## Workflow Phases

### Phase 1: Design — Plan Mode

Write the design in the plan file, structured as "what" then "how":

**Part A: Problem & Decision (What)**

- **Context**: What problem are we solving? What's the business or technical driver?
- **Decision**: What approach are we taking at a high level?
- **Consequences**: What are the tradeoffs? What does this enable or constrain?
- **Alternatives considered**: What other approaches did we consider and why did we reject them?

**Part B: Detailed Design (How)**

- **Scope**: Exactly what are we building? What's explicitly out of scope?
- **User/Developer experience**: How will this be used? What's the API or interface?
- **Architecture**: What modules, processes, or components are involved? How do they interact?
- **Data model**: What structures or schemas do we need? What are the key types?
- **Error handling**: What can go wrong? How do we handle errors and edge cases?
- **Performance considerations**: Any scalability, concurrency, or performance concerns?
- **Dependencies**: What existing code does this interact with? What new libraries might we need? (Flag if project CLAUDE.md restricts new dependencies)
- **Migration path**: If changing existing functionality, how do we migrate? What's the rollback strategy?
- **Testing approach**: What needs testing? What types of tests are appropriate? (Reference pre-workflow test assessment)
- **Documentation updates**: What README files, guides, or module docs need updating?

**Design Review**: Launch a subagent (`subagent_type: "general-purpose"`) to critically evaluate the design.

Example prompt:

```
Review this design critically. Look for:
- Better alternatives not yet considered
- Unclear tradeoffs
- Misalignment with existing project architecture
- Gaps or unhandled error cases
- Simpler ways to achieve the goal

[paste design content]
```

Iterate based on review feedback for a maximum of 3 cycles. If fundamental issues remain, use AskUserQuestion to resolve. Complete all internal iterations before proceeding to Codex review.

**Plan Review (Codex)** — After internal design review converges, call `mcp__codex__codex` **directly** (never via subagent) to get external review. This is a single-pass final check, not an iteration loop.

Steps:

1. Call `mcp__codex__codex` directly with the design content
2. Include focus areas in the prompt: architectural concerns, potential issues, better alternatives, best practices alignment
3. Classify feedback as CRITICAL (blocking) or ADVISORY (note for implementation)
4. Show the actual Codex response to maintain transparency

Example prompt for `mcp__codex__codex`:

```
Review this design for [feature]. Focus on architectural concerns, potential issues, and best practices.

[paste design content here]
```

**Error Handling**: If the Codex MCP call fails:

- **Tool not available** (MCP not configured): Report to user and use AskUserQuestion to ask whether to proceed without external review
- **Timeout or error**: Report the error and use AskUserQuestion with options: (1) retry once, (2) proceed without external review

If user chooses retry and it fails again, proceed without external review (don't ask again).

**Handling Codex Feedback** (no ping-pong):

- **CRITICAL issues**: Address in the design, then proceed. Do NOT re-run internal design review or Codex. If the critical issue fundamentally changes the design, escalate to user.
- **ADVISORY feedback**: Note in the plan for consideration during implementation. Do not iterate.

Codex review runs exactly once. After addressing any critical feedback, proceed to Exit Plan Mode.

**Handling Conflicting Reviews**: When internal design review and Codex review give contradictory feedback:

1. Prefer the recommendation that aligns with existing project patterns
2. If both are equally valid, choose one with explicit reasoning documented in the plan
3. If the conflict is fundamental (mutually exclusive approaches), use AskUserQuestion

**Exit Plan Mode**: Use ExitPlanMode to get user approval before proceeding to implementation. If the user rejects the plan, incorporate their feedback and iterate on the design (this counts toward the 3-cycle limit).

### Phase 2: Task Creation and Preparation — Post-Approval

Analyze the complete design and break down all work into concrete tasks upfront:

- Each task should be atomic and result in working code (tested when appropriate)
- Tasks should reference specific parts of the design
- Order tasks by dependencies (what needs to happen first)
- Include documentation update tasks
- Be specific about file locations and what needs to change

Note: The specification (Phase 4) is handled separately after all implementation tasks complete — do not create a task for it.

**Create all tasks upfront** using TaskCreate before beginning any implementation. This provides complete visibility, proper dependency ordering, clear progress tracking, and ability to resume if interrupted.

**Task Complexity Assessment**: A task is considered complex if it:

- Affects multiple modules or system boundaries
- Introduces new architectural patterns
- Has unclear implementation path
- Involves significant refactoring

**Subagent Task Preparation**: After all tasks are created, launch subagents for complex tasks:

- Use `subagent_type: "Explore"` (see Subagent Strategy for fallback)
- Launch subagents in parallel for independent tasks to reduce overhead
- For dependent tasks, prepare them sequentially in dependency order
- Each subagent should analyze files to create/modify, identify code to understand, draft test cases, plan implementation approach, and identify potential issues
- If preparation reveals design flaws, pause and return to Phase 1 or use AskUserQuestion

**Task List Adjustments**: During implementation, if you discover that additional tasks are needed, tasks need to be split or combined, the order needs adjustment, or tasks are no longer needed — use TaskCreate, TaskUpdate, and TaskList to add, modify, or track tasks as appropriate. Document significant changes in commit messages or the final specification.

**Task Creation Verification**: After creating tasks, verify completeness:

- Count the created tasks and compare against the numbered items in the implementation plan
- Ensure every implementation item in the plan has a corresponding task
- If any tasks are missing, create them before proceeding

**Parallelization Checkpoint** (conditional): If 5 or more tasks were created, use AskUserQuestion to ask whether to continue with sequential implementation or stop here for parallel sessions. If fewer than 5 tasks, proceed directly with sequential implementation.

If stopping for parallelization, remind the user that each parallel session should claim a task via TaskUpdate (set owner) before starting work to avoid conflicts.

### Phase 3: Test-Driven Implementation — Execution

For each task:

1. **Mark task in progress**: Use TaskUpdate to set status to `in_progress`
2. **Write tests first** (when appropriate): Create tests based on the design and task preparation. Skip if pre-workflow check determined tests aren't appropriate for this change type.
3. **Run tests**: Verify they fail appropriately (red phase)
4. **Implement**: Write the minimum code to make tests pass (green phase)
5. **Refactor**: Clean up code while keeping tests green
6. **Run full test suite**: Ensure no regressions
7. **Update documentation**: Modify relevant README files, guides, or inline docs
8. **Code review**: For non-trivial changes, launch a subagent (`subagent_type: "pr-review-toolkit:code-reviewer"`) to check for quality issues, edge cases, or improvements (see Subagent Strategy for fallback). Skip for trivial changes.
9. **Address review feedback**: Make any necessary changes, then re-run tests if changes were substantive
10. **Commit**: Create atomic commit with descriptive message
11. **Mark task completed**: Use TaskUpdate to set status to `completed`

**Projects Without Test Infrastructure**: If the pre-workflow check found no test infrastructure, skip steps 2-3 and 6. Implement directly and verify manually. Do not introduce test infrastructure unless the user requests it.

Commit messages should reference design decisions or task context where relevant. Example:

```
feat(auth): implement token refresh logic

Uses short-lived access tokens with refresh tokens for security.
```

**Failure Handling**: If tests fail during implementation:

- First attempt to fix the issue
- If the fix requires rethinking the approach, update the task and document the deviation in the commit message or specification
- If the failure reveals a fundamental design problem, pause and use AskUserQuestion
- Never commit failing tests

**Rollback Strategy**: If implementation proves fundamentally flawed mid-task:

1. Use `git stash` or `git checkout` to preserve or discard work in progress
2. Mark the task as `pending` with updated description noting the issue
3. Use AskUserQuestion to determine whether to redesign, take an alternative approach, or abandon the feature
4. Do not leave the codebase in a broken state

**Test Sequencing**: Execute implementation tasks sequentially. Subagents are used for review and preparation, not parallel implementation. Sequential execution avoids test suite conflicts and ensures each task builds on verified, working code.

**Interruption Handling**: If work is interrupted mid-implementation:

- Use TaskList to see current state and identify the in-progress or next pending task
- Read task details with TaskGet before resuming
- Check git status for uncommitted work:
  - If changes are complete for the task: commit them
  - If changes are partial but stable: stash and note in task description
  - If changes are broken: discard with `git checkout`
- Resume by completing the current task or starting the next pending one

**Completion Verification**: Before proceeding to Phase 4:

- Run TaskList and verify all tasks are marked `completed`
- If any tasks remain `pending` or `in_progress`, complete them first
- Do not proceed to specification writing until all tasks are done

### Phase 4: Technical Specification — Final Deliverable

**Skip Threshold**: Skip this phase entirely if ALL of the following are true:

- Fewer than 50 lines changed total
- Only 1-2 files affected
- No new APIs or interfaces introduced
- No architectural decisions made
- No design tradeoffs worth documenting

For changes that meet this threshold, the commit messages serve as sufficient documentation.

**When to Write a Spec**: Proceed with specification if ANY of these apply:

- New module or significant new functionality
- API changes that other code will depend on
- Architectural decisions with tradeoffs
- Complex logic that future maintainers need to understand
- Changes that affect multiple modules

**Note**: If Phase 1 was skipped but the implementation warrants documentation, write the spec based on the implementation itself — the spec writer subagent will read the code directly.

After all implementation tasks are complete, launch a subagent (`subagent_type: "general-purpose"`) to generate the technical specification.

This is the only persisted design document. It captures key decisions for long-term reference.

**Specification Writer Subagent**: Example prompt:

```
Write a technical specification for [feature].

1. Review existing specs in the project to match format and style
2. Read the implemented files to understand the architecture
3. Place the spec following project conventions (see Specification Location)
4. Include: Header, Overview, Architecture, API/Interface, and other relevant sections
5. Link to related specifications

Key decisions: [summarize design rationale]
Files implemented: [list of files]
```

**Post-Generation Review**: After the subagent returns:

- Read the generated specification file
- Verify it accurately reflects the implementation
- Check that all required sections are present and complete
- Ensure links to related specs are valid
- Make any necessary corrections before committing

**Error Recovery**: If the spec writer subagent fails or produces inadequate output:

- Review the subagent's partial output or error message
- Either fix the issues directly or re-launch with a more specific prompt
- For repeated failures, write the specification manually using the template below

**Specification Location**: Determine by examining existing specs:

1. **Existing specs exist**: Follow the established pattern
2. **No specs, but docs directory exists** (`docs/`, `documentation/`, `doc/`): Create specs subdirectory there
3. **Greenfield**: Create `docs/specs/` and document this in project README or CLAUDE.md

Common patterns:
- `docs/specs/[feature-name].md` — centralized
- `lib/[module]/specs/[feature-name].md` — module-local
- `[module]_spec.md` — alongside implementation

**Specification Template**:

| Section | Contents |
|---------|----------|
| **Header** | Feature name, dates (created/updated), status (`draft`/`in-progress`/`implemented`/`deprecated`/`superseded`), related specs |
| **Overview** | What it does (2-3 sentences), why it exists (decision rationale) |
| **Architecture** | Modules and responsibilities, interactions, design decisions/tradeoffs, rejected alternatives |
| **API/Interface** | Function signatures, inputs/outputs, usage examples, error responses |
| **Data Structures** | Schemas, type definitions, validation rules |
| **Error Handling** | Possible errors, handling strategies, recovery |
| **Dependencies** | Related specs/modules, external dependencies, version requirements |
| **Testing** | Strategy, key test cases, coverage expectations |
| **Future Considerations** | Limitations, potential enhancements, technical debt |
| **Change History** | Date/author/summary of changes, PR/commit links |

Commit the specification with message format:

```
docs(spec): add specification for [feature-name]

Captures architecture decisions, API design, and implementation
details for future reference and LLM context.

Related to: [original feature request or ticket]
```

**Scaling for Smaller Features**: For straightforward features, only include sections that provide value. Minimum required: Header, Overview. Include API/Interface if there's a public interface, Change History if updating an existing spec. Other sections can be omitted when the feature is simple.

### Specification Updates

When Phase 4 involves updating an existing specification (identified during pre-workflow check):

1. Launch a subagent (`subagent_type: "Explore"`) to review the existing spec and current implementation to identify differences (see Subagent Strategy for fallback)
2. Update the existing spec to reflect changes (do not create a new spec)
3. Preserve the history by adding update notes with dates in the "Change History" section
4. Update the "Last updated" field and status if applicable
5. Ensure bidirectional links between related specs remain valid
6. Commit the updated specification

For substantial changes that alter the spec's core architecture, consider creating a new spec and marking the old one as `superseded`.

### Specification Deprecation

When a specification is no longer relevant:

**Mark as Deprecated** when:

- The feature still exists but is discouraged for new use
- A better alternative exists but migration isn't complete

Process:

1. Update status to `deprecated`
2. Add deprecation notice at the top of the spec with reason and alternative
3. Link to the replacement spec or approach
4. Add entry to Change History

**Mark as Superseded** when:

- A new spec fully replaces this one
- The old approach is no longer valid

Process:

1. Update status to `superseded`
2. Add supersession notice: "Superseded by [new-spec-link] on [date]"
3. Keep the old spec for historical reference (do not delete)
4. Ensure the new spec links back to this one in its "Related specifications"

## Subagent Strategy

Use the Task tool to launch subagents for:

| Purpose | Subagent Type | Fallback |
|---------|---------------|----------|
| Design Review | `general-purpose` | N/A (always available) |
| Task Preparation | `Explore` | `general-purpose` with prompt: "Explore the codebase to analyze files to create/modify, identify relevant code patterns, and draft an implementation approach." |
| Code Review | `pr-review-toolkit:code-reviewer` | `general-purpose` with prompt: "Review this code for quality issues, edge cases, adherence to project conventions, and potential improvements." |
| Specification Writing | `general-purpose` | N/A (always available) |

**Direct calls (never via subagent)**:

| Purpose | Tool |
|---------|------|
| Codex Review | `mcp__codex__codex` |

Do not use subagents for:

- **MCP tool calls** — call MCP tools directly in the main conversation
- Parallel implementation of tasks (causes test suite conflicts; subagents are for review/preparation only)
- Trivial changes (single-line fixes, simple renames)
- Decisions that can be made by examining project conventions
- Simple questions answerable by reading code directly

## Quality Standards

**Phase 1 → Phase 2**:
- Design review subagent finds no critical issues (minor issues acceptable after 3 iterations)
- Codex MCP review completed (direct call), OR user explicitly approved skipping
- User approved plan via ExitPlanMode

**Phase 2 → Phase 3**:
- All tasks created and verified against implementation plan
- Complex tasks prepared via subagents

**Phase 3 → Phase 4**:
- All tasks marked `completed`
- All tests pass (if tests were written)
- Code follows project conventions and passes code review
- Documentation is updated

**Phase 4 completion**:
- Specification accurately reflects implementation
- All commits have descriptive messages

## Handling External Dependencies

When the design requires new external dependencies:

1. Check project CLAUDE.md for dependency restrictions
2. If restrictions exist, surface the conflict: "Design requires [dependency] but project restricts new dependencies. Options: [alternatives without dependency] or [request exception]."
3. Use AskUserQuestion to resolve
4. Document the decision in the specification

When adding approved dependencies:

- Use the project's package manager (detect from lockfiles: package-lock.json, yarn.lock, pnpm-lock.yaml, Cargo.lock, etc.)
- Pin versions appropriately for the project's convention
- Document new dependencies in the specification's "Dependencies" section

## Usage

Invoke this skill with `/spec [description]`.

**New feature implementation**:

```
/spec add user authentication with OAuth2
```

The agent handles: spec lookup, design, reviews, task creation, implementation, code reviews, commits, documentation updates, and specification writing.

**Update existing feature**:

```
/spec update the authentication module to support MFA
```

The agent finds and analyzes any existing spec, plans changes, implements, updates documentation and specs, all with appropriate reviews.

## Integration with Claude Code

- **Plan mode**: Design (what + how) is written in the plan file, reviewed via subagent + direct Codex call, approved via ExitPlanMode
- **Execution**: TaskCreate/TaskUpdate/TaskList track implementation; Task tool launches review subagents
- **Deliverable**: Technical specification is committed as the long-term design record
- Specifications become the primary context for future work

The user provides the initial feature request and approves the plan. Implementation proceeds autonomously with subagents ensuring quality.

## Precedence

This workflow operates within constraints set by:

1. Direct user prompts (highest priority)
2. Project-level CLAUDE.md (project-specific constraints)
3. Global CLAUDE.md (user defaults)
4. This skill (workflow guidance)

When project CLAUDE.md specifies constraints (e.g., "no new dependencies"), respect them even if they limit implementation options. Surface conflicts rather than silently violating constraints.
