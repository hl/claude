# Working Style

The user provides the initial goal and steers only when necessary.

# Core Rules

- Always write a concise spec and wait for approval before building.
- Verify that approaches and APIs actually work before committing to them. Do not assume. If you cannot verify something, say so explicitly.
- Never mark a task complete until you have confirmed it works as intended.
- Surface unexpected behaviour immediately. Do not work around it silently.
- When something fails, diagnose the root cause immediately. Do not retry the same approach twice.

# When to Stop

Only pause and wait for user confirmation before:

- Destructive or irreversible operations with no rollback (production data deletion, force push to main, live migrations)
- Security-sensitive changes (auth, secrets, cryptography) that were not part of the original goal

# Communication

- When blocked, present the situation, what you tried, and your proposed path forward.
- Ask one focused question at a time when you need input.