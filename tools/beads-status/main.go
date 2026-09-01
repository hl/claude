// beads-status — live TUI overview of in-flight beads in the repo it is
// repo, for a herdr pane next to the orchestrator. Pull-based (shells out to
// bd, read-only) so it can never go stale and needs no orchestrator involvement.
//
// Left pane: docket (needs-human) + per-repo bead rows. Right pane: full
// description of the selected bead. Arrow keys / j k / mouse click to select,
// J K (or wheel over the right pane) to scroll the description, / to search
// (id, title, description, notes, labels), r to refresh now, q to quit.
// Auto-refreshes every 5s (BEADS_STATUS_INTERVAL to change).
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

type bead struct {
	ID          string   `json:"id"`
	Title       string   `json:"title"`
	Description string   `json:"description"`
	Notes       string   `json:"notes"`
	Status      string   `json:"status"`
	Priority    int      `json:"priority"`
	Assignee    string   `json:"assignee"`
	UpdatedAt   string   `json:"updated_at"`
	Labels      []string `json:"labels"`

	repoName string
	repoPath string
	hay      string // lowercased search haystack, built once by sweep
}

func (b bead) needsHuman() bool {
	for _, l := range b.Labels {
		if l == "needs-human" {
			return true
		}
	}
	return false
}

// flagSymbol is the marker shown when a bead needs a human's attention.
func (b bead) flagSymbol() string {
	if b.needsHuman() {
		return "⚑"
	}
	return " "
}

// buildHay lowercases the fields matches searches into one haystack, done
// once per bead in sweep() rather than on every keystroke of a search.
func (b bead) buildHay() string {
	return strings.ToLower(strings.Join(append([]string{
		b.ID, b.Title, b.Description, b.Notes, b.Status, b.Assignee, b.repoName,
	}, b.Labels...), "\x00"))
}

// matches reports whether every whitespace-separated term of a (lowercased)
// query appears somewhere in the bead — id, title, description, notes, labels.
// AND semantics so extra words narrow rather than widen the result.
func (b bead) matches(terms []string) bool {
	if len(terms) == 0 {
		return true
	}
	hay := b.hay
	if hay == "" {
		// sweep() normally precomputes this; fall back for a bead built any
		// other way (tests, callers that skip sweep) so matches() is never
		// silently wrong just because the cache wasn't warmed.
		hay = b.buildHay()
	}
	for _, t := range terms {
		if !strings.Contains(hay, t) {
			return false
		}
	}
	return true
}

func queryTerms(q string) []string {
	return strings.Fields(strings.ToLower(q))
}

func (b bead) age() string {
	t, err := time.Parse(time.RFC3339, b.UpdatedAt)
	if err != nil {
		return "?"
	}
	d := time.Since(t)
	switch {
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh", int(d.Hours()))
	default:
		return fmt.Sprintf("%dd", int(d.Hours()/24))
	}
}

type repoData struct {
	name  string
	path  string
	beads []bead
	err   string // bd failed for this repo; shown instead of its beads
}

// ---- data sweep (runs off the UI goroutine) ----

// scopeDir is the single repo this run watches: the directory beads-status was
// started from, unless BEADS_STATUS_DIR overrides it.
func scopeDir() string {
	if p := os.Getenv("BEADS_STATUS_DIR"); p != "" {
		if abs, err := filepath.Abs(p); err == nil {
			return abs
		}
		return p
	}
	wd, err := os.Getwd()
	if err != nil {
		return "."
	}
	return wd
}

// bdErrMessage boils a failed `bd` invocation down to one line. With --json bd
// reports the failure as {"error": ...} (on either stream); otherwise it prints
// prose, whose first line is the useful part.
func bdErrMessage(out, stderr []byte, err error) string {
	var payload struct {
		Error string `json:"error"`
	}
	for _, s := range [][]byte{stderr, out} {
		if json.Unmarshal(s, &payload) == nil && payload.Error != "" {
			return payload.Error
		}
	}
	for _, s := range []string{string(stderr), string(out)} {
		for _, line := range strings.Split(s, "\n") {
			if line = strings.TrimSpace(line); line != "" && line != "{" {
				return line
			}
		}
	}
	return err.Error()
}

