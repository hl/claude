# orchestrator.awk — live sections of a .orchestrator.md, for compact-session.sh.
# Prints one TSV line per section that is not finished: heading, first content
# line, status line (may be empty). A section is finished when its heading
#   - has a last " — " segment (em dash, en dash or spaced hyphen) that starts with
#     DONE or BLOCKED (Claudette's convention: "## 2026-10-18 — change X — DONE: merged #12"),
#   - ends in "(DONE)" / "[DONE]" (or BLOCKED), or
#   - starts with "DONE:" / "BLOCKED:",
# or when a "Status:" in its body starts with done / blocked / merged. A heading
# that merely mentions DONE ("Make the DONE marker visible") is live. Deeper headings under a finished
# section are finished too. Table rows marked DONE or BLOCKED, table separators
# and blank lines are never the "first line". H1 is the file title and is
# skipped unless the file has no deeper headings.
#
# -v mode=prune -v cutoff=YYYY-MM-DD -v today=YYYY-MM-DD (orchestrator-prune.sh):
# prints every line tagged K (keep), A (archive), C (collapsed heading, keep),
# S (collapsed heading stamped now, keep) or D (finished heading closed before
# cutoff, archive). A finished section shrinks to its heading (" — DONE" appended
# when only its Status line said so). The first prune that sees it finished
# appends " (closed <today>)"; the heading goes once that stamp is before cutoff,
# so retention counts from when it closed, not from its leading date. Deeper
# headings under it are archived with the body. A trailing close stamp is
# ignored when deciding whether a heading is finished.
# -v mode=report: one TSV line per live top-level section: lines, heading.
function trim(s) { sub(/^[ \t>*-]+/, "", s); sub(/[ \t]+$/, "", s); gsub(/\t/, " ", s); return s }
function cut(s, n) { return length(s) > n ? substr(s, 1, n - 1) "…" : s }
function level(h) { match(h, /^#+/); return RLENGTH }
function finished_heading(h,    t, rest, k) {
  t = h
  sub(/^#+[ \t]*/, "", t)
  sub(/[ \t]+$/, "", t)
  sub(/[ \t]+\(closed [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)$/, "", t)
  if (t ~ /^[*_]*(DONE|BLOCKED)[*_]*:/) return 1
  if (t ~ /[(\[][*_]*(DONE|BLOCKED)[*_]*[)\]]$/) return 1
  # the text after the last separator, whichever dash it uses
  gsub(/ – /, " — ", t)
  gsub(/ - /, " — ", t)
  rest = t
  while ((k = index(rest, " — ")) > 0) rest = substr(rest, k + length(" — "))
  if (rest == t) return 0
  return rest ~ /^[*_]*(DONE|BLOCKED)([^A-Za-z]|$)/
}
function flush() {
  if (head != "" && !done) print cut(head, 160) "\t" cut(first, 200) "\t" cut(status, 160)
  head = ""; first = ""; status = ""; done = 0
}
{ lines[NR] = $0 }
/^##+ / { deep = 1 }
function is_head(l) { return l ~ /^#+ / && (deep == 0 || l !~ /^# /) }
function status_done(l,    s) {
  if (!match(l, /[Ss]tatus\**:[ \t]*\**[A-Za-z]+/)) return 0
  s = substr(l, RSTART, RLENGTH); sub(/^[Ss]tatus\**:[ \t]*\**/, "", s)
  return tolower(s) ~ /^(done|blocked|merged)$/
}
# close_date(h): the date of a trailing " (closed YYYY-MM-DD)" stamp, or ""
function close_date(h) {
  if (!match(h, /\(closed [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)[ \t]*$/)) return ""
  return substr(h, RSTART + 8, 10)
}
# sections(): fin[h] for every heading line h, top[] (min heading level), and
# role[i] for every line: "live", "fin" (top of a finished section), "in" (inside one).
function sections(    i, h, lv, dl) {
  h = 0; top = 99
  for (i = 1; i <= NR; i++) {
    if (is_head(lines[i])) { h = i; fin[h] = finished_heading(lines[i]); if (level(lines[i]) < top) top = level(lines[i]); continue }
    if (h && status_done(lines[i])) fin[h] = 1
  }
  dl = 0
  for (i = 1; i <= NR; i++) {
    if (is_head(lines[i])) {
      lv = level(lines[i])
      if (dl > 0 && lv <= dl) dl = 0
      if (dl > 0) role[i] = "in"
      else if (fin[i]) { role[i] = "fin"; dl = lv }
      else role[i] = "live"
      continue
    }
    role[i] = dl > 0 ? "in" : "live"
  }
}
END {
  if (mode == "prune") {
    sections()
    for (i = 1; i <= NR; i++) {
      l = lines[i]
      if (role[i] == "live") { print "K\t" l; continue }
      if (role[i] == "fin") {
        c = close_date(l)
        if (c != "" && cutoff != "" && c < cutoff) { print "D\t" l; continue }
        sub(/[ \t]+$/, "", l)
        sub(/[ \t]+\(closed [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)$/, "", l)
        if (!finished_heading(l)) l = l " — DONE"
        if (c != "") { print "C\t" l " (closed " c ")"; continue }
        if (today != "") { print "S\t" l " (closed " today ")"; continue }
        print "C\t" l
        continue
      }
      print (l ~ /^[ \t]*$/ ? "K\t" : "A\t") l
    }
    exit
  }
  if (mode == "report") {
    sections()
    h = 0
    for (i = 1; i <= NR + 1; i++) {
      if (i > NR || (is_head(lines[i]) && level(lines[i]) <= top)) {
        if (h) print n "\t" lines[h]
        h = (i <= NR && role[i] == "live") ? i : 0; n = 0
      }
      n++
    }
    exit
  }
  donelevel = 0
  for (i = 1; i <= NR; i++) {
    l = lines[i]
    if (l ~ /^#+ / && (deep == 0 || l !~ /^# /)) {
      flush()
      head = l
      lv = level(l)
      if (donelevel > 0 && lv <= donelevel) donelevel = 0
      if (donelevel > 0 && lv > donelevel) done = 1
      if (finished_heading(l)) { done = 1; donelevel = lv }
      continue
    }
    if (head == "") continue
    if (match(l, /[Ss]tatus\**:[ \t]*\**[A-Za-z]+/)) {
      s = substr(l, RSTART, RLENGTH); sub(/^[Ss]tatus\**:[ \t]*\**/, "", s)
      if (tolower(s) ~ /^(done|blocked|merged)$/) { done = 1; if (donelevel == 0) donelevel = level(head) }
      if (status == "") status = trim(l)
    }
    if (first == "" && l !~ /^[ \t]*$/ && l !~ /^[ \t]*\|[- :|]*\|?[ \t]*$/ && l !~ /(^|[^A-Za-z])(DONE|BLOCKED)([^A-Za-z]|$)/) first = trim(l)
  }
  flush()
}
