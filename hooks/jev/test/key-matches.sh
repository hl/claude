#!/usr/bin/env bash
# key-matches.sh <expected> — exit 0 if lib.sh's key lookup yields exactly
# <expected> ("" = no key found). Never prints the key.
set -uo pipefail
export JEV_MIGRATE=0 # tests never move this machine's real ~/.claude/jev
J=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=SCRIPTDIR/../lib.sh
. "$J/lib.sh"
if jev_load_key; then [ "$JEV_KEY" = "$1" ]; else [ -z "$1" ]; fi