// statusMeta is the single source of truth for the status taxonomy: sort
// rank, list symbol/style, and the label used in per-repo header counts.
// A new status is one row here, not a switch edited in three places.
var statusMeta = map[string]struct {
	rank  int
	sym   string
	style lipgloss.Style
	label string
}{
	"blocked":     {0, "✗", stBlocked, "blocked"},
	"in_progress": {1, "●", stProg, "in progress"},
	"deferred":    {3, "⏸", stDim, "deferred"},
}

// statusOpen is the fallback for any status not named in statusMeta (chiefly
// "open").
var statusOpen = struct {
	rank  int
	sym   string
	style lipgloss.Style
	label string
}{2, "○", stOpen, "open"}

func lookupStatus(s string) (rank int, sym string, style lipgloss.Style, label string) {
	if m, ok := statusMeta[s]; ok {
		return m.rank, m.sym, m.style, m.label
	}
	return statusOpen.rank, statusOpen.sym, statusOpen.style, statusOpen.label
}

func statusRank(s string) int {
	rank, _, _, _ := lookupStatus(s)
	return rank
}

// sweep reads the beads of the one repo in scope. It returns a slice so the
// rest of the UI, which groups by repo, stays unchanged.
func sweep() ([]repoData, error) {
	repo := scopeDir()
	name := filepath.Base(repo)
	// Its .beads must be right here: bd otherwise walks up and would silently
	// report a parent directory's beads as this repo's.
	if st, err := os.Stat(filepath.Join(repo, ".beads")); err != nil || !st.IsDir() {
		return []repoData{{name: name, path: repo, err: "no .beads directory here"}}, nil
	}
	out, err := exec.Command("bd", "-C", repo, "list",
		"--status", "open,in_progress,blocked,deferred", "--json", "-n", "0").Output()
	if err != nil {
		// A broken db shouldn't kill the screen, but it must not silently
		// erase the repo either — a missing repo reads as "no work left".
		var stderr []byte
		if ee, ok := err.(*exec.ExitError); ok {
			stderr = ee.Stderr
		}
		return []repoData{{name: name, path: repo, err: bdErrMessage(out, stderr, err)}}, nil
	}
	var beads []bead
	if err := json.Unmarshal(out, &beads); err != nil {
		return []repoData{{name: name, path: repo, err: "bad json from bd: " + err.Error()}}, nil
	}
	if len(beads) == 0 {
		return nil, nil
	}
	for i := range beads {
		beads[i].repoName = name
		beads[i].repoPath = repo
		beads[i].hay = beads[i].buildHay()
	}
	sort.SliceStable(beads, func(i, j int) bool {
		if a, b := statusRank(beads[i].Status), statusRank(beads[j].Status); a != b {
			return a < b
		}
		return beads[i].Priority < beads[j].Priority
	})
	return []repoData{{name: name, path: repo, beads: beads}}, nil
}

// ---- model ----

type rowKind int

const (
	rowHeader rowKind = iota
	rowBead
	rowBlank
	rowError
)

type row struct {
	kind rowKind
	text string // pre-rendered for header/blank
	bead *bead
}

type dataMsg struct {
	repos []repoData
	err   error
	seq   int // matches the sweepSeq in flight when this sweep was dispatched
}
type tickMsg struct{}

type model struct {
	repos      []repoData
	rows       []row
	cursor     int // index into rows; always a rowBead when any exist
	listOffset int
	descOffset int
	width      int
	height     int
	err        error
	sweptAt    time.Time
	interval   time.Duration
	query      string // active filter; empty = show everything
	searching  bool   // typing in the search prompt

	sweepSeq int // bumped each time a sweep is dispatched; a bd list can run
	// long enough to overlap the next tick, and a slow sweep landing after a
	// fresher one would otherwise snap the list back to stale data
}

// beadCount is how many beads the current rows show (i.e. matches under the
// active query).
func (m model) beadCount() int {
	n := 0
	for _, r := range m.rows {
		if r.kind == rowBead {
			n++
		}
	}
	return n
}

