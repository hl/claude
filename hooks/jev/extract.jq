# extract.jq — deterministic fact extraction for compact-pre.sh.
# Input (jq -s): slimmed records (slim.jq) after the last compact boundary.
# Args: $max (fact cap), $tail_chars (size of the plain-text transcript tail).
# Output: {facts: [{n, kind, text, src}], tail: "..."}  (src: uuid of the record the fact came from)
#
# Candidates: user messages, assistant lines that read like decisions or
# constraints, files touched, URLs, branches, the last failing command, and
# open TODO-ish lines. Deduplicated, capped at $max by recency, numbered in
# transcript order.

def clean: gsub("<system-reminder>[\\s\\S]*?</system-reminder>"; "") | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "");
def trunc($n): if length > $n then .[0:$n] + "…" else . end;
def usertext: if type == "string" then . elif type == "array" then [.[] | select(.type == "text") | .text] | join("\n") else "" end;
# Slash commands: a bare "/word" token is always a command. "/word args" is only
# treated as a command echo when the record lacks promptSource (real prompts
# carry it on 2.1.302), so "/tmp is full" typed by the user is kept.
def cmdtoken: test("^/[a-z][a-z0-9:_-]*$");
def cmdecho: test("^/[a-z][a-z0-9:_-]* ");
def slash($ps): cmdtoken or (($ps | not) and cmdecho);
def carried_header: "Facts preserved across compaction by the Jev hook";
def harness: test("^<(command-name|command-message|command-args|local-command-stdout|local-command-stderr|local-command-caveat|task-notification|bash-input|bash-stdout|bash-stderr|user-prompt-submit-hook)");
def todo: test("^(?:[-*] )?(?:\\[ \\]|TODO\\b|FIXME\\b|Next:|Next step|Remaining:|Still need|Open item|Follow-up|Follow up)"; "i");
def decision: test("\\b(?:decid|decision|going with|we'll use|I'll use|will use|chose|choose|must|never|always|do not|don't|avoid|constraint|requirement|root cause|because|instead of|the fix|blocked|conclusion|agreed|confirmed|verified|only)\\b"; "i");
def urls: [scan("https?://[^\\s\"'<>()\\[\\]`]+") | sub("[.,;:!?]+$"; "")];
def recent($k): sort_by(-.i) | .[0:$k];

[to_entries[] | .value + {_i: .key}] as $recs
| ([$recs[] | select(.type == "assistant") | .c | arrays | .[] | select(.type == "tool_use") | {key: .id, value: .}] | from_entries) as $tools

# user turns (typed or queued)
| [ $recs[] | select(.type == "user" and (.isMeta | not) and (.isCompactSummary | not)) | ._i as $i | (.ps == true) as $ps
    | (.c | usertext) | clean | select(length > 0 and (harness | not) and (slash($ps) | not))
    | {i: $i, kind: "user", text: ("User said: " + trunc(400))} ] as $user
| [ $recs[] | select(.type == "attachment") | ._i as $i | .a.prompt | strings | clean
    | select(length > 0 and (harness | not) and (cmdtoken | not))
    | {i: $i, kind: "user", text: ("User said: " + trunc(400))} ] as $queued

# facts a previous compaction re-injected (SessionStart hook_additional_context
# after the boundary): carried forward so a second compaction does not lose them
| [ $recs[] | select(.type == "attachment" and .a.type == "hook_additional_context") | ._i as $i
    | .a.ctx | strings | select(contains(carried_header)) | split("\n")[] | select(startswith("- "))
    | {i: $i, kind: "carried", text: ltrimstr("- ")} ]
  | reduce .[] as $f ([]; if any(.[]; .text == $f.text) then . else . + [$f] end) | .[0:30]
  as $carried

# assistant prose, line by line
| [ $recs[] | select(.type == "assistant") | ._i as $i | .c | arrays | .[] | select(.type == "text")
    | .text | split("\n")[] | clean | sub("^#+ "; "") | {i: $i, t: .} ] as $alines
| [ $alines[] | select((.t | length) >= 20 and (.t | todo | not) and (.t | decision))
    | {i, kind: "decision", text: (.t | trunc(300))} ] as $decisions
| [ ($alines[], ($user[] | {i, t: (.text | ltrimstr("User said: "))}))
    | select(.t | todo) | {i, kind: "todo", text: ("Open item: " + (.t | sub("^(?:[-*] )?open item: *"; ""; "i") | trunc(300)))} ] as $todos

