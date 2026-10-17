# slim.jq — run with `jq -cR -f slim.jq` over a transcript JSONL.
# Keeps only conversation records and the fields extract.jq needs; drops huge
# payloads (toolUseResult, thinking, file contents). Partial lines are skipped.
def flat: if type == "string" then . elif type == "array" then [.[] | select(.type == "text") | .text] | join("\n") else "" end;

fromjson?
| select(.type == "user" or .type == "assistant"
         or (.type == "attachment" and .attachment.type == "queued_command"))
| {
    type, isMeta, isCompactSummary, gitBranch,
    a: (if .type == "attachment" then {type: .attachment.type, prompt: (.attachment.prompt | strings)} else null end),
    c: (.message.content
        | if type == "array" then
            map(if .type == "tool_result" then {type, tool_use_id, is_error, text: (.content | flat | .[0:1500])}
                elif .type == "text" then {type, text}
                elif .type == "tool_use" then
                  {type, id, name, input: (.input | if type == "object" then {file_path, notebook_path, command, url} else {} end)}
                else empty end)
          else . end)
  }