// applyQuery rebuilds the rows for the current query, keeping the selection on
// the same bead when it survives the filter.
func (m *model) applyQuery() {
	var prev string
	if m.cursor >= 0 && m.cursor < len(m.rows) && m.rows[m.cursor].kind == rowBead {
		prev = m.rows[m.cursor].bead.ID
	}
	m.rows = buildRows(m.repos, m.query)
	m.selectNearest(prev)
	m.descOffset = 0
	m.listOffset = 0
	m.clampScroll()
}

func (m model) Init() tea.Cmd {
	return tea.Batch(doSweep(m.sweepSeq), m.tick())
}

func doSweep(seq int) tea.Cmd {
	return func() tea.Msg {
		repos, err := sweep()
		return dataMsg{repos: repos, err: err, seq: seq}
	}
}

func (m model) tick() tea.Cmd {
	return tea.Tick(m.interval, func(time.Time) tea.Msg { return tickMsg{} })
}

// buildRows flattens repos into display rows: docket first, then per-repo
// groups. A non-empty query keeps only matching beads (and drops repos and the
// docket entirely when nothing in them matches).
func buildRows(repos []repoData, query string) []row {
	terms := queryTerms(query)
	var rows []row
	var docket []*bead
	for i := range repos {
		for j := range repos[i].beads {
			if b := &repos[i].beads[j]; b.needsHuman() && b.matches(terms) {
				docket = append(docket, b)
			}
		}
	}
	if len(docket) > 0 {
		rows = append(rows, row{kind: rowHeader, text: "Waiting on you"})
		for _, b := range docket {
			rows = append(rows, row{kind: rowBead, bead: b})
		}
		rows = append(rows, row{kind: rowBlank})
	}
	for i := range repos {
		r := &repos[i]
		if r.err != "" {
			// always visible: an unreadable repo is the one thing a filter
			// must not hide, or the tool lies by omission
			rows = append(rows, row{kind: rowError,
				text: fmt.Sprintf("%s  bd failed: %s", r.name, r.err)},
				row{kind: rowBlank})
			continue
		}
		var hits []*bead
		counts := map[string]int{}
		for j := range r.beads {
			b := &r.beads[j]
			if !b.matches(terms) {
				continue
			}
			hits = append(hits, b)
			_, _, _, label := lookupStatus(b.Status)
			counts[label]++
		}
		if len(hits) == 0 {
			continue
		}
		rows = append(rows, row{kind: rowHeader, text: fmt.Sprintf("%s  %d in progress · %d blocked · %d open · %d deferred",
			r.name, counts["in progress"], counts["blocked"], counts["open"], counts["deferred"])})
		for _, b := range hits {
			rows = append(rows, row{kind: rowBead, bead: b})
		}
		rows = append(rows, row{kind: rowBlank})
	}
	return rows
}

func (m *model) selectNearest(prevID string) {
	// keep selection on the same bead across refreshes; else first bead
	first := -1
	for i, r := range m.rows {
		if r.kind != rowBead {
			continue
		}
		if first == -1 {
			first = i
		}
		if r.bead.ID == prevID {
			m.cursor = i
			return
		}
	}
	m.cursor = first
}

func (m *model) move(delta int) {
	i := m.cursor
	for {
		i += delta
		if i < 0 || i >= len(m.rows) {
			return
		}
		if m.rows[i].kind == rowBead {
			m.cursor = i
			m.descOffset = 0
			return
		}
	}
}

func (m *model) clampScroll() {
	visible := m.listHeight()
	if m.cursor >= 0 {
		if m.cursor < m.listOffset {
			m.listOffset = m.cursor
		}
		if m.cursor >= m.listOffset+visible {
			m.listOffset = m.cursor - visible + 1
		}
	}
	m.listOffset = clampInt(m.listOffset, 0, len(m.rows)-visible)
}

// geometry — responsive layout. Wide panes get list | detail side by side;
// narrow ones (a herdr split) stack: full-width list, separator, full-width
// detail. All row math (scrolling, mouse hits) goes through this.
type geom struct {
	stacked          bool
	listW, listH     int
	listY            int
	detailW, detailH int
	detailX, detailY int
}

const stackBelow = 110 // columns

