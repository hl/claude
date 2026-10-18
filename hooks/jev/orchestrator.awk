# orchestrator.awk — live sections of a .orchestrator.md, for compact-session.sh.
# Prints one TSV line per section that is not finished: heading, first content
# line, status line (may be empty). A section is finished when the LAST " — "
# segment of its heading starts with DONE or BLOCKED (Claudette's convention:
# "## 2026-10-18 — change X — DONE: merged #12"), or when a "Status:" in its body
# starts with done / blocked / merged. A heading that merely mentions DONE
# ("Make the DONE marker visible") is live. Deeper headings under a finished
# section are finished too. Table rows marked DONE or BLOCKED, table separators
# and blank lines are never the "first line". H1 is the file title and is
# skipped unless the file has no deeper headings.
function trim(s) { sub(/^[ \t>*-]+/, "", s); sub(/[ \t]+$/, "", s); gsub(/\t/, " ", s); return s }
function cut(s, n) { return length(s) > n ? substr(s, 1, n - 1) "…" : s }
function level(h) { match(h, /^#+/); return RLENGTH }
# finished_heading: the text after the last " — " starts with DONE or BLOCKED
function finished_heading(h,    rest, k) {
  rest = h
  while ((k = index(rest, " — ")) > 0) rest = substr(rest, k + length(" — "))
  if (rest == h) return 0
  return rest ~ /^[*_]*(DONE|BLOCKED)([^A-Za-z]|$)/
}
function flush() {
  if (head != "" && !done) print cut(head, 160) "\t" cut(first, 200) "\t" cut(status, 160)
  head = ""; first = ""; status = ""; done = 0
}
{ lines[NR] = $0 }
/^##+ / { deep = 1 }
END {
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
