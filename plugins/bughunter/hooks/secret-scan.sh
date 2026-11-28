#!/bin/bash
# Refuse a submit_review whose payload or any other text it carries (meta on every submit) holds a credential, and a challenge_finding (a dispute) that quotes
# one or cites a path git does not list in this repository.
#
# Why a shell hook and not the Claude Code mod: a check that only some clients
# run is a check the others silently lack. This one fires wherever hooks.json
# does — Claude Code of any version, and Codex — so the same diff is refused
# everywhere, headless runs included (a refusal, never a dialog nobody answers).
#
# The detector itself is omb_scan.py beside this hook, the one copy of the
# shapes: high-signal ones only, every value masked. This hook reads the call.
#
# It reads whatever payload the call carries: submit_review's diff and files,
# provide_files' files, every string of a challenge_finding, an ask_ohmybug question, a send_feedback text, and every other field of a call
# (a submit's meta, sent on every submit, a repo+ref one included).
#
# It also FILLS provide_files' `paths`: the agent names the requested files,
# and this hook reads them from disk and hands the call on with their contents
# (updatedInput). In auto mode the classifier refuses a shell POST of repo
# files as data exfiltration, and the permission rule the first-run notice
# suggests covers MCP tools only; this keeps the answer an MCP call that rule
# covers, with no bytes through the model's context. It never decides a
# permission: it only rewrites the call the user already allowed. The bytes it
# reads are scanned below like any other payload. Not under Codex (it sets
# PLUGIN_DATA): there the paths reach the server, which refuses them and points
# at its own door.
#
# It is the ONE PreToolUse hook on submit_review, and it hands the call on to
# stamp-hunt.sh only when it lets the call through. Two hooks in parallel would
# let stamp-hunt record an attempt for a call this scan refuses; nothing clears
# that record, and the merge gate reads a lone attempt as "the environment
# refused the hunt" and warns the merge through.
set -u

STAMP=${OHMYBUG_TEST_STAMP:-$(dirname "$0")/stamp-hunt.sh}
INPUT=$(cat 2>/dev/null) || INPUT=
pass() { # the call goes on: a submit is recorded exactly as before
  case "$INPUT" in *'__submit_review"'*) printf '%s' "$INPUT" | exec bash "$STAMP" ;; esac
  exit 0
}
# The user's way out, in the env block of settings.json: no scan at all. A
# provide_files still goes through python, which fills its paths unscanned, and
# a challenge_finding still has its paths checked against git.
if [ "${OHMYBUG_SECRET_SCAN:-1}" = 0 ]; then
  # A dispute's paths are still held to the repository below: the opt-out skips the credential scan only.
  case "$INPUT" in *'__provide_files"'*|*'__challenge_finding"'*) ;; *) pass ;; esac
fi
command -v python3 >/dev/null 2>&1 || {
  case "$INPUT" in *'__challenge_finding"'*)
    echo "OhMyBug: a dispute is checked before it is sent (its paths against git, its text for credentials), and python3 is not found, so it was NOT sent. Judge the finding without a dispute." >&2
    exit 2 ;;
  esac
  printf '%s\n' '{"systemMessage":"OhMyBug: secret scan skipped before this upload (python3 not found)."}'
  pass
}

