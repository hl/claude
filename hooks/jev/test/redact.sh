#!/usr/bin/env bash
# shellcheck disable=SC2015 # ok() always succeeds, so `A && ok || bad` is a safe if-then-else.
# redact.sh — redaction before anything is sent to Jev (offline; no key needed).
#
#  1. unit: every planted secret is scrubbed by redact(), and paths, hostnames
#     and git remotes survive
#  2. on the wire: a local fake Jev (fake-jev.py) captures the request bodies of
#     route.sh, agent-route.sh, ledger.sh, compact-pre.sh (v1 mode) and
#     compact-post.sh fed with the planted secrets; none of the secret values
#     may appear in any body. With JEV_LIVE=1 or JEV_EVIDENCE=1 it also
#     rewrites test/evidence/redaction.txt.
# All secrets below are fake.
set -uo pipefail
export JEV_MIGRATE=0 # tests never move this machine's real ~/.claude/jev
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
J=$(cd "$HERE/.." && pwd)
# shellcheck source=SCRIPTDIR/../lib.sh
. "$J/lib.sh"
unset CLAUDE_PROJECT_DIR CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CLAUDE_PID
W=$(mktemp -d "${TMPDIR:-/tmp}/jev-red.XXXXXX")
EVID="$HERE/evidence/redaction.txt"
fails=0
: >"$W/ev.txt"
log() { printf '%s\n' "$*" | tee -a "$W/ev.txt"; }
ok() { log "ok   - $1"; }
bad() {
  log "FAIL - $1"
  fails=$((fails + 1))
}

