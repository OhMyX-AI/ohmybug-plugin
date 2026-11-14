#!/bin/bash
# Say the one thing a new install cannot discover by itself: in auto mode the
# permission classifier reviews every call these tools make, because sending
# code to a cloud service is exactly what it is built to watch. Measured on
# Claude Code 2.1.293: it let a hunt start (a payload submit and a repo+ref one
# alike), but refused the reviewers' file request at every size tried, from
# 2 KB up: files a tool result asked for are the exfiltration shape it exists
# to stop, so it is provenance, not size. Splitting the answer cannot help, and
# a retry of a no-verdict denial passed rarely. So without the rule the
# reviewers lose the files they asked for mid-run, silently from the user's
# side. The rule that fixes it is not guessable. A no-payload hunt of a pushed
# commit on a repository the server can read never asks: the server reads the
# files from the repository itself.
#
# Claude Code gives a plugin NO way to ship a permission rule or to ask for one
# at install time, and that is deliberate: a plugin that widens its own
# permissions is the shape of the attack the classifier exists to catch. So this
# prints the rule and stops. Adding it is the user's click, in their own
# settings, and nothing here writes to those files.
#
# Printed ONCE per machine, and only while no rule mentions our tools — a plugin
# that reminds you of something you already did is a plugin you turn off.
#
# It runs before every call to an OhMyBug tool (PreToolUse, print-only, beside
# secret-scan.sh), not at SessionStart: the rule is named after the server the
# call goes through, and a session start has no tool name to give. Two more things it says there:
# - in auto mode, a submit_review while nothing decides provide_files: the
#   reviewers' mid-run file request is a second send nobody allowed, so say so
#   before the hunt (once per session).
# - on provide_files itself, in auto mode, while no rule covers it: tell the
#   ASSISTANT (additionalContext, which arrives even when the call is then
#   refused) to name the exact rule to the user and send again inside the
#   window, instead of letting the request expire.
set -euo pipefail

STATE=${OMB_STATE_DIR:-$HOME/.ohmybug}