# The rule that closes every edge at once: the scan passes a call only when it
# READ the call and found nothing (exit 0), and refuses on a hit (exit 3). Any
# other outcome — unreadable input, a payload of an unexpected shape, a bug in
# here — is "could not scan", and that refuses too. Passing on its own failure
# is how a check turns into a hole for every input it did not foresee.
# Bytes in, bytes out, UTF-8 both ways: nothing below depends on the locale.
# A missing detector fails the import, and that refuses like any other failure.
# -I: no PYTHON* variables, and neither the session's folder nor the user's site
# on sys.path. The hook runs inside the user's repository, where a json.py
# would otherwise be imported in place of the standard one. -B: no bytecode
# written into the plugin folder (-I ignores PYTHONDONTWRITEBYTECODE).
OUT=$(printf '%s' "$INPUT" | OMB_SCAN_DIR="$(dirname "$0")" python3 -I -B -c '
import json, os, re, sys
d = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
if os.environ.get("OHMYBUG_TEST_SCAN_RAISE"):
    raise RuntimeError("forced by the test")
sys.path.insert(0, os.environ["OMB_SCAN_DIR"])
from omb_scan import scan, scan_payload, shown
dstrings = []
ti = d.get("tool_input")
if ti is None:
    ti = {}
if not isinstance(ti, dict):
    raise TypeError("tool_input")

def stop(rc, msg):
    sys.stdout.buffer.write((msg + "\n").encode("utf-8"))
    sys.stdout.flush()
    sys.exit(rc)

# Every string under a value, with a label that says where it sits. Scanned by content only (scan, not
# scan_payload): a label is not a file name, so it never meets the key-file check. A dict key is a string too.
# A key that itself looks like a credential never goes into a label in full: the label is printed.
def named(k):
    kh = []
    scan(kh, "", str(k))
    return "<flagged key>" if kh else str(k)

def collect(v, where, flat=False):
    if isinstance(v, str):
        dstrings.append((where, v))
    elif isinstance(v, dict):
        for k, x in v.items():
            dstrings.append((where + " key", k))
            collect(x, where if flat and k in ("note", "claim") else "%s.%s" % (where, named(k)), flat)
    elif isinstance(v, list):
        for i, x in enumerate(v):
            collect(x, "%s[%d]" % (where, i), flat)


# The selection rules of the files_url recipe the server hands out: the git top level of
# the session directory, a regular file whose path git lists as tracked or
# untracked-not-ignored, with no symlink in any part of that path. Missing,
# unreadable, not a regular file, a symlink, an empty, "." or ".." part, under
# .git or outside: skipped and named. Inside the
# work tree but not listed (ignored, or in a submodule): nothing is sent, the
# agent decides.
filled = None
if str(d.get("tool_name") or "").endswith("__provide_files") and "paths" in ti and not os.environ.get("PLUGIN_DATA"):
    import subprocess
    paths = ti["paths"]
    if not isinstance(paths, list) or not all(isinstance(p, str) for p in paths):
        raise TypeError("paths")
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    try:
        top = subprocess.check_output(["git", "rev-parse", "--show-toplevel"], cwd=d.get("cwd") or None,
                                      env=env, stderr=subprocess.DEVNULL).rstrip(b"\n")
    except (OSError, subprocess.CalledProcessError):
        stop(5, "")
    top = os.path.realpath(top)
    listed = set(subprocess.check_output(["git", "ls-files", "-z", "-co", "--exclude-standard"], cwd=top, env=env).split(b"\0"))
    from omb_scan import read_listed

    def walk(p):
        # The fd walk lives in omb_scan.read_listed (the upload script reads its
        # context files with it too); a listed file is decoded here with
        # replacement, as before.
        rel, data = read_listed(top, listed, p)
        if data is None:
            return rel, None
        # Universal newlines, as the text-mode read before it: CRLF and CR become LF.
        return rel, data.decode("utf-8", errors="replace").replace("\r\n", "\n").replace("\r", "\n")

    files = list(ti.get("files") or [])
    sent, skipped, unlisted, read = [], [], [], []
    for p in paths:
        rel, content = walk(p)
        if rel is not None and rel in listed:
            sent.append(p)
            read.append({"path": p, "content": content})
        elif rel is not None and not rel.startswith(b"../") and rel.split(b"/")[0] != b".git":
            unlisted.append(p)
        else:
            skipped.append(p)
    if unlisted:
        stop(4, "\n".join("  - " + p for p in unlisted))
    files += read
    filled = {k: v for k, v in ti.items() if k != "paths"}
    filled["files"] = files
    ti = filled
    note = "OhMyBug read %d requested file(s) from disk for provide_files%s." % (len(sent), (": " + ", ".join(sent)) if sent else "")
    if skipped:
        note += " Not sent (missing, unreadable, not a regular file, a symlink, under .git or outside the repository): " + ", ".join(skipped) + "."
# A dispute (challenge_finding) sends a claim and notes on lines of the repository. Each evidence path must be a
# regular file git lists in this repository, reached with no symlink (the provide_files rule, omb_scan.read_listed),
# and not a file that holds keys in any letter case: so a spelling (a backslash, a case variant, a nested .git, a
# path outside) cannot pass, even with the scan turned off. Every string the call carries is scanned like a file.
if str(d.get("tool_name") or "").endswith("__challenge_finding"):
    import subprocess
    from omb_scan import KEY_FILE, ENV_FILE, read_listed

    def shape(field):
        stop(7, field)

    if not isinstance(ti.get("finding_id"), str) or not ti.get("finding_id"):
        shape("finding_id must be the id string of a finding")
    if not isinstance(ti.get("claim"), str):
        shape("claim must be a string")
    if len(ti["claim"]) > 1500:
        shape("claim is longer than 1500 characters")
    ev = ti.get("evidence")
    ev = [] if ev is None else ev
    if not isinstance(ev, list):
        shape("evidence must be a list of {path, line, note}")
    if len(ev) > 5:
        shape("at most 5 evidence items")
    for e in ev:
        if not isinstance(e, dict) or not isinstance(e.get("path"), str):
            shape("each evidence item needs a string path")
        if e.get("note") is not None and not isinstance(e.get("note"), str):
            shape("an evidence note must be a string")
        if isinstance(e.get("note"), str) and len(e["note"]) > 400:
            shape("an evidence note is longer than 400 characters")
        ln = e.get("line")
        if ln is not None and (isinstance(ln, bool) or not isinstance(ln, int) or ln < 1):
            shape("an evidence line must be a whole number from 1")
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    try:
        top = subprocess.check_output(["git", "rev-parse", "--show-toplevel"], cwd=d.get("cwd") or None,
                                      env=env, stderr=subprocess.DEVNULL).rstrip(b"\n")
    except (OSError, subprocess.CalledProcessError):
        stop(8, "")
    top = os.path.realpath(top)
    # Tracked files only (no -o): the service reads the hunted commit, where an untracked file does not exist.
    listed = set(subprocess.check_output(["git", "ls-files", "-z"], cwd=top, env=env).split(b"\0"))
    bad = []
    for e in ev:
        rel, data = read_listed(top, listed, e["path"])
        name = rel.decode("utf-8", "replace").lower() if rel is not None else ""
        if data is None or KEY_FILE.search(name) or ENV_FILE.search(name):
            bad.append(e["path"])
        elif e.get("line") is not None and e["line"] > data.count(b"\n") + (0 if data.endswith(b"\n") or not data else 1):
            bad.append("%s (line %d is past its end)" % (e["path"], e["line"]))
    if bad:
        stop(6, "\n".join("  - " + p for p in bad))
    for k, v in ti.items():
        dstrings.append(("field name", k))
        if k != "evidence":
            collect(v, named(k), True)
    for i, e in enumerate(ev):
        collect({k: v for k, v in e.items() if k != "path"}, "evidence[%d] note (%s)" % (i, e["path"]), True)
    ti = {}
if os.environ.get("OHMYBUG_SECRET_SCAN", "1") == "0":
    ti, dstrings = {}, []

hits = []
scan_payload(hits, ti)
# Every other string the call carries leaves the machine too (meta on every submit, a repo+ref one included), so
# each is read whatever its key, shape and depth: no list of known keys to fall behind the server.
for k, v in ti.items():
    dstrings.append(("field name", k))
    if k not in ("diff", "files"):
        collect(v, named(k))
# scan_payload reads the content of a file entry and checks its path against key-file names; every other field, the path text included, is read here.
for i, f in enumerate(ti.get("files") or []):
    if isinstance(f, dict):
        collect({k: v for k, v in f.items() if k != "content"}, "files[%d]" % i)
for where, text in dstrings:
    scan(hits, where, text)

if hits:
    stop(3, "\n".join(shown(hits)))
if filled is not None:
    stop(0, json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "updatedInput": filled, "additionalContext": note}}))