# <text containing a secret> TAB <the secret value that must disappear>
cat >"$W/planted.tsv" <<'EOF'
export ANTHROPIC_API_KEY=s@@k-ant-api03-FAKEabcdefghijklmnopqrstuvwxyz012345	FAKEabcdefghijklmnopqrstuvwxyz012345
the jev key is a@@pikFAKEREDACTME0123456789abcdefghijklmnopqrstuvwxyz	a@@pikFAKEREDACTME0123456789
git push with g@@hp_FAKE0123456789abcdefghijklmnopqrstu	g@@hp_FAKE0123456789abcdefghij
slack bot token x@@oxb-1234567890-FAKEFAKEFAKEFAKE	x@@oxb-1234567890-FAKEFAKE
aws key A@@KIAIOSFODNN7EXAMPLE in the env	A@@KIAIOSFODNN7EXAMPLE
cookie e@@yJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.e@@yJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c	SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV
curl -H "Authorization: Bearer FAKEBEARERtoken1234567890" https://api.example.com/v1	FAKEBEARERtoken1234567890
curl -H 'authorization: Basic ZmFrZTpmYWtlcGFzc3dvcmQ=' https://api.example.com	ZmFrZTpmYWtlcGFzc3dvcmQ
DB_PASSWORD=hunter2-FAKE-pw mix test	hunter2-FAKE-pw
STRIPE_SECRET_KEY="w@@hsec_FAKE0987654321abc" in .env	w@@hsec_FAKE0987654321abc
{"client_secret": "cs-FAKE-77aa88bb99cc"}	cs-FAKE-77aa88bb99cc
the api key: 3f9a0c1d2e4b5a6978877665544332211aabbccdd0	3f9a0c1d2e4b5a6978877665544332211aabbccdd0
ask jan.jansen@example.com about it	jan.jansen@example.com
the db is on 10.20.30.40 behind the vpn	10.20.30.40
clone https://deploy:s3cretFAKEpw@git.example.com/acme/repo.git	s3cretFAKEpw
download https://bucket.s3.amazonaws.com/f.tar?X-Amz-Signature=FAKESIG0123abcdef&X-Amz-Credential=FAKECRED99&x=1	FAKESIG0123abcdef
download https://bucket.s3.amazonaws.com/f.tar?X-Amz-Signature=FAKESIG0123abcdef&X-Amz-Credential=FAKECRED99&x=1	FAKECRED99
-----BEGIN OPENSSH PRIV@@ATE KEY----- b3BlbnNzaC1rZXktdjEFAKEKEYMATERIAL -----END OPENSSH PRIV@@ATE KEY-----	b3BlbnNzaC1rZXktdjEFAKEKEYMATERIAL
stripe live key s@@k_live_51HFAKEabcdefghijklmnop0123	s@@k_live_51HFAKEabcdefghij
restricted key r@@k_live_51HFAKEqrstuvwxyz98765432	r@@k_live_51HFAKEqrstuv
test key s@@k_test_51HFAKE00112233445566	s@@k_test_51HFAKE0011
curl -u admin:s3cretFAKEpw https://api.example.com/x	s3cretFAKEpw
curl --user deploy:FAKEpass-77 https://api.example.com/y	FAKEpass-77
mysql -u root -pFAKEsupersecret app_db	FAKEsupersecret
mysql -h db.internal.example -u app -p FAKEspacedpw app_db	FAKEspacedpw
pg_dump --password FAKEflagpw1 app	FAKEflagpw1
tool --password=FAKEflagpw2 run	FAKEflagpw2
curl -H 'Cookie: session=FAKEcookie0123456789abcdef; theme=dark' https://app.example.com	FAKEcookie0123456789
post to https://hooks.slack@@.com/services/T0FAKE/B0FAKE/FAKEwebhookSECRET123 when done	FAKEwebhookSECRET123
SLACK_WEBHOOK=https://hooks.slack@@.com/services/T0FAKE/B0FAKE/FAKEwebhook2SECRET	FAKEwebhook2SECRET
npm token n@@pm_FAKEabcdefghijklmnopqrstuvwxyz0123	n@@pm_FAKEabcdefghijkl
hugging face h@@f_FAKEabcdefghijklmnopqrstuvwxyz	h@@f_FAKEabcdefghijklm
digitalocean d@@op_v1_0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef	d@@op_v1_0123456789abcdef
shopify s@@hpat_0123456789abcdef0123456789abcdef	s@@hpat_0123456789abcdef
github app token g@@hs_FAKEabcdefghijklmnopqrstuvwxyz0123	g@@hs_FAKEabcdefghijkl
gitlab g@@lpat-FAKEabcdefghijklmnop	g@@lpat-FAKEabcdefghij
cache at redis://:s3cretRedisFAKEpw@localhost:6379/0	s3cretRedisFAKEpw
queue amqp://:rabbitFAKEpw@mq:5672	rabbitFAKEpw
sshpass -p 'Hunter2FAKEpw' ssh deploy@build-host	Hunter2FAKEpw
docker login -u bot -p d@@ckr_pat_FAKEabcdefghijklmnop registry.example.com	d@@ckr_pat_FAKEabcdefghij
podman login -u bot -p FAKEpodmanPw quay.example.com	FAKEpodmanPw
token d@@ckr_pat_FAKE0123456789abcdefgh in the CI vars	d@@ckr_pat_FAKE0123456789
machine api.example.com login bot password n3tRcFAKEpw	n3tRcFAKEpw
slack app token x@@app-1-A0FAKE123-4567890-abcdefFAKE	x@@app-1-A0FAKE123
{"cookie":"sid=FAKEcookieJSON0123456789"}	FAKEcookieJSON0123456789
mysql -u root -p'Quoted QFAKEpw9' app_db	QFAKEpw9
EOF
# token-shaped values carry an @@ that is removed here, so the repository
# never holds a string a secret scanner would take for a real key
p=$(cat "$W/planted.tsv")
printf '%s\n' "${p//@@/}" >"$W/planted.tsv"
keep=("/home/dev/projects/platform/lib/platform/events.ex" "pg-staging-7.internal.example" "git@github.com:acme/platform.git" "https://github.com/acme/platform/pull/2417")

log "## 1. unit: redact()"
while IFS=$'\t' read -r text secret; do
  r=$(printf '%s' "$text" | redact)
  case $r in *"$secret"*) bad "not redacted: ${text:0:50}… -> $r" ;; *) ok "redacted: ${r:0:90}" ;; esac
done <"$W/planted.tsv"
k="read ${keep[0]}, connect to ${keep[1]}, remote ${keep[2]}, see ${keep[3]}"
r=$(printf '%s' "$k" | redact)
[ "$r" = "$k" ] && ok "kept: paths, hostnames, git remotes, PR links" || bad "over-redacted: $r"

log "## 2. on the wire (fake Jev on 127.0.0.1)"
port=$((20000 + RANDOM % 20000))
python3 -I "$HERE/fake-jev.py" "$port" "$W/cap" >"$W/fake.out" 2>&1 &
fpid=$!
trap 'kill $fpid 2>/dev/null' EXIT
for _ in $(seq 1 50); do grep -q ready "$W/fake.out" 2>/dev/null && break; sleep 0.1; done
export TYPESAFE_BASE_URL="http://127.0.0.1:$port" TYPESAFE_API_KEY=apikFAKEKEYFORTHELISTENER JEV_HOME="$W/home"
all=$(cut -f1 "$W/planted.tsv" | paste -sd'\n' -)
all="$all
Files: ${keep[0]} on ${keep[1]}"

