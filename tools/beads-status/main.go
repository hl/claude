// beads-status — live TUI overview of in-flight beads across every ~/Projects
// repo, for a herdr pane next to the orchestrator. Pull-based (shells out to
// bd, read-only) so it can never go stale and needs no orchestrator involvement.
//
// Left pane: docket (needs-human) + per-repo bead rows. Right pane: full
// description of the selected bead. Arrow keys / j k / mouse click to select,
// J K (or wheel over the right pane) to scroll the description, r to refresh
// now, q to quit. Auto-refreshes every 5s (BEADS_STATUS_INTERVAL to change).
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
}

func (b bead) needsHuman() bool {
	for _, l := range b.Labels {
		if l == "needs-human" {
			return true
		}
	}
	return false
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
}

// ---- data sweep (runs off the UI goroutine) ----

func projectsDir() string {
	if p := os.Getenv("BEADS_STATUS_PROJECTS"); p != "" {
		return p
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Projects")
}

func statusRank(s string) int {
	switch s {
	case "blocked":
		return 0
	case "in_progress":
		return 1
	default:
		return 2
	}
}

func sweep() ([]repoData, error) {
	dirs, err := filepath.Glob(filepath.Join(projectsDir(), "*", ".beads"))
	if err != nil {
		return nil, err
	}
	var repos []repoData
	for _, d := range dirs {
		repo := filepath.Dir(d)
		out, err := exec.Command("bd", "-C", repo, "list",
			"--status", "open,in_progress,blocked", "--json", "-n", "0").Output()
		if err != nil {
			continue // repo with a broken db shouldn't kill the screen
		}
		var beads []bead
		if json.Unmarshal(out, &beads) != nil || len(beads) == 0 {
			continue
		}
		name := filepath.Base(repo)
		for i := range beads {
			beads[i].repoName = name
			beads[i].repoPath = repo
		}
		sort.SliceStable(beads, func(i, j int) bool {
			if a, b := statusRank(beads[i].Status), statusRank(beads[j].Status); a != b {
				return a < b
			}
			return beads[i].Priority < beads[j].Priority
		})
		repos = append(repos, repoData{name: name, path: repo, beads: beads})
	}
	return repos, nil
}

// ---- model ----

type rowKind int

const (
	rowHeader rowKind = iota
	rowBead
	rowBlank
)

type row struct {
	kind rowKind
	text string // pre-rendered for header/blank
	bead *bead
}

type dataMsg struct {
	repos []repoData
	err   error
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
}

func (m model) Init() tea.Cmd {
	return tea.Batch(doSweep, m.tick())
}

func doSweep() tea.Msg {
	repos, err := sweep()
	return dataMsg{repos: repos, err: err}
}

func (m model) tick() tea.Cmd {
	return tea.Tick(m.interval, func(time.Time) tea.Msg { return tickMsg{} })
}

// buildRows flattens repos into display rows: docket first, then per-repo groups.
func buildRows(repos []repoData) []row {
	var rows []row
	var docket []*bead
	for i := range repos {
		for j := range repos[i].beads {
			if b := &repos[i].beads[j]; b.needsHuman() {
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
		var np, nb, no int
		for _, b := range r.beads {
			switch b.Status {
			case "in_progress":
				np++
			case "blocked":
				nb++
			default:
				no++
			}
		}
		rows = append(rows, row{kind: rowHeader,
			text: fmt.Sprintf("%s  %d in progress · %d blocked · %d open", r.name, np, nb, no)})
		for j := range r.beads {
			rows = append(rows, row{kind: rowBead, bead: &r.beads[j]})
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
	if max := len(m.rows) - visible; m.listOffset > max {
		m.listOffset = max
	}
	if m.listOffset < 0 {
		m.listOffset = 0
	}
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

func (m model) geometry() geom {
	if m.width >= stackBelow {
		lw := m.width * 45 / 100
		lh := m.height - 2 // header + footer
		return geom{listW: lw, listH: lh, listY: 1,
			detailW: m.width - lw - 3, detailH: lh, detailX: lw + 3, detailY: 1}
	}
	body := m.height - 3 // header + separator + footer
	dh := body * 2 / 5
	if dh < 6 {
		dh = 6
	}
	if dh > body-3 {
		dh = body - 3
	}
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
		return m, tea.Batch(doSweep, m.tick())

	case dataMsg:
		m.err = msg.err
		m.sweptAt = time.Now()
		var prev string
		if m.cursor >= 0 && m.cursor < len(m.rows) && m.rows[m.cursor].kind == rowBead {
			prev = m.rows[m.cursor].bead.ID
		}
		m.repos = msg.repos
		m.rows = buildRows(msg.repos)
		m.selectNearest(prev)
		m.clampScroll()

	case tea.KeyMsg:
		switch msg.String() {
		case "q", "ctrl+c", "esc":
			return m, tea.Quit
		case "r":
			return m, doSweep
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
			m.descOffset -= m.listHeight() / 2
			if m.descOffset < 0 {
				m.descOffset = 0
			}
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
					m.descOffset -= 3
					if m.descOffset < 0 {
						m.descOffset = 0
					}
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
	sym, style := "○", stOpen
	switch b.Status {
	case "in_progress":
		sym, style = "●", stProg
	case "blocked":
		sym, style = "✗", stBlocked
	}
	flag := " "
	if b.needsHuman() {
		flag = "⚑"
	}
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
	off := m.descOffset
	if off > len(all)-1 {
		off = len(all) - 1
	}
	if off < 0 {
		off = 0
	}
	endI := off + height
	if endI > len(all) {
		endI = len(all)
	}
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

	head := stDim.Render(truncate(fmt.Sprintf("beads status · %s · %s",
		m.sweptAt.Format("15:04:05"), projectsDir()), m.width))
	if m.err != nil {
		head += "  " + stBlocked.Render("sweep error: "+m.err.Error())
	}
	foot := stDim.Render(truncate("↑↓/click select · J/K scroll description · r refresh · q quit", m.width))

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
		for _, r := range buildRows(repos) {
			switch r.kind {
			case rowHeader:
				fmt.Println(r.text)
			case rowBead:
				b := r.bead
				flag := " "
				if b.needsHuman() {
					flag = "⚑"
				}
				fmt.Printf("  %-11s %-18s P%d %4s %s %s\n",
					b.Status, b.ID, b.Priority, b.age(), flag, b.Title)
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
