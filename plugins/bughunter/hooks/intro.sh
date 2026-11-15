#!/bin/bash
# The first-session notice: asks the assistant to run the skill's First-run
# setup (three questions that set the account's defaults) at the start of its
# first reply. It only ADDS context: the setup itself needs the question tool,
# so a session without one (a headless `claude -p` run) asks, writes and marks
# nothing. The hook never writes the marker: only a finished (or skipped)
# setup does, through `intro.sh done`. Offered at most 3 times per machine
# (a counter file), so a persistent headless machine stops hearing it.
#
# intro.sh        SessionStart: the notice, or nothing
# intro.sh done   write the marker; print the UTC time for intro.at
set -euo pipefail

STATE=${OMB_STATE_DIR:-$HOME/.ohmybug}
MARK=$STATE/intro-v1
OFFERS=$STATE/intro-v1-offers
CAP=3

if [ "${1:-}" = done ]; then
  mkdir -p "$STATE" && : > "$MARK"
  date -u +%Y-%m-%dT%H:%M:%SZ
  exit 0
fi

# Codex: codex-router.js carries its own one-line offer.
[ -n "${PLUGIN_DATA:-}" ] && exit 0
[ -f "$MARK" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0
# Only a new session: a resumed, cleared or compacted one is mid-task, and
# would burn an offer. hooks.json runs this on startup only; the source check
# holds the same line when a client runs it on another source anyway.
src=$(python3 -I -c 'import json, sys
try: print(json.loads(sys.stdin.read() or "{}").get("source") or "")
except Exception: print("")' 2>/dev/null) || src=
case $src in ''|startup) ;; *) exit 0 ;; esac
n=$(cat "$OFFERS" 2>/dev/null || :)
case $n in ''|*[!0-9]*) n=0 ;; ????????*) exit 0 ;; esac
n=$((10#$n))
[ "$n" -ge "$CAP" ] && exit 0
# A counter that cannot be written would offer forever: no offer then.
{ mkdir -p "$STATE" && printf '%s\n' "$((n + 1))" > "$OFFERS"; } 2>/dev/null || exit 0

NOTE='OhMyBug is installed. Three quick questions set your defaults: /bughunter:setup'
CONTEXT='Run the First-run setup of the bughunter skill at the start of your first reply, then answer what the user asked. Only with the question tool: if this session has none, do nothing and say nothing about it.'
python3 -I - "$NOTE" "$CONTEXT" <<'PY'
import json, sys
print(json.dumps({
    "systemMessage": sys.argv[1],
    "hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": sys.argv[2]},
}))
PY
