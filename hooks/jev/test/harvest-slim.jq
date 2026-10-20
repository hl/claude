# harvest-slim.jq — `jq -cR -f harvest-slim.jq` over one transcript JSONL.
# Keeps, per record, only what harvest.sh needs: Agent tool_use inputs, the
# assistant's text, tool_result ids and typed user prompts. Partial lines are skipped.
def flat: if type == "string" then . elif type == "array" then [.[] | select(.type == "text") | .text] | join("\n") else "" end;
fromjson?
| select(.type == "assistant" or .type == "user")
| if .type == "assistant" then
    {k: "a", ts: .timestamp, sid: .sessionId, ag: (.agentId // null), m: (.message.model // null), cwd: (.cwd // null),
     uses: [.message.content | arrays | .[] | select(.type == "tool_use" and .name == "Agent") | {id, in: .input}],
     text: ([.message.content | arrays | .[] | select(.type == "text") | .text] | join("\n") | .[0:1500])}
    | select((.uses | length) > 0 or (.text | length) > 0)
  else
    ([.message.content | arrays | .[] | select(.type == "tool_result") | .tool_use_id]) as $r
    | if ($r | length) > 0 then {k: "r", ids: $r, ts: .timestamp}
      elif has("promptSource") and (.isMeta | not) then {k: "u", ts: .timestamp, text: (.message.content | flat | .[0:1500])}
      else empty end
  end