# route.sh (the brief) and agent-route.sh (the Agent prompt)
"$J/route.sh" "Fix the deploy script. Context: $all" >/dev/null 2>&1 || bad "route.sh failed against the fake"
jq -cn --arg p "$all" '{session_id: "red", hook_event_name: "PreToolUse", tool_name: "Agent",
  tool_input: {description: "fix deploy", prompt: $p, subagent_type: "general-purpose", model: "haiku"}}' >"$W/agent.json"
JEV_ROUTE_MODE=escalate "$J/agent-route.sh" <"$W/agent.json" >/dev/null 2>&1
# a transcript with the secrets in a user message, a tool result and assistant text
jq -cn --arg t "$all" '
  {type: "user", uuid: "u1", promptSource: "typed", message: {role: "user", content: ("Remember this: " + $t)}},
  {type: "assistant", uuid: "a1", message: {role: "assistant", content: [{type: "text", text: ("Decision: we must use these settings because " + $t)},
    {type: "tool_use", id: "t1", name: "Bash", input: {command: "cat .env"}}]}},
  {type: "user", uuid: "u2", message: {role: "user", content: [{type: "tool_result", tool_use_id: "t1", is_error: true, content: $t}]}}' >"$W/t.jsonl"
jq -cn --arg tp "$W/t.jsonl" '{session_id: "red", transcript_path: $tp, hook_event_name: "Stop", stop_hook_active: false}' >"$W/stop.json"
"$J/ledger.sh" <"$W/stop.json"
jq -cn --arg tp "$W/t.jsonl" '{session_id: "red-v1", transcript_path: $tp, hook_event_name: "PreCompact", trigger: "manual"}' >"$W/pre.json"
JEV_LEDGER=0 "$J/compact-pre.sh" <"$W/pre.json"
jq -cn --arg m "<summary>$all</summary>" '{session_id: "red-v1", hook_event_name: "PostCompact", trigger: "manual", compact_summary: $m}' >"$W/post.json"
"$J/compact-post.sh" <"$W/post.json"
kill "$fpid" 2>/dev/null

n=$(find "$W/cap" -name 'body-*.json' 2>/dev/null | wc -l | tr -d ' ')
hooks=$(jq -r -s '[.[] | .hook] | unique | join(",")' "$W/home/log/jev.jsonl" 2>/dev/null)
[ "$n" -ge 5 ] && ok "$n request bodies captured (hooks that called out: $hooks)" || bad "only $n bodies captured ($hooks)"
leaks=0
while IFS=$'\t' read -r _ secret; do
  if grep -rlF -- "$secret" "$W/cap" >/dev/null 2>&1; then
    bad "secret left the machine: ${secret:0:12}… in $(grep -rlF -- "$secret" "$W/cap" | xargs -n1 basename | paste -sd, -)"
    leaks=$((leaks + 1))
  fi
done <"$W/planted.tsv"
grep -rqF 'apikFAKEKEYFORTHELISTENER' "$W/cap" && bad "the API key appears in a body or header capture" || ok "the API key is not in any captured body or header (Authorization recorded as <present>)"
[ "$leaks" -eq 0 ] && ok "none of the $(wc -l <"$W/planted.tsv" | tr -d ' ') planted secrets is in any captured body"
grep -rqF "${keep[0]}" "$W/cap" && grep -rqF "${keep[1]}" "$W/cap" && ok "paths and hostnames still reach Jev" || bad "paths/hostnames were redacted on the wire"
log "--- sample of a captured body (route.sh state.task):"
f=$(grep -lF 'Fix the deploy script' "$W"/cap/body-*.json | sed -n 1p)
jq -r '.state.task // empty' "$f" 2>/dev/null | sed -n 1,22p | sed 's/^/    /' | tee -a "$W/ev.txt" >/dev/null

log "redact: $fails failure(s)"
if [ "${JEV_LIVE:-0}" = 1 ] || [ "${JEV_EVIDENCE:-0}" = 1 ]; then sed "s#$W#<tmp>#g" "$W/ev.txt" >"$EVID"; fi
[ "$fails" -eq 0 ]
