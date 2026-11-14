#!/bin/bash
# Ask the model to check, at the start of a session, that this plugin's MCP
# tools are actually present — and to say so at once if they are not.
#
# Why a hook has to say this: a session whose MCP handshake failed (a refused
# or timed-out connection at startup) has no tools and no way to get them —
# the client does not retry the handshake, and in-app sessions cannot
# reconnect a server. Left alone, the model discovers that at the merge gate,
# hours later, when it tries to hand in a hunt it can no longer run; every
# minute of work before that is work it cannot deliver. Told at the start, the
# remedy is a restart that costs a minute.
#
# additionalContext only, on a NEW process (hooks.json matcher `startup|resume`
# — a resumed session handshakes again; a cleared or compacted one does not), no state:
# this is an instruction to the assistant, not news for the user's screen — the
# user hears about it from the assistant exactly when it matters (the tools are
# missing), not on every start. Once, and the user decides: the tools can be
# absent for reasons a restart cannot change (the server disabled, no sign-in
# yet, offline), and a plugin that refuses the user's own work over that is the
# trap the merge gate promises not to be. Codex is routed by codex-router.js,
# which carries the same sentence in its own words (its tool names differ), so
# nothing is said here under Codex. And nothing is said when python3 is not
# there to say it: a hook that cannot speak stands down, it does not fail the
# session start with a stack of stderr.
set -euo pipefail

[ -n "${PLUGIN_DATA:-}" ] && exit 0

# A user who also added the OhMyBug server with `claude mcp add` gets that server's
# tools under another name (mcp__ohmybug__* by the README's line): Claude Code
# hides the plugin server of the same URL. The hooks, the permission advice and the
# merge gate know only the plugin's tool names, so that setup is not supported; a
# restart does not change it, removing the added server does.
NOTE='First thing this session: confirm the OhMyBug MCP tools (mcp__plugin_bughunter_ohmybug__*) are present. If they are not, but OhMyBug tools are there under another server name (mcp__ohmybug__*, or any mcp__<name>__submit_review beside get_findings and confirm_findings), the user added the OhMyBug server themselves and Claude Code hides the plugin server of the same URL: tell the user once, now, that the plugin hooks, permission advice and merge gate do not recognise those tools, and that claude mcp remove <that name> and a restart bring the plugin server back (a restart alone does not); then let the user decide and go on with what they asked. If no OhMyBug tools are there at all, tell the user once, now — a session that began without them will not get them, and a restart (claude -c) usually does — then let the user decide and go on with what they asked; do not leave the discovery to the merge gate hours later.'

python3 - "$NOTE" <<'PY' || exit 0
import json, sys
print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": sys.argv[1]}}))
PY
