# beads-status

Live TUI overview of in-flight [beads](https://github.com/steveyegge/beads)
of the repo it is started in — built to run in a herdr pane next to the
orchestrator (pien), so that repo's bead state is visible at a glance without
asking an agent.

Pull-based by design: it shells out to read-only `bd` on a timer, so it needs no
orchestrator involvement, burns no tokens, and can never go stale.

## Layout

Responsive: at ≥110 columns the list and detail sit side by side; narrower
(a herdr split pane) they stack — full-width list on top, a separator naming
the selected bead, full-width detail below.

- **List** — the `needs-human` docket first ("Waiting on you"), then the
  repo's group of non-closed beads: status symbol, id, priority, age
  since last update, `⚑` flag, title.
- **Detail** — the selected bead's full description, notes, labels, and
  metadata.

A repo whose `bd` call fails (or has no `.beads` directory) gets a red
`<repo>  bd failed: <reason>` row in place of its group (and the reason on
stderr under `--once`) — it is never silently dropped, since a missing repo
reads as "no work left". Such rows ignore the search filter.

Colour rules: **red strictly means blocked** (row) or the `⚑` needs-human flag
itself; yellow = in progress; dim = open. An in-progress bead whose age keeps
climbing while its agent looks alive is the dead-worker tell.

## Keys & mouse

| Input | Action |
|---|---|
| `↑`/`↓`, `j`/`k`, click | select a bead |
| `J`/`K`, `pgup`/`pgdn`, wheel over right pane | scroll the description |
| `g`/`G` | first / last bead |
| `/` | search (see below) |
| `r` | refresh now (auto-refresh every 5s) |
| `enter` | (in search) keep the filter, return to the list |
| `esc` | clear the active filter, else quit |
| `q`, `ctrl-c` | quit |

## Search

`/` opens a search prompt; the list filters live as you type. A query matches a
bead if **every** whitespace-separated term appears (case-insensitively) in its
id, title, description, notes, labels, status, assignee, or repo name — so
extra words narrow the result. Repos and the docket disappear when nothing in
them matches, and the header shows the query and match count.

`enter` keeps the filter and hands the keys back to the list (so `j`/`k`, `J`/`K`
work over the matches); `esc` clears it. The filter survives auto-refresh.

## Usage

```sh
beads-status              # full TUI
beads-status --once       # plain-text snapshot to stdout (for scripts)
beads-status --once auth  # snapshot filtered by the same search rules
```

Environment knobs:

- `BEADS_STATUS_DIR` — repo to sweep (default: the working directory
  beads-status was started in; it must contain a `.beads` directory)
- `BEADS_STATUS_INTERVAL` — auto-refresh interval in seconds (default `5`)

## Build

The binary is not tracked; rebuild after changes:

```sh
cd ~/.claude/tools/beads-status && go build -o ~/.claude/bin/beads-status .
```

Dependencies: `bd` on `PATH`, Go ≥1.21 to build
(charmbracelet [bubbletea](https://github.com/charmbracelet/bubbletea) +
[lipgloss](https://github.com/charmbracelet/lipgloss), fetched via go.mod).
