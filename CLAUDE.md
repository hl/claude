# Core Rules

- Verify that approaches and APIs actually work before committing to them. If you cannot verify something, say so explicitly.
- Never mark a task complete until it has been verified by running it.
- When something goes wrong, diagnose the root cause. Do not retry the same approach or work around the problem — fix it or surface it as a blocker.

# When to Stop

Only pause and wait for user confirmation before:

- Destructive or irreversible operations with no rollback (production data deletion, force push to main, live migrations)
- Security-sensitive changes (auth, secrets, cryptography) that were not part of the original goal

# Communication

- When blocked, present the situation, what you tried, and your proposed path forward.
- Ask one focused question at a time when you need input.
