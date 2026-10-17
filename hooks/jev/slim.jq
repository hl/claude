# slim.jq — run with `jq -cR -f slim.jq` over a transcript JSONL.
# Keeps only conversation records and the fields extract.jq needs; drops huge
# payloads (toolUseResult, thinking, file contents). Partial lines are skipped.
def flat: if type == "string" then . elif type == "array" then [.[] | select(.type == "text") | .text] | join("\n") else "" end;

fromjson?
| select(.type == "user" or .type == "assistant"
         or (.type == "attachment" and .attachment.type == "queued_command")
         or (.type == "attachment" and .attachment.type == "hook_additional_context" and .attachment.hookEvent == "SessionStart"))
| {
    type, isMeta, isCompactSummary, gitBranch, ps: has("promptSource"),
    a: (if .type == "attachment" then
          {type: .attachment.type, prompt: ((.attachment.prompt | strings) // null),
           ctx: ((.attachment.content | if type == "array" then map(strings) | join("\n") else strings end) // null)}
        else null end),
    c: (.message.content
        | if type == "array" then
            map(if .type == "tool_result" then {type, tool_use_id, is_error, text: (.content | flat | .[0:1500])}
                elif .type == "text" then {type, text}
                elif .type == "tool_use" then
                  {type, id, name, input: (.input | if type == "object" then {file_path, notebook_path, command, url} else {} end)}
                else empty end)
          else . end)
  }