// clampInt keeps v within [lo, hi], collapsing to lo if the range is degenerate.
func clampInt(v, lo, hi int) int {
	if hi < lo {
		return lo
	}
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

func (m model) geometry() geom {
	if m.width >= stackBelow {
		lw := m.width * 45 / 100
		lh := m.height - 2 // header + footer
		return geom{listW: lw, listH: lh, listY: 1,
			detailW: m.width - lw - 3, detailH: lh, detailX: lw + 3, detailY: 1}
	}
	body := m.height - 3 // header + separator + footer
	dh := clampInt(body*2/5, 6, body-3)
	lh := body - dh
	return geom{stacked: true, listW: m.width, listH: lh, listY: 1,
		detailW: m.width, detailH: dh, detailX: 0, detailY: 1 + lh + 1}
}

func (m model) listHeight() int {
	if m.height == 0 {
		return 0
	}
	return m.geometry().listH
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		m.clampScroll()

	case tickMsg:
		m.sweepSeq++
		return m, tea.Batch(doSweep(m.sweepSeq), m.tick())

	case dataMsg:
		if msg.seq != m.sweepSeq {
			return m, nil // superseded by a newer sweep already in flight
		}
		m.err = msg.err
		m.sweptAt = time.Now()
		var prev string
		if m.cursor >= 0 && m.cursor < len(m.rows) && m.rows[m.cursor].kind == rowBead {
			prev = m.rows[m.cursor].bead.ID
		}
		m.repos = msg.repos
		m.rows = buildRows(msg.repos, m.query)
		m.selectNearest(prev)
		m.clampScroll()

	case tea.KeyMsg:
		if m.searching {
			switch msg.String() {
			case "enter":
				m.searching = false // keep the filter, hand keys back to the list
			case "esc", "ctrl+c":
				m.searching = false
				m.query = ""
				m.applyQuery()
			case "backspace":
				if r := []rune(m.query); len(r) > 0 {
					m.query = string(r[:len(r)-1])
					m.applyQuery()
				}
			case "ctrl+u":
				m.query = ""
				m.applyQuery()
			default:
				switch msg.Type {
				case tea.KeyRunes:
					m.query += string(msg.Runes)
					m.applyQuery()
				case tea.KeySpace:
					m.query += " "
					m.applyQuery()
				}
			}
			return m, nil
		}
		switch msg.String() {
		case "/":
			m.searching = true
			return m, nil
		case "esc":
			if m.query != "" { // clear the filter before quitting on esc
				m.query = ""
				m.applyQuery()
				return m, nil
			}
			return m, tea.Quit
		case "q", "ctrl+c":
			return m, tea.Quit
		case "r":
			m.sweepSeq++
			return m, doSweep(m.sweepSeq)
		case "up", "k":
			m.move(-1)
			m.clampScroll()
		case "down", "j":
			m.move(1)
			m.clampScroll()
		case "g", "home":
			m.cursor = -1
			m.move(1)
			m.clampScroll()
		case "G", "end":
			m.cursor = len(m.rows)
			m.move(-1)
			m.clampScroll()
		case "K", "pgup":
			m.descOffset = max(0, m.descOffset-m.listHeight()/2)
		case "J", "pgdown":
			m.descOffset += m.listHeight() / 2
		}

	case tea.MouseMsg:
		g := m.geometry()
		inList := func(x, y int) bool {
			if y < g.listY || y >= g.listY+g.listH {
				return false
			}
			return g.stacked || x < g.listW
		}
		switch msg.Action {
		case tea.MouseActionPress:
			switch msg.Button {
			case tea.MouseButtonLeft:
				if inList(msg.X, msg.Y) {
					i := m.listOffset + msg.Y - g.listY
					if i >= 0 && i < len(m.rows) && m.rows[i].kind == rowBead {
						m.cursor = i
						m.descOffset = 0
					}
				}
			case tea.MouseButtonWheelUp:
				if inList(msg.X, msg.Y) {
					m.listOffset -= 3
					m.clampScroll()
				} else {
					m.descOffset = max(0, m.descOffset-3)
				}
			case tea.MouseButtonWheelDown:
				if inList(msg.X, msg.Y) {
					m.listOffset += 3
					m.clampScroll()
				} else {
					m.descOffset += 3
				}
			}
		}
	}
	return m, nil
}

