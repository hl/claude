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
- Use subagents to review and iterate
- Exit plan mode via ExitPlanMode when design is ready

**Execution (Phases 2-4)**: Implement after approval

- Create tasks, implement (with TDD if test infrastructure exists), commit incrementally
- Technical specification is the only persisted design document
- Spec captures key decisions from the plan for long-term reference

**Phase Skipping**: For trivial changes (single-file fixes, obvious implementations):

- Skip Phase 1 if the change doesn't require design decisions
- Skip Phase 2 subagent preparation for simple, well-understood tasks
- Skip Phase 4 if the change is trivial and doesn't warrant spec documentation

## Operating Principles

- Use the Task tool to launch subagents for review and validation
- Iterate on designs with a maximum of 3 review cycles (escalate via AskUserQuestion if fundamental issues remain)
- Only use AskUserQuestion when genuine ambiguity cannot be resolved through analysis
- When asking questions, provide a recommended answer with detailed reasoning
- Make decisions confidently based on codebase patterns and best practices
- Use TaskCreate/TaskUpdate/TaskList to track all work
- Follow TDD when test infrastructure exists; otherwise implement directly
- Commit after each completed task with working code
- Respect risk boundaries: ask before data deletion, destructive git operations, or external network calls not required for the task
- Use the Write tool for file creation (never cat/heredoc in Bash)

## Pre-Workflow Check

Before calling EnterPlanMode, perform these checks:

1. Search for existing specifications related to the feature or module
2. Review existing specs to understand current architecture and decisions
3. Check for related documentation in README files or module docs
4. Determine the project's specification location convention by examining existing specs
5. Identify any existing patterns or conventions that should be followed
6. Check if the project has test infrastructure (determines whether TDD applies)

**Greenfield Projects**: If no specifications exist:

- Create `docs/specs/` as the specification directory
- Document this convention in the project README or CLAUDE.md
- The first spec establishes the format for future specs

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
- **Dependencies**: What existing code does this interact with? What libraries might we need?
- **Migration path**: If changing existing functionality, how do we migrate?
- **Testing approach**: What needs testing? What types of tests are appropriate?
- **Documentation updates**: What README files, guides, or module docs need updating?

**Design Review**: Launch a general-purpose subagent (via Task tool with `subagent_type: "general-purpose"`) to critically evaluate the design:

- Are there better alternatives we haven't considered?
- Are the tradeoffs clearly understood?
- Does this align with existing project architecture and specifications?
- Are there gaps in the design or unhandled error cases?
- Is the testing approach comprehensive?
- Are there simpler ways to achieve the same goal?

Iterate based on review feedback for a maximum of 3 cycles. If fundamental issues remain, use AskUserQuestion to resolve.

**Plan Review (Codex)** — REQUIRED: After the design review subagent completes, you MUST launch a general-purpose subagent to get an external review from the Codex MCP server. This step cannot be skipped. The subagent must:

1. Read the complete design from the plan file
2. Call the `mcp__codex__codex` tool to submit the design for review
3. **Capture the `sessionId`** from the response's `_meta` field (this is the Codex session identifier)
4. Return to the parent agent with:
   - The **`sessionId`** (required — this proves the MCP was called)
   - Codex's feedback summary
   - Any critical issues that require design iteration

Example prompt for the subagent:

```
You MUST call the mcp__codex__codex tool to review this design. Do NOT skip this step or simulate the response.

Submit this design for review:
[design content]

Focus areas: architectural concerns, potential issues, better alternatives, best practices alignment.

IMPORTANT: Extract and return the `sessionId` from the response's `_meta` field. This is required proof that the MCP was called and enables follow-up queries via `mcp__codex__codex-reply`.
```

**Verification**: If the subagent returns without a valid Codex `sessionId`, the review did not happen. Re-launch the subagent with explicit instructions to call `mcp__codex__codex` and return the `sessionId` from `_meta`.

If Codex identifies significant issues, iterate on the design (counts toward the 3-cycle maximum). Minor suggestions can be noted for implementation.

**Exit Plan Mode**: Once the design is complete and reviewed by both subagents, include the Codex `sessionId` in your ExitPlanMode summary. This serves as:
- Proof that external review occurred
- A reference for follow-up queries via `mcp__codex__codex-reply` if needed during implementation

Use ExitPlanMode to get user approval before proceeding to implementation.

### Phase 2: Task Creation and Preparation — Post-Approval

Analyze the complete design and break down all work into concrete tasks upfront:

- Each task should be atomic and result in working code (tested if infrastructure exists)
- Tasks should reference specific parts of the design
- Order tasks by dependencies (what needs to happen first)
- Tasks follow TDD when test infrastructure exists
- Include documentation update tasks
- Be specific about file locations and what needs to change