# Codex loads these hooks too (manifest `hooks` lists hooks.json), and every
# sentence below is about Claude Code: its auto-mode classifier, its
# /permissions rule, its settings files, its tool namespace. Codex approves MCP
# tools in its own config and names them mcp__ohmybug__*, so the note would be
# wrong there — and, marked once per machine, would also silence the right one
# for a Claude Code session beside it. Codex is the client that sets PLUGIN_DATA
# (Claude Code sets only the CLAUDE_-prefixed names); nothing is written, so the
# other client still gets its turn.
[ -n "${PLUGIN_DATA:-}" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0
INPUT=$(cat 2>/dev/null) || INPUT=

mkdir -p "$STATE"
printf '%s' "$INPUT" | python3 -I -c '
import json, os, re, sys
state, home, proj = sys.argv[1:4]
try:
    d = json.loads(sys.stdin.read() or "{}")
except ValueError:
    d = {}
# A client that names no event: a tool call with no response is a PreToolUse.
event = d.get("hook_event_name") or ("PreToolUse" if d.get("tool_name") and "tool_response" not in d else "SessionStart")
tool = str(d.get("tool_name") or "")

# Every rule in the four files a user edits. Allow, ask and deny are all
# decisions: re-suggesting a rule against a deliberate deny would be nagging
# someone to undo their own choice.
# The rule is named after the server this call goes through (tool_name minus
# its last part): the plugin server, or a second server at the same URL that
# hides it. With no tool in hand there is no name to give, so nothing is said.
P = tool.rpartition("__")[0]
if event != "PreToolUse" or not re.fullmatch(r"mcp__[A-Za-z0-9_-]{1,120}", P):
    sys.exit(0)
rules = []
for f in (home + "/.claude/settings.json", home + "/.claude/settings.local.json",
          proj + "/.claude/settings.json", proj + "/.claude/settings.local.json"):
    try:
        text = open(f, encoding="utf-8", errors="replace").read()
    except OSError:
        continue
    try:
        perms = json.loads(text).get("permissions") or {}
    except (ValueError, AttributeError):
        continue
    for kind in ("allow", "ask", "deny"):
        rules += [r for r in perms.get(kind) or [] if isinstance(r, str)]
covers = lambda rs, t: any(r in (P, P + "__*", P + "__" + t) for r in rs)
mentioned = any(r == P or r.startswith(P + "__") for r in rules)
files_decided = covers(rules, "provide_files")

def once(mark):
    m = os.path.join(state, mark)
    if os.path.exists(m):
        return False
    open(m, "w").close()
    return True

auto = d.get("permission_mode") == "auto"
say, ctx = None, None
# One mark per server name: the plugin server keeps the old name, so a machine that
# heard it once is not told again; a second server gets one notice of its own.
mark = "permission-notice-v1" + ("" if P == "mcp__plugin_bughunter_ohmybug" else "-" + P)
if not mentioned:
    if once(mark):
        say = ("OhMyBug: the hunt runs in our cloud, so its tools send code off this machine.\n"
               "In auto mode the permission classifier reviews each of those calls, and it\n"
               "refuses the files the reviewers ask for mid-run, at any size; the hunt then\n"
               "goes on without them. One rule lets the OhMyBug\n"
               "tools through, and only you can add it — /permissions -> Add rule ->\n"
               + P + "__* . One tool at a time instead? Then allow both\n"
               + P + "__submit_review and " + P + "__provide_files .\n"
               + "Nothing will add them for you. With the rule, the files go through the plugin,\n"
               "read from disk; no shell command uploads them.")
else:
    once(mark)
# The careful user allows one tool at a time — a rule, or an approval under
# /permissions -> Recently denied, which lives in the session and in no file
# this hook can read. Either way a submit that goes ahead while nothing decides
# provide_files is a hunt whose file request is a second send nobody allowed:
# say so before the hunt, once per session (one file holding the last session).
if not say and auto and not files_decided and tool.endswith("__submit_review"):
    sid = str(d.get("session_id") or "")
    last = os.path.join(state, "permission-notice-files-session")
    try:
        seen = open(last).read()
    except OSError:
        seen = None
    if seen != sid:
        open(last, "w").write(sid)
        say = ("OhMyBug: no permission rule covers provide_files. When the reviewers ask for files\n"
               "mid-hunt, sending them is a second call; in auto mode the classifier will refuse\n"
               "it, at any size, and the hunt goes on without the files.\n"
               "To allow it: /permissions -> Add rule -> " + P + "__provide_files\n"
               "Without the rule: a hunt of a pushed commit with no payload, on a repository\n"
               "OhMyBug can read (App installed, or public), needs no file answer from you.")
if event == "PreToolUse" and auto and not files_decided and tool.endswith("__provide_files"):
    ctx = ("OhMyBug: no permission rule covers provide_files. If auto mode refuses this call,"
           " tell the user now, in one line, how to let it through: /permissions -> Add rule -> "
           + P + "__provide_files, or approve it under /permissions -> Recently denied (only they"
           " can; never add or widen a rule yourself). When they say it is done, call provide_files"
           " again for the same review: the file request stays open only a few minutes. Do not"
           " retry the refused call, and do not split it into smaller ones: without the rule it is"
           " refused at any size.")

if say or ctx:
    out = {}
    if say:
        out["systemMessage"] = say
    # systemMessage is what the USER reads; additionalContext is what the
    # assistant reads, so it can answer "why was that denied" without
    # re-deriving it.
    extra = "\n\n".join(x for x in (say, ctx) if x)
    out["hookSpecificOutput"] = {"hookEventName": event, "additionalContext": extra}
    print(json.dumps(out))
' "$STATE" "$HOME" "${CLAUDE_PROJECT_DIR:-$PWD}" || exit 0
