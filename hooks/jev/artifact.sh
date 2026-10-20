#!/usr/bin/env bash
# artifact.sh — save a deliverable (report, review, findings) where it survives
# compaction: the artifact index is re-injected after every compaction.
#
#   artifact.sh <name> [--from-file <path>] [--session <id>]     (content on stdin otherwise)
#
# Writes ~/.local/state/jev/artifacts/<session_id>/<name>.md and prints that
# path. Writing the same name again replaces the file. Content over
# JEV_ARTIFACT_MAX_BYTES (512 KB) is cut, with a note saying so.
#
# Session id, first match wins: --session, $CLAUDE_CODE_SESSION_ID (exported to
# Bash tool commands and hooks by Claude Code 2.1.302, subagents included),
# $CLAUDE_SESSION_ID. Exits 2 when none is found.
# Local only: nothing is sent anywhere.
set -euo pipefail
JEV_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
JEV_HOOK=artifact
# shellcheck source=SCRIPTDIR/lib.sh
. "$JEV_DIR/lib.sh"

usage() {
  echo "usage: artifact.sh <name> [--from-file <path>] [--session <id>]   (content on stdin otherwise)" >&2
  exit 2
}
name=${1:-}
[ -n "$name" ] && [ "${name#-}" = "$name" ] || usage
shift
from="" sid=""
while [ $# -gt 0 ]; do
  case $1 in
    --from-file)
      [ $# -ge 2 ] || usage
      from=$2
      shift 2
      ;;
    --session)
      [ $# -ge 2 ] || usage
      sid=$2
      shift 2
      ;;
    *) usage ;;
  esac
done

[ -n "$sid" ] || sid=${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}
case $sid in
  '') echo "artifact.sh: no session id (pass --session <id>)" >&2 && exit 2 ;;
  *[!A-Za-z0-9._-]*) echo "artifact.sh: bad session id" >&2 && exit 2 ;;
esac

name=${name%.md}
name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '-' | sed -e 's/--*/-/g' -e 's/^[-.]*//' | cut -c1-80)
[ -n "$name" ] || usage
dir="$JEV_HOME/artifacts/$sid"
mkdir -p "$dir"
path="$dir/$name.md"
tmpf=$(mktemp "$dir/.tmp.XXXXXX")
trap 'rm -f "$tmpf" "$tmpf.cut"' EXIT
if [ -n "$from" ]; then
  [ -r "$from" ] || {
    echo "artifact.sh: cannot read $from" >&2
    exit 2
  }
  cat "$from" >"$tmpf"
else
  cat >"$tmpf"
fi
[ -s "$tmpf" ] || {
  rm -f "$tmpf"
  echo "artifact.sh: empty content, nothing saved" >&2
  exit 2
}
size=$(wc -c <"$tmpf" | tr -d ' ')
cap=${JEV_ARTIFACT_MAX_BYTES:-524288}
if [ "$size" -gt "$cap" ]; then
  head -c "$cap" "$tmpf" | iconv -c -f UTF-8 -t UTF-8 >"$tmpf.cut" 2>/dev/null || head -c "$cap" "$tmpf" >"$tmpf.cut"
  printf '\n\n[truncated by artifact.sh: %s of %s bytes kept]\n' "$cap" "$size" >>"$tmpf.cut"
  mv "$tmpf.cut" "$tmpf"
  echo "artifact.sh: content cut to $cap of $size bytes" >&2
fi
mv "$tmpf" "$path"
echo "$path"