' 2>/dev/null)
rc=$?
if [ "$rc" = 0 ]; then
  [ -n "$OUT" ] && printf '%s\n' "$OUT"
  pass
fi
if [ "$rc" = 4 ] && [ -n "$OUT" ]; then
  {
    echo "OhMyBug: git does not list these requested files (ignored: build output, generated code, a secret; or in a submodule), so nothing was sent:"
    printf '%s\n' "$OUT"
    echo "Call provide_files again for the same review without them in paths. If the user approves sending them, put them in files with their content instead."
  } >&2
  exit 2
fi
if [ "$rc" = 6 ] && [ -n "$OUT" ]; then
  {
    echo "OhMyBug: a dispute cites only lines that exist in files git tracks in this repository, by a path relative to its root (no empty, \".\" or \"..\" part, no symlink), never a file that holds keys. Not sent, because of:"
    printf '%s\n' "$OUT"
    echo "Fix or drop those items; a dispute you change goes back to the user for a new yes before you send it. Or judge the finding without a dispute."
  } >&2
  exit 2
fi
if [ "$rc" = 7 ] && [ -n "$OUT" ]; then
  echo "OhMyBug: this dispute is not the shape challenge_finding takes ($OUT), so it was NOT sent. Send {finding_id, claim, evidence: [{path, line, note}]}, or judge the finding without a dispute." >&2
  exit 2
