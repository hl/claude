# beads-status

Live TUI overview of in-flight [beads](https://github.com/steveyegge/beads)
across every repo under `~/Projects` — built to run in a herdr pane next to the
orchestrator (ananke), so fleet-wide bead state is visible at a glance without
asking an agent.

Pull-based by design: it shells out to read-only `bd` on a timer, so it needs no
orchestrator involvement, burns no tokens, and can never go stale.

## Layout

Responsive: at ≥110 columns the list and detail sit side by side; narrower
(a herdr split pane) they stack — full-width list on top, a separator naming
the selected bead, full-width detail below.

- **List** — the `needs-human` docket first ("Waiting on you"), then one
  group per repo that has non-closed beads: status symbol, id, priority, age
  since last update, `⚑` flag, title.
- **Detail** — the selected bead's full description, notes, labels, and
  metadata.

Colour rules: **red strictly means blocked** (row) or the `⚑` needs-human flag
itself; yellow = in progress; dim = open. An in-progress bead whose age keeps
climbing while its agent looks alive is the dead-worker tell.

## Keys & mouse

| Input | Action |
|---|---|
| `↑`/`↓`, `j`/`k`, click | select a bead |
| `J`/`K`, `pgup`/`pgdn`, wheel over right pane | scroll the description |
| `g`/`G` | first / last bead |
| `r` | refresh now (auto-refresh every 5s) |
| `q`, `esc`, `ctrl-c` | quit |

## Usage

```sh
beads-status            # full TUI
beads-status --once     # plain-text snapshot to stdout (for scripts)
```

Environment knobs:

- `BEADS_STATUS_PROJECTS` — projects root to sweep (default `~/Projects`;
  every `*/.beads` directory under it is a repo)
- `BEADS_STATUS_INTERVAL` — auto-refresh interval in seconds (default `5`)

## Build

The binary is not tracked; rebuild after changes:

```sh
cd ~/.claude/tools/beads-status && go build -o ~/.claude/bin/beads-status .
```

Dependencies: `bd` on `PATH`, Go ≥1.21 to build
(charmbracelet [bubbletea](https://github.com/charmbracelet/bubbletea) +
[lipgloss](https://github.com/charmbracelet/lipgloss), fetched via go.mod).
