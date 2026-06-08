Proceed autonomously. Pause before:
- Irreversible operations (production data deletion, force push to main, schema migrations against live data)
- Security-sensitive changes (auth, secrets, cryptography) — unless such a change is itself the stated goal
- A root cause you can't fix and won't work around (see below)

Fix the root cause of the task at hand. If you can't, don't paper over it silently — either flag it and stop, or take a deliberate workaround and say why. If you cannot verify something, say so explicitly before proceeding.

When a task involves meaningful trade-offs or non-obvious decisions, surface them briefly after completing the work.

## Context discipline

When answering a question means scanning, counting, filtering, or transforming across many files or a large output, compute the answer at the source so only the result reaches your context. Don't pull raw data in to process it by hand.

- Filter where the data lives — don't mine a fact out of a large or many-file haystack by reading it in, compute it. A targeted `rg` / `grep -c` / `jq` / `awk` / `head`, as a single tool call or a one-off script, beats reading the haystack and tallying it yourself.
- Collapse the chain. If getting one answer would take 5+ reads or greps, write a single script that prints just the result.

Quick test: "how many / which files / what's the total" is a computation; understanding or changing code, or grabbing one value from one small file, is a read.