fi
if [ "$rc" = 8 ]; then
  echo "OhMyBug: a dispute's paths are checked against the git repository this session runs in, and this directory is not inside one, so it was NOT sent. Judge the finding without a dispute." >&2
  exit 2
fi
if [ "$rc" = 5 ]; then
  echo "OhMyBug: provide_files paths are read from the git repository this session runs in, and this directory is not inside one, so nothing was sent. Call provide_files again with files [{path, content}] for the files you approve." >&2
  exit 2
fi
if [ "$rc" != 3 ] || [ -z "$OUT" ]; then
  {
    echo "OhMyBug: could not scan this payload for credentials, so it was NOT sent."
    case "$INPUT" in
      *'__provide_files"'*) echo "Call provide_files again for the same review (do not start a new hunt for this), or set OHMYBUG_SECRET_SCAN=0 to skip the scan." ;;
      *'__challenge_finding"'*) echo "Dispute again, or judge the finding without a dispute." ;;
      *) echo "Resend it, or set OHMYBUG_SECRET_SCAN=0 to skip the scan." ;;
    esac
  } >&2
  exit 2
fi
{
  echo "OhMyBug: this call carries what looks like credentials, so it was NOT sent:"
  printf '%s\n' "$OUT" | LC_ALL=C sed 's/^/  - /'
  case "$INPUT" in
    *'__provide_files"'*) echo "Call provide_files again for the same review without those files (or with each value replaced by [REDACTED]); an empty list is a valid answer. Do not start a new hunt for this." ;;
    *'__challenge_finding"'*) echo "Dispute again with each value named instead of quoted, or judge the finding without a dispute." ;;
    *'__ask_ohmybug"'*) echo "Ask again with each value replaced by [REDACTED]." ;;
    *'__send_feedback"'*) echo "Show the user the text with each value replaced by [REDACTED], and send it only after they confirm it again." ;;
    *) echo "Replace each value with [REDACTED] where it is named above, or leave that file or meta field out, then submit again. The text in meta (the task, the PR title and description, the briefing) is sent on every submit: a submit with meta.repo + meta.ref and no payload drops the diff and files only." ;;
  esac
} >&2
exit 2