# files touched
| [ $recs[] | select(.type == "assistant") | ._i as $i | .c | arrays | .[]
    | select(.type == "tool_use" and (.name | IN("Edit", "Write", "MultiEdit", "NotebookEdit", "Read")))
    | {i: $i, name, path: (.input.file_path // .input.notebook_path // empty)} ]
  | group_by(.path)
  | map({i: (map(.i) | max), kind: "file",
         text: ((if any(.name != "Read") then "File changed this session: " else "File read this session: " end) + .[0].path)})
  as $files

# URLs from every text source, PR links called out
| [ $recs[] | ._i as $i
    | ((.c | usertext), (.c | arrays | .[] | select(.type == "tool_result") | .text), (.a.prompt // ""))
    | strings | urls[] | {i: $i, u: .} ]
  | group_by(.u)
  | map({i: (map(.i) | max), kind: "url",
         text: ((if (.[0].u | test("/pull/[0-9]+")) then "Pull request: " else "URL referenced: " end) + .[0].u)})
  as $urls

# branches: created/pushed in Bash, plus the session's current branch
| [ $recs[] | select(.type == "assistant") | ._i as $i | .c | arrays | .[]
    | select(.type == "tool_use" and .name == "Bash") | .input.command | strings
    | (scan("git (?:checkout -b|switch -c|checkout -B|branch) ([A-Za-z0-9._/-]+)") | .[0]),
      (scan("git worktree add [^;&|]*-b ([A-Za-z0-9._/-]+)") | .[0]),
      (scan("git push [^;&|]*origin ([A-Za-z0-9._/-]+)") | .[0]),
      (scan("--head ([A-Za-z0-9._/-]+)") | .[0])
    | select(test("^-") | not) | {i: $i, b: .} ]
  | group_by(.b) | map({i: (map(.i) | max), kind: "branch", text: ("Branch used this session: " + .[0].b)})
  as $branches
| ([$branches[] | .text | ltrimstr("Branch used this session: ")]) as $bnames
| ([$recs[] | select((.gitBranch // "") != "" and .gitBranch != "HEAD") | {i: ._i, b: .gitBranch}] | last
   | if . and ((.b | IN($bnames[])) | not) then [{i: .i, kind: "branch", text: ("Git branch of the session directory: " + .b)}] else [] end) as $cur

# last failing command
| ([ $recs[] | ._i as $i | .c | arrays | .[] | select(.type == "tool_result" and .is_error == true)
     | . as $r | ($tools[$r.tool_use_id] // null) as $t
     | select($t != null and $t.name == "Bash")
     | {i: $i, kind: "error",
        text: ("Last failing command: " + ($t.input.command // "" | clean | trunc(200)) + " — output: " + ($r.text | clean | trunc(300)))} ]
   | last | if . then [.] else [] end) as $err

# per-kind caps (most recent first) so file paths and URLs cannot crowd out what the user said
| ($user + $queued + ($decisions | recent(25)) + ($todos | recent(10)) + ($files | recent(15))
   + ($urls | recent(10)) + ($branches | recent(5)) + $cur + $err)
  | map(select(.text | IN($carried[].text) | not))
  | group_by(.text) | map(max_by(.i))
  # carried facts are exempt from the recency cap
  | sort_by(-.i) | .[0:([$max - ($carried | length), 0] | max)]
  | ($carried + .) | sort_by(.i)
  | to_entries | map({n: (.key + 1), kind: .value.kind, text: .value.text, src: ($recs[.value.i].uuid // null)})
  as $facts

# plain-text tail of the transcript for context
| ([ $recs[]
     | if .type == "user" and (.isCompactSummary | not) then
         (((.ps == true) as $ps | .c | usertext | clean | select(length > 0 and (harness | not) and (slash($ps) | not)) | "USER: " + trunc(1500)),
          (.c | arrays | .[] | select(.type == "tool_result") | "RESULT" + (if .is_error then " (error)" else "" end) + ": " + (.text | clean | trunc(400))))
       elif .type == "assistant" then
         (.c | arrays | .[]
          | if .type == "text" then "ASSISTANT: " + (.text | clean | trunc(1500))
            elif .type == "tool_use" then "TOOL " + .name + ": " + ((.input.command // .input.file_path // .input.notebook_path // .input.url // "") | clean | trunc(300))
            else empty end)
       elif .type == "attachment" then (.a.prompt | strings | "USER (queued): " + (clean | trunc(1500)))
       else empty end ]
   | join("\n")) as $all
| {facts: $facts, tail: (if ($all | length) > $tail_chars then $all[-$tail_chars:] else $all end)}