// ---- view ----

var (
	stDim     = lipgloss.NewStyle().Faint(true)
	stHeader  = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("6"))
	stDocket  = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("1"))
	stProg    = lipgloss.NewStyle().Foreground(lipgloss.Color("3"))
	stBlocked = lipgloss.NewStyle().Foreground(lipgloss.Color("1"))
	stOpen    = lipgloss.NewStyle().Faint(true)
	stFlag    = lipgloss.NewStyle().Foreground(lipgloss.Color("1"))
	stSel     = lipgloss.NewStyle().Reverse(true)
	stTitle   = lipgloss.NewStyle().Bold(true)
	stLabel   = lipgloss.NewStyle().Foreground(lipgloss.Color("6"))
	stSearch  = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("3"))
)

func truncate(s string, w int) string {
	if w <= 0 {
		return ""
	}
	r := []rune(s)
	if len(r) <= w {
		return s
	}
	if w == 1 {
		return "…"
	}
	return string(r[:w-1]) + "…"
}

func (m model) beadLine(b *bead, width int, selected bool) string {
	_, sym, style, _ := lookupStatus(b.Status)
	flag := b.flagSymbol()
	id := truncate(b.ID, 18)
	pre := fmt.Sprintf(" %s %-18s P%d %4s ", sym, id, b.Priority, b.age())
	title := truncate(b.Title, width-lipgloss.Width(pre)-2)
	if selected {
		return stSel.Render(truncate(pre+flag+" "+title, width))
	}
	// The flag renders red independently of row colour: red row = blocked,
	// red ⚑ = waiting on you. Never conflate the two.
	out := style.Render(pre)
	if flag == "⚑" {
		out += stFlag.Render(flag)
	} else {
		out += " "
	}
	return out + " " + style.Render(title)
}

func (m model) renderList(width, height int) []string {
	if len(m.rows) == 0 && m.query != "" {
		return []string{stDim.Render(truncate("no beads match "+strconv.Quote(m.query), width))}
	}
	lines := make([]string, 0, height)
	end := m.listOffset + height
	if end > len(m.rows) {
		end = len(m.rows)
	}
	for i := m.listOffset; i < end; i++ {
		r := m.rows[i]
		switch r.kind {
		case rowHeader:
			if r.text == "Waiting on you" {
				lines = append(lines, stDocket.Render(truncate(r.text, width)))
			} else {
				name, rest, _ := strings.Cut(r.text, "  ")
				lines = append(lines, stHeader.Render(name)+"  "+stDim.Render(truncate(rest, width-len(name)-2)))
			}
		case rowError:
			lines = append(lines, stBlocked.Render(truncate(r.text, width)))
		case rowBead:
			lines = append(lines, m.beadLine(r.bead, width, i == m.cursor))
		default:
			lines = append(lines, "")
		}
	}
	return lines
}

func (m model) renderDetail(width, height int) []string {
	if m.cursor < 0 || m.cursor >= len(m.rows) || m.rows[m.cursor].kind != rowBead {
		if m.query != "" {
			return []string{stDim.Render("no matches")}
		}
		return []string{stDim.Render("no bead selected")}
	}
	b := m.rows[m.cursor].bead
	wrap := lipgloss.NewStyle().Width(width)

	var parts []string
	parts = append(parts, stTitle.Render(wrap.Render(b.ID+" · "+b.Title)))
	meta := fmt.Sprintf("%s · P%d · %s", strings.ToUpper(b.Status), b.Priority, b.repoName)
	if b.Assignee != "" {
		meta += " · " + b.Assignee
	}
	meta += " · updated " + b.age() + " ago"
	parts = append(parts, stDim.Render(wrap.Render(meta)))
	if len(b.Labels) > 0 {
		parts = append(parts, stLabel.Render(wrap.Render("["+strings.Join(b.Labels, "] [")+"]")))
	}
	parts = append(parts, "")
	if b.Description != "" {
		parts = append(parts, wrap.Render(b.Description))
	} else {
		parts = append(parts, stDim.Render("(no description)"))
	}
	if b.Notes != "" {
		parts = append(parts, "", stHeader.Render("NOTES"), wrap.Render(b.Notes))
	}

	all := strings.Split(strings.Join(parts, "\n"), "\n")
	off := clampInt(m.descOffset, 0, len(all)-1)
	endI := min(off+height, len(all))
	out := all[off:endI]
	if off > 0 {
		out[0] = stDim.Render("↑ " + strconv.Itoa(off) + " more")
	}
	if endI < len(all) {
		out[len(out)-1] = stDim.Render("↓ " + strconv.Itoa(len(all)-endI) + " more (J/K or wheel)")
	}
	return out
}

