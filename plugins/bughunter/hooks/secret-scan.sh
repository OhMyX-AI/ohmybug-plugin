#!/bin/bash
# Refuse a submit_review whose inline payload carries a credential.
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
# provide_files' files. A repo+ref submit carries none, so nothing is read.
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
# provide_files still goes through python, which fills its paths unscanned.
if [ "${OHMYBUG_SECRET_SCAN:-1}" = 0 ]; then
  case "$INPUT" in *'__provide_files"'*) ;; *) pass ;; esac
fi
command -v python3 >/dev/null 2>&1 || {
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
from omb_scan import scan_payload, shown
ti = d.get("tool_input")
if ti is None:
    ti = {}
if not isinstance(ti, dict):
    raise TypeError("tool_input")

def stop(rc, msg):
    sys.stdout.buffer.write((msg + "\n").encode("utf-8"))
    sys.stdout.flush()
    sys.exit(rc)

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
    import stat
    RD = os.O_RDONLY | getattr(os, "O_BINARY", 0)
    NOFOLLOW, NONBLOCK, DIRECTORY = (getattr(os, f, 0) for f in ("O_NOFOLLOW", "O_NONBLOCK", "O_DIRECTORY"))

    def walk(p):
        # Opened one part at a time from the fd of the top level, never through a
        # symlink, and read from the fd that was checked: nothing can swap the file
        # between the check and the read. Only a listed file is read, at once, and
        # every fd is closed here, however many paths are asked for.
        try:
            # The name opened is the name sent: a part that is empty, "." or ".." is
            # refused, never tidied away, or "x/." would open x under another name.
            parts = os.fsencode(p).replace(os.fsencode(os.sep), b"/").split(b"/")
            while len(parts) > 1 and parts[0] == b".":
                parts = parts[1:]
            if any(c in (b"", b".", b"..") for c in parts):
                return None, None
            rel = b"/".join(parts)
            if os.open not in os.supports_dir_fd:
                # shortcut: no dir_fd (Windows python), so the whole path is checked for any link or
                # junction and then opened, a window for someone rewriting the checkout mid-call;
                # upgrade if it gains dir_fd.
                full = os.path.join(top, *parts)
                if os.path.realpath(full) != os.path.normpath(full):
                    return None, None
                before = os.stat(full)
                fd = os.open(full, RD | NONBLOCK)
                after = os.fstat(fd)
                if (after.st_ino, after.st_dev) != (before.st_ino, before.st_dev):
                    os.close(fd)
                    return None, None
            else:
                dfd = os.open(top, RD)
                try:
                    for c in parts[:-1]:
                        sub = os.open(c, RD | NOFOLLOW | DIRECTORY, dir_fd=dfd)
                        os.close(dfd)
                        dfd = sub
                    fd = os.open(parts[-1], RD | NOFOLLOW | NONBLOCK, dir_fd=dfd)
                finally:
                    os.close(dfd)
        except (OSError, ValueError):
            return None, None
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                return None, None
            if rel not in listed:
                return rel, None
            with open(fd, encoding="utf-8", errors="replace", closefd=False) as f:
                return rel, f.read()
        except OSError:
            return None, None
        finally:
            os.close(fd)

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
if os.environ.get("OHMYBUG_SECRET_SCAN", "1") == "0":
    ti = {}

hits = []
scan_payload(hits, ti)

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
if [ "$rc" = 5 ]; then
  echo "OhMyBug: provide_files paths are read from the git repository this session runs in, and this directory is not inside one, so nothing was sent. Call provide_files again with files [{path, content}] for the files you approve." >&2
  exit 2
fi
if [ "$rc" != 3 ] || [ -z "$OUT" ]; then
  {
    echo "OhMyBug: could not scan this payload for credentials, so it was NOT sent."
    case "$INPUT" in
      *'__provide_files"'*) echo "Call provide_files again for the same review (do not start a new hunt for this), or set OHMYBUG_SECRET_SCAN=0 to skip the scan." ;;
      *) echo "Resend it, or set OHMYBUG_SECRET_SCAN=0 to skip the scan. A submit with meta.repo + meta.ref and no payload has nothing to scan." ;;
    esac
  } >&2
  exit 2
fi
{
  echo "OhMyBug: this upload carries what looks like credentials, so it was NOT sent:"
  printf '%s\n' "$OUT" | LC_ALL=C sed 's/^/  - /'
  case "$INPUT" in
    *'__provide_files"'*) echo "Call provide_files again for the same review without those files (or with each value replaced by [REDACTED]); an empty list is a valid answer. Do not start a new hunt for this." ;;
    *) echo "Drop those files or replace each value with [REDACTED], then submit again. Or submit with meta.repo + meta.ref and no payload: the server reads the pushed commit and nothing leaves this machine." ;;
  esac
} >&2
exit 2