Note: The specification (Phase 4) is handled separately after all implementation tasks complete — do not create a task for it.

**Create all tasks upfront** using TaskCreate before beginning any implementation. This provides:

- Complete visibility into the scope of work
- Proper dependency ordering
- Clear progress tracking
- Ability to resume work if interrupted

**Task Complexity Assessment**: A task is considered complex if it:

- Affects multiple modules or system boundaries
- Introduces new architectural patterns
- Has unclear implementation path
- Involves significant refactoring

**Subagent Task Preparation**: After all tasks are created, launch Explore subagents (via Task tool with `subagent_type: "Explore"`) for complex tasks:

- Launch subagents in parallel for independent tasks to reduce overhead
- For dependent tasks, prepare them sequentially in dependency order
- Each subagent should analyze files to create/modify, identify code to understand, draft test cases, plan implementation approach, and identify potential issues
- If preparation reveals design flaws, pause and return to Phase 1 or use AskUserQuestion

**Task List Adjustments**: During implementation, if you discover that:

- Additional tasks are needed
- Tasks need to be split or combined
- The order needs adjustment
- Tasks are no longer needed

Use TaskCreate, TaskUpdate, and TaskList to add, modify, or track tasks as appropriate. Document significant changes in commit messages or the final specification.

**Task Creation Verification**: After creating tasks, verify completeness:

- Count the created tasks and compare against the numbered items in the implementation plan
- Ensure every implementation item in the plan has a corresponding task
- If any tasks are missing, create them before proceeding

**Parallelization Checkpoint**: After all tasks are created, verified, and complex tasks are prepared, use AskUserQuestion to ask whether to continue with sequential implementation or stop here for parallel sessions. If stopping, remind the user that each parallel session should claim a task via TaskUpdate (set owner) before starting work to avoid conflicts.

Begin execution only after all initial tasks are created, complex tasks are prepared, and the user chooses to continue.

### Phase 3: Test-Driven Implementation — Execution

For each task:

1. **Mark task in progress**: Use TaskUpdate to set status to `in_progress`
2. **Write tests first**: Create comprehensive tests based on the design and task preparation (skip if project lacks test infrastructure)
3. **Run tests**: Verify they fail appropriately (red phase)
4. **Implement**: Write the minimum code to make tests pass (green phase)
5. **Refactor**: Clean up code while keeping tests green
6. **Run full test suite**: Ensure no regressions
7. **Update documentation**: Modify relevant README files, guides, or inline docs
8. **Code review**: For non-trivial changes, launch a code-reviewer subagent (via Task tool with `subagent_type: "pr-review-toolkit:code-reviewer"`) to check for quality issues, edge cases, or improvements. Skip for trivial changes (single-line fixes, simple renames, obvious implementations).
9. **Address review feedback**: Make any necessary changes
10. **Commit**: Create atomic commit with descriptive message
11. **Mark task completed**: Use TaskUpdate to set status to `completed`

**Projects Without Test Infrastructure**: If the pre-workflow check found no test infrastructure, skip steps 2-3 and 6. Implement directly and verify manually. Do not introduce test infrastructure unless the user requests it.

Commit messages should reference design decisions, spec sections, or task identifiers where relevant.

**Failure Handling**: If tests fail during implementation:

- First attempt to fix the issue
- If the fix requires rethinking the approach, update the task and document the deviation in the commit message or specification
- If the failure reveals a fundamental design problem, pause and use AskUserQuestion
- Never commit failing tests

**Test Sequencing**: Execute implementation tasks sequentially. Subagents are used for review and preparation, not parallel implementation. Sequential execution avoids test suite conflicts and ensures each task builds on verified, working code.

**Interruption Handling**: If work is interrupted mid-implementation:

- Use TaskList to see current state and identify the next pending task
- Read incomplete task details with TaskGet before resuming
- Check git status for any uncommitted work
- Resume by completing the current in-progress task or starting the next pending one

**Completion Verification**: Before proceeding to Phase 4:

- Run TaskList and verify all tasks are marked `completed`
- If any tasks remain `pending` or `in_progress`, complete them first
- Do not proceed to specification writing until all tasks are done

### Phase 4: Technical Specification — Final Deliverable

After all implementation tasks are complete, launch a general-purpose subagent (via Task tool with `subagent_type: "general-purpose"`) to generate the technical specification.

This is the only persisted design document. It captures key decisions from the planning phase for long-term reference.

**Specification Writer Subagent**: This subagent will:

- Review all existing specifications to understand format, style, and location conventions
- Determine the correct location based on project patterns
- Synthesize the design, implementation, and tests into a cohesive specification
- Ensure consistency with other project specifications
- Include all required sections with appropriate detail
- Reference related specifications and create bidirectional links

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

The specification location should be determined by examining existing specs. Common patterns include:

- `docs/specs/[feature-name].md` for centralized specifications
- `lib/[module]/specs/[feature-name].md` for module-local specifications
- Alongside the main module file as `[module]_spec.md`

The specification should include:

**Header**

- Feature name
- Date created
- Last updated
- Status: `draft` | `in-progress` | `implemented` | `deprecated` | `superseded`
- Related specifications (links)

**Overview**

- Brief description of what this does (2-3 sentences)
- Why it exists (captures the key decision rationale from the planning phase)

**Architecture**

- Key modules and their responsibilities
- How components interact
- Important design decisions and tradeoffs (distilled from planning phase)
- Alternatives considered and why they were rejected
- Diagrams if helpful for understanding

**API/Interface**

- Public functions and their signatures
- Expected inputs and outputs
- Usage examples
- Error responses

**Data Structures**

- Important data structures or schemas
- Key type definitions
- Validation rules

**Error Handling**

- What errors can occur
- How they're handled
- Recovery strategies

**Dependencies and Related Code**

- Links to other specifications or modules
- External dependencies
- Version requirements

**Testing**

- Testing strategy
- Key test cases or scenarios
- Coverage expectations

**Documentation**

- Links to related documentation
- Usage guides or tutorials
- Migration guides if applicable

**Future Considerations**

- Known limitations
- Potential future enhancements
- Technical debt notes

**Change History**

- Date, author, and summary of significant changes
- Links to related PRs or commits

Commit the specification with message format:

```
docs(spec): add specification for [feature-name]

Captures architecture decisions, API design, and implementation
details for future reference and LLM context.

Related to: [original feature request or ticket]
```

**Scaling for Smaller Features**: For minor changes or simple features, include only the sections that provide value. Required sections: Header, Overview, API/Interface (if applicable), and Change History. Other sections can be omitted or condensed when the feature is straightforward.

### Specification Updates

When Phase 4 involves updating an existing specification (identified during pre-workflow check):

1. Launch an Explore subagent to review the existing spec and current implementation to identify differences
2. Update the existing spec to reflect changes (do not create a new spec)
3. Preserve the history by adding update notes with dates in the "Change History" section
4. Update the "Last updated" field and status if applicable
5. Ensure bidirectional links between related specs remain valid
6. Commit the updated specification

For substantial changes that alter the spec's core architecture, consider creating a new spec and marking the old one as `superseded`.

## Using AskUserQuestion

Only use the AskUserQuestion tool when:

- There are genuinely multiple valid approaches with significantly different tradeoffs
- The decision impacts user-facing behavior or API design in non-obvious ways
- There's ambiguity in requirements that cannot be resolved by examining existing code or specs
- A decision requires domain knowledge that isn't present in the codebase
- Design review iterations have not converged after 3 cycles

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

## Subagent Strategy

Use the Task tool to launch subagents for:

- **Design Review** (`general-purpose`): Required during Phase 1 to critically evaluate the design
- **Plan Review via Codex** (`general-purpose`): REQUIRED during Phase 1 after design review; subagent MUST call `mcp__codex__codex` and return the `sessionId` as proof of execution
- **Task Preparation** (`Explore`): For complex tasks before execution to analyze files and draft test cases
- **Code Review** (`pr-review-toolkit:code-reviewer`): Non-trivial changes before committing; if plugin unavailable, use `general-purpose` with explicit review prompt
- **Specification Writing** (`general-purpose`): Required for final documentation in Phase 4

**Plugin Fallback**: The `pr-review-toolkit:code-reviewer` requires the pr-review-toolkit plugin. If unavailable, use `general-purpose` with this prompt: "Review this code for quality issues, edge cases, adherence to project conventions, and potential improvements."

Do not use subagents for:

- Parallel implementation of tasks (causes test suite conflicts; subagents are for review/preparation only)
- Trivial changes (single-line fixes, simple renames)
- Decisions that can be made by examining project conventions

## Quality Standards

Before proceeding to the next phase:

- Design review subagent finds no critical issues (minor issues acceptable after 3 iterations)
- Codex MCP review completed with valid `sessionId` captured (required proof of external review)
- All tests pass (if test infrastructure exists)
- Code follows project conventions and passes code review
- Documentation is updated and accurate
- Specification is complete and consistent with implementation
- All commits have descriptive messages

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

- **Plan mode**: Design (what + how) is written in the plan file, reviewed via subagents, approved via ExitPlanMode
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