func (m model) View() string {
	if m.width == 0 {
		return "loading…"
	}
	if m.width < 24 || m.height < 10 {
		return stDim.Render("pane too small")
	}
	g := m.geometry()

	headText := fmt.Sprintf("beads status · %s · %s", m.sweptAt.Format("15:04:05"), scopeDir())
	if m.query != "" {
		headText = fmt.Sprintf("beads status · %s · search %q · %d match(es)",
			m.sweptAt.Format("15:04:05"), m.query, m.beadCount())
	}
	head := stDim.Render(truncate(headText, m.width))
	if m.err != nil {
		head += "  " + stBlocked.Render("sweep error: "+m.err.Error())
	}

	var foot string
	switch {
	case m.searching:
		foot = stSearch.Render(truncate("/"+m.query+"█", m.width)) +
			stDim.Render(truncate("  enter keep · esc cancel", m.width-lipgloss.Width(m.query)-3))
	case m.query != "":
		foot = stDim.Render(truncate("filter: "+m.query+" · / edit · esc clear · ↑↓ select · J/K scroll · q quit", m.width))
	default:
		foot = stDim.Render(truncate("↑↓/click select · J/K scroll description · / search · r refresh · q quit", m.width))
	}

	list := m.renderList(g.listW, g.listH)
	detail := m.renderDetail(g.detailW, g.detailH)

	var body strings.Builder
	if g.stacked {
		for i := 0; i < g.listH; i++ {
			if i < len(list) {
				body.WriteString(list[i])
			}
			body.WriteString("\n")
		}
		// separator names the selected bead so the detail block reads anchored
		label := ""
		if m.cursor >= 0 && m.cursor < len(m.rows) && m.rows[m.cursor].kind == rowBead {
			label = " " + m.rows[m.cursor].bead.ID + " "
		}
		bar := "─" + label
		if n := m.width - lipgloss.Width(bar); n > 0 {
			bar += strings.Repeat("─", n)
		}
		body.WriteString(stDim.Render(truncate(bar, m.width)) + "\n")
		for i := 0; i < g.detailH; i++ {
			if i < len(detail) {
				body.WriteString(detail[i])
			}
			body.WriteString("\n")
		}
	} else {
		sep := stDim.Render(" │ ")
		for i := 0; i < g.listH; i++ {
			l, d := "", ""
			if i < len(list) {
				l = list[i]
			}
			if i < len(detail) {
				d = detail[i]
			}
			pad := g.listW - lipgloss.Width(l)
			if pad < 0 {
				pad = 0
			}
			body.WriteString(l + strings.Repeat(" ", pad) + sep + d + "\n")
		}
	}

	return head + "\n" + body.String() + foot
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "--once" {
		repos, err := sweep()
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		query := strings.Join(os.Args[2:], " ") // optional search terms
		for _, r := range buildRows(repos, query) {
			switch r.kind {
			case rowHeader:
				fmt.Println(r.text)
			case rowError:
				fmt.Fprintln(os.Stderr, r.text)
			case rowBead:
				b := r.bead
				fmt.Printf("  %-11s %-18s P%d %4s %s %s\n",
					b.Status, b.ID, b.Priority, b.age(), b.flagSymbol(), b.Title)
			default:
				fmt.Println()
			}
		}
		return
	}

	interval := 5 * time.Second
	if v := os.Getenv("BEADS_STATUS_INTERVAL"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			interval = time.Duration(n) * time.Second
		}
	}
	m := model{cursor: -1, interval: interval}
	p := tea.NewProgram(m, tea.WithAltScreen(), tea.WithMouseCellMotion())
	if _, err := p.Run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
