#!/bin/bash
# Run me after touching secret-scan.sh: `hooks/secret-scan-test.sh`
#
# Tokens are glued together at run time, so this public file never holds a
# string that a secret scanner (ours, or a push protection) reads as a key.
set -u
G=$(cd "$(dirname "$0")" && pwd)
fails=0

AWS="AKIA""QWERTYUIOPASDFGH"
GHP="ghp_""$(printf 'a%.0s' $(seq 1 36))"
PEM="-----BEGIN RSA ""PRIVATE KEY-----"
PGP="-----BEGIN PGP ""PRIVATE KEY BLOCK-----"
R=$(printf 'Ab1c%.0s' $(seq 1 10)) # 40 characters no placeholder rule reads as filler
SLACK="xox""b-${R:0:24}"
STRIPE="sk_""live_${R:0:24}"
GOOGLE="AI""za${R:0:34}-" # ends in '-', where a \b never matches
ANTHROPIC="sk-""ant-api03-${R:0:32}"
OPENAI="sk-""proj-${R:0:40}"

# stamp-hunt.sh is chained from the scan; a stub stands in for it and leaves a
# mark, so a row can tell "recorded" from "refused before recording".
STUB=$(mktemp -d); MARK="$STUB/stamped"
printf '#!/bin/sh\ncat >/dev/null\n: > "%s"\n' "$MARK" > "$STUB/stamp.sh"
export OHMYBUG_TEST_STAMP="$STUB/stamp.sh"
TOOL=submit_review
hook() { # tool_input JSON -> "<exit> <stderr>"; the tool is $TOOL
  local err rc
  rm -f "$MARK"
  # Raw UTF-8 bytes, not \u escapes: that is what a client sends, and only raw
  # bytes reach a stdin decoded in the locale codec.
  err=$(python3 -c "import json,sys; sys.stdout.buffer.write(json.dumps({'tool_name':'mcp__plugin_bughunter_ohmybug__'+sys.argv[2],'tool_input':json.loads(sys.argv[1])}, ensure_ascii=False).encode('utf-8'))" "$1" "$TOOL" \
    | bash "$G/secret-scan.sh" 2>&1 >/dev/null); rc=$?
  printf '%s %s' "$rc" "$err"
}
stamped() { [ -e "$MARK" ] && echo yes || echo no; }
check() { # name, got, want
  [ "$2" = "$3" ] && echo "ok   $1" || { echo "FAIL $1: got $2, want $3"; fails=$((fails + 1)); }
}
row() { # name, want exit, tool_input JSON, [text the message must hold]
  local got; got=$(hook "$3")
  if [ "${got%% *}" != "$2" ]; then echo "FAIL $1: exit ${got%% *}, want $2 — ${got#* }"; fails=$((fails + 1)); return; fi
  if [ -n "${4:-}" ] && ! printf '%s' "$got" | LC_ALL=C grep -qF -- "$4"; then echo "FAIL $1: message lacks '$4' — ${got#* }"; fails=$((fails + 1)); return; fi
  echo "ok   $1"
}
j() { python3 -c "import json,sys; print(json.dumps(eval(sys.argv[1])))" "$1"; }

row "AWS key in the diff names file and line"   2 "$(j "{'diff':'+++ b/app.py\n@@ -1,2 +1,3 @@\n x = 1\n+key = \"$AWS\"\n'}")" "app.py:2 AWS access key"
row "the refusal masks the value"               2 "$(j "{'diff':'+k=\"$AWS\"'}")" "AKIA...GH"
row "GitHub token in a context file"            2 "$(j "{'files':[{'path':'ci.sh','content':'export T=$GHP'}]}")" "ci.sh:1 GitHub token"
row "private key block"                          2 "$(j "{'files':[{'path':'fixture.txt','content':'$PEM'}]}")" "private key"
row "a whole .env attached as context"          2 "$(j "{'files':[{'path':'deploy/.env.staging','content':'PORT=3000'}]}")" ".env.staging is a file that holds keys"
row "a diff touching a .pem file"               2 "$(j "{'diff':'+++ b/certs/server.pem\n+abc\n'}")" "server.pem"
for shape in "Slack token:$SLACK" "Stripe live key:$STRIPE" "Google API key:$GOOGLE" "Anthropic key:$ANTHROPIC" "OpenAI key:$OPENAI" "private key:$PGP"; do
  row "${shape%%:*} in a context file" 2 "$(j "{'files':[{'path':'ci.sh','content':'T=${shape#*:}'}]}")" "ci.sh:1 ${shape%%:*}"
done
for name in id_rsa id_dsa id_ecdsa id_ed25519 k.pem k.p12 k.pfx k.key .env; do
  row "$name attached as context is refused" 2 "$(j "{'files':[{'path':'keys/$name','content':'x'}]}")" "keys/$name is a file that holds keys"
done
row "a secret in a deleted file names that file" 2 "$(j "{'diff':'--- a/old.py\n+++ /dev/null\n@@ -1,1 +0,0 @@\n-k = \"$AWS\"\n'}")" "old.py (a removed line) AWS access key"
row "a diff deleting a key file is refused"      2 "$(j "{'diff':'--- a/certs/old.pem\n+++ /dev/null\n@@ -1,1 +0,0 @@\n-abc\n'}")" "diff changes certs/old.pem"
row "AWS documentation placeholder passes"      0 "$(j "{'diff':'+k=\"AKIAIOSFODNN7EXAMPLE\"'}")"
row ".env.example attached passes"              0 "$(j "{'files':[{'path':'.env.example','content':'PORT=3000'}]}")"
row "a diff touching .env with no secret passes" 0 "$(j "{'diff':'+++ b/.env\n+PORT=3000\n'}")"
row "clean diff passes"                          0 "$(j "{'diff':'+++ b/a.py\n+print(1)\n'}")"
row "repo+ref submit has nothing to scan"       0 "$(j "{'meta':{'repo':'o/r','ref':'abc','base_branch':'main'}}")"
row "a removed '-- ' line inside a hunk is scanned" 2 "$(j "{'diff':'--- a/q.sql\n+++ b/q.sql\n@@ -1,2 +1,1 @@\n--- key $AWS\n x\n'}")" "q.sql (a removed line) AWS access key"
row "upload=true still reads an inline payload" 2 "$(j "{'upload':True,'diff':'+k=\"$AWS\"'}")" "AWS access key"
row "upload=true with no payload passes"        0 "$(j "{'upload':True}")"
TOOL=provide_files
row "provide_files carrying a token is refused" 2 "$(j "{'review_id':'r','files':[{'path':'ci.sh','content':'T=$GHP'}]}")" "ci.sh:1 GitHub token"
row "a refused provide_files is told to resend, not to hunt again" 2 "$(j "{'review_id':'r','files':[{'path':'ci.sh','content':'T=$GHP'}]}")" "Call provide_files again"
TOOL=submit_review

# A refused submit must leave no attempt behind: the gate reads a lone attempt
# as "the environment refused the hunt" and warns the merge through.
hook "$(j "{'diff':'+k=\"$AWS\"'}")" >/dev/null; check "a refused submit is not recorded" "$(stamped)" no
hook "$(j "{'diff':'+print(1)'}")" >/dev/null; check "a clean submit is recorded" "$(stamped)" yes
TOOL=provide_files; hook "$(j "{'files':[{'path':'a','content':'x'}]}")" >/dev/null; check "provide_files is never recorded" "$(stamped)" no; TOOL=submit_review
wired=$(python3 - "$G/hooks.json" <<'PY2'
import json, re, sys
pre = json.load(open(sys.argv[1]))["hooks"]["PreToolUse"]
# first-run.sh rides beside it on every OhMyBug tool, print-only: it never
# refuses and records nothing, so it cannot split "scanned" from "recorded".
print(" ".join(c for c in (k["command"].rsplit("/", 1)[-1] for e in pre
               if re.search(e.get("matcher", ""), "mcp__plugin_bughunter_ohmybug__submit_review") for k in e["hooks"])
               if c != "first-run.sh"))
PY2
)
check "submit_review has one PreToolUse hook, the scan" "$wired" "secret-scan.sh"

full=$(hook "$(j "{'diff':'+k=\"$AWS\"'}")")
if printf '%s' "$full" | LC_ALL=C grep -qF "$AWS"; then echo "FAIL the full key reached the message"; fails=$((fails + 1)); else echo "ok   the full key never reaches the message"; fi

# The scan must read and report under any locale. Each of these once broke a
# step (a print that raised, a stdin decoded in the locale codec), and the hook
# then read its own failure as "nothing found". A locale the machine lacks is a
# failure here, not a skip: CI generates them (see ci.yaml).
for lc in en_US.ISO8859-1:iso8859-1 ja_JP.eucJP:euc_jp zh_CN.GBK:gbk; do
  loc=${lc%:*}
  # A missing locale falls back to C/UTF-8 and the row would pass for nothing.
  got=$(LC_ALL=$loc PYTHONUTF8=0 python3 -c 'import codecs, locale; print(codecs.lookup(locale.getpreferredencoding(False)).name)' 2>/dev/null)
  if [ "$got" != "${lc#*:}" ]; then
    echo "FAIL locale $loc is not installed (python reads ${got:-nothing}), so its row cannot run"; fails=$((fails + 1)); continue
  fi
  LC_ALL=$loc LANG=$loc PYTHONUTF8=0 PYTHONIOENCODING= row "a key is refused under $loc, its file named" 2 "$(j "{'files':[{'path':'\u65e5.md','content':'\u65e5\u672c \u4e2d\u6587 k=$AWS'}]}")" ".md:1 AWS access key"
done

# A scan that fails refuses: it never lets through what it did not read.
OHMYBUG_TEST_SCAN_RAISE=1 row "an error inside the scan refuses" 2 "$(j "{'diff':'+print(1)'}")" "could not scan this payload"
OHMYBUG_TEST_SCAN_RAISE=1 hook "$(j "{'diff':'+print(1)'}")" >/dev/null; check "a scan that failed records nothing" "$(stamped)" no
TOOL=provide_files
OHMYBUG_TEST_SCAN_RAISE=1 row "a provide_files that could not be scanned is told to resend" 2 "$(j "{'files':[{'path':'a','content':'x'}]}")" "Call provide_files again"
TOOL=submit_review
row "a payload of an unexpected shape refuses"  2 "$(j "{'files':'not a list'}")" "could not scan"
rc=$(printf 'not json' | bash "$G/secret-scan.sh" >/dev/null 2>&1; echo $?)
check "unreadable input refuses" "$rc" 2

# The user's way out: the scan is off, the call goes through and is recorded.
OHMYBUG_SECRET_SCAN=0 row "OHMYBUG_SECRET_SCAN=0 lets a key through" 0 "$(j "{'diff':'+k=\"$AWS\"'}")"
OHMYBUG_SECRET_SCAN=0 hook "$(j "{'diff':'+k=\"$AWS\"'}")" >/dev/null; check "with the scan off a submit is still recorded" "$(stamped)" yes

# provide_files with PATHS: the hook reads the files from disk and hands the
# call on with their contents (updatedInput), by the selection rules of the
# server's files_url recipe, and scans what it read.
FX=$(mktemp -d); trap 'rm -rf "$STUB" "$FX"' EXIT
mkdir -p "$FX/repo/sub" && echo 'outside' > "$FX/outside.ts"
(
  cd "$FX/repo" && git init -q && printf 'secret.txt\n' > .gitignore
  printf 'export const a = 1\n' > a.ts && printf 'T=%s\n' "$GHP" > ci.sh && printf 'S=1\n' > secret.txt
  git add a.ts ci.sh .gitignore && printf 'export const n = 2\n' > new.ts
  printf '// \377\376\n' > bad.ts && ln -s ../outside.ts out.ts && ln -s a.ts alias.ts
  printf 'export const d = 3\n' > sub/d.ts && git add sub/d.ts && ln -s sub lnk
)
fillrun() { # cwd, paths JSON -> sets rc, out (stdout), err (stderr)
  local e; e=$(mktemp)
  out=$(python3 -c "import json,sys; print(json.dumps({'tool_name':'mcp__plugin_bughunter_ohmybug__provide_files','cwd':sys.argv[1],'tool_input':{'review_id':'r','paths':json.loads(sys.argv[2])}}))" "$1" "$2" \
    | bash "$G/secret-scan.sh" 2>"$e"); rc=$?
  err=$(cat "$e"); rm -f "$e"
}
field() { printf '%s' "$out" | python3 -c "import json,sys; o=json.load(sys.stdin)['hookSpecificOutput']; print(eval(sys.argv[1]))" "$1" 2>/dev/null; }
fillrun "$FX/repo" '["a.ts","new.ts","bad.ts","alias.ts","nope.ts","sub",".git/config","out.ts","../outside.ts","sub/d.ts","lnk/d.ts"]'
check "paths: the call goes on" "$rc" 0
check "paths: tracked and untracked files are filled from disk, in order" \
  "$(field "ascii([(f['path'], f['content']) for f in o['updatedInput']['files']])")" \
  "[('a.ts', 'export const a = 1\\n'), ('new.ts', 'export const n = 2\\n'), ('bad.ts', '// \\ufffd\\ufffd\\n'), ('sub/d.ts', 'export const d = 3\\n')]"
check "paths: the paths key is gone, the review id stays" "$(field "sorted(o['updatedInput'])")" "['files', 'review_id']"
check "paths: no permission decision, ever" "$(field "sorted(o)")" "['additionalContext', 'hookEventName', 'updatedInput']"
check "paths: skipped ones are named to the agent" "$(field "o['additionalContext'].split('Not sent')[1]")" \
  " (missing, unreadable, not a regular file, a symlink, under .git or outside the repository): alias.ts, nope.ts, sub, .git/config, out.ts, ../outside.ts, lnk/d.ts."
# Where python has no dir_fd (Windows): os.open refuses dir_fd as it does there, so
# a run that took the dir_fd branch fails; links are refused by the realpath check.
mkdir -p "$FX/nodirfd" && cat > "$FX/nodirfd/sitecustomize.py" <<'PY'
import os
_open = os.open
def _no_dir_fd(path, flags, mode=0o777, *, dir_fd=None):
    if dir_fd is not None:
        raise NotImplementedError("dir_fd unavailable on this platform")
    return _open(path, flags, mode)
os.open = _no_dir_fd
os.supports_dir_fd = set()
PY
PYTHONPATH="$FX/nodirfd" fillrun "$FX/repo" '["a.ts","alias.ts","out.ts","sub/d.ts","lnk/d.ts"]'
check "paths: without dir_fd links are still refused" \
  "$rc:$(field "[f['path'] for f in o['updatedInput']['files']]")" "0:['a.ts', 'sub/d.ts']"
# The bytes come from the fd that was checked: a directory swapped for a link to
# outside right before the file is opened changes nothing. Reopening by name, or
# the check-then-open branch, would send the file outside.
mkdir -p "$FX/swap/sub" "$FX/away" && printf 'away\n' > "$FX/away/d.ts"
( cd "$FX/swap" && git init -q && printf 'here\n' > sub/d.ts && git add sub/d.ts )
mkdir -p "$FX/swapper" && cat > "$FX/swapper/sitecustomize.py" <<'PY'
import os
_open, _done = os.open, []
def _swap(path, flags, mode=0o777, *, dir_fd=None):
    if not _done and os.fsencode(path).endswith(b"d.ts"):
        _done.append(1)
        top = os.environ["SWAP_TOP"]
        os.rename(os.path.join(top, "sub"), os.path.join(top, "sub.real"))
        os.symlink(os.environ["SWAP_TO"], os.path.join(top, "sub"))
    return _open(path, flags, mode, dir_fd=dir_fd)
os.open = _swap
os.supports_dir_fd.add(_swap)
PY
SWAP_TOP="$FX/swap" SWAP_TO="$FX/away" PYTHONPATH="$FX/swapper" fillrun "$FX/swap" '["sub/d.ts"]'
check "paths: a directory swapped for a link mid-call sends the checked file" \
  "$rc:$(field "[(f['path'], f['content']) for f in o['updatedInput']['files']]")" "0:[('sub/d.ts', 'here\\n')]"
check "paths: ...and the swap really happened under the walk" "$([ -L "$FX/swap/sub" ] && [ -d "$FX/swap/sub.real" ] && echo yes)" yes
# Every fd is closed as the walk goes: a long list under a small fd limit loses nothing.
many=$(python3 -c "import json; print(json.dumps(['sub/d.ts'] * 100 + ['.git/config'] * 50))")
check "paths: 150 paths under a 32-fd limit, every listed one filled" \
  "$(ulimit -n 32; fillrun "$FX/repo" "$many"; field "len(o['updatedInput']['files'])")" 100
# A name is opened as it is sent: an empty, "." or ".." part is refused, not tidied
# into another file (a trailing "/." would read a.ts under a name no rule matches).
fillrun "$FX/repo" '["a.ts/.","a.ts/","sub/../a.ts","./a.ts","sub//d.ts"]'
check "paths: odd parts are refused, a leading ./ is not" \
  "$rc:$(field "[f['path'] for f in o['updatedInput']['files']]")" "0:['./a.ts']"
# A named pipe is opened without blocking and skipped as not a regular file.
mkfifo "$FX/repo/pipe"
fillrun "$FX/repo" '["pipe","a.ts"]'
check "paths: a named pipe is skipped, not waited on" "$rc:$(field "[f['path'] for f in o['updatedInput']['files']]")" "0:['a.ts']"
rm -f "$FX/repo/pipe"
fillrun "$FX/repo/sub" '["a.ts"]'
check "paths: read from the top level, whatever the session directory" "$(field "o['updatedInput']['files'][0]['path']")" "a.ts"
fillrun "$FX/repo" '["a.ts","secret.txt"]'
check "paths: a file git does not list stops the call" "$rc" 2
check "paths: ...nothing goes on" "$out" ""
case "$err" in *"git does not list"*"- secret.txt"*) echo "ok   paths: ...and the file is named";; *) echo "FAIL paths: unlisted message: $err"; fails=$((fails + 1));; esac
fillrun "$FX/repo" '["ci.sh"]'
check "paths: a key in a file read from disk is refused" "$rc" 2
case "$err" in *"ci.sh:1 GitHub token"*) echo "ok   paths: ...naming file and line";; *) echo "FAIL paths: scan message: $err"; fails=$((fails + 1));; esac
OHMYBUG_SECRET_SCAN=0 fillrun "$FX/repo" '["ci.sh"]'
check "paths: with the scan off the paths are still filled" "$rc:$(field "o['updatedInput']['files'][0]['path']")" "0:ci.sh"
PLUGIN_DATA=x fillrun "$FX/repo" '["a.ts"]'
check "paths: under Codex nothing is filled (the server refuses the paths)" "$rc:$out" "0:"
fillrun "$FX" '["outside.ts"]'
check "paths: outside any repository nothing is sent" "$rc:$out" "2:"
case "$err" in *"not inside one"*) echo "ok   paths: ...and the agent is told to send contents";; *) echo "FAIL paths: no-repo message: $err"; fails=$((fails + 1));; esac

# File mode: the two files omb-upload.sh posts, scanned before any POST.
FM="$FX/filemode"; mkdir -p "$FM"
fm() { # name, want exit, mode, file, [text in stderr]
  local err rc
  rm -f "$MARK" "$FM/hits"
  err=$(bash "$G/secret-scan.sh" "--$3" "$4" "$FM/hits" 2>&1 >/dev/null); rc=$?
  if [ "$rc" != "$2" ]; then echo "FAIL $1: exit $rc, want $2 — $err"; fails=$((fails + 1)); return; fi
  if [ -n "${5:-}" ] && ! printf '%s' "$err" | LC_ALL=C grep -qF -- "$5"; then echo "FAIL $1: message lacks '$5' — $err"; fails=$((fails + 1)); return; fi
  if [ -e "$MARK" ]; then echo "FAIL $1: file mode chained to the recorder"; fails=$((fails + 1)); return; fi
  echo "ok   $1"
}
tgz() { # out, then name=content pairs (content may hold \n escapes)
  python3 - "$@" <<'PY2'
import io, sys, tarfile
out, pairs = sys.argv[1], sys.argv[2:]
with tarfile.open(out, "w:gz", format=tarfile.PAX_FORMAT, encoding="utf-8") as t:
    for p in pairs:
        n, c = p.split("=", 1)
        b = c.encode("utf-8")
        i = tarfile.TarInfo(n); i.size = len(b)
        t.addfile(i, io.BytesIO(b))
PY2
}
j "{'diff':'+++ b/app.py\n@@ -1,1 +1,2 @@\n x\n+k = \"$AWS\"\n','files':[]}" > "$FM/hit.json"
j "{'diff':'+++ b/app.py\n+print(1)\n','files':[{'path':'c.py','content':'x = 1'}]}" > "$FM/clean.json"
j "{'diff':'+print(1)\n','files':[{'path':'c.py','content':'T=$GHP'}]}" > "$FM/ctx.json"
printf 'not json' > "$FM/bad.json"
fm "--payload: a key in the diff"              3 payload "$FM/hit.json" "app.py:2 AWS access key"
fm "--payload: a key in a context file"        3 payload "$FM/ctx.json" "c.py:1 GitHub token"
fm "--payload: clean"                          0 payload "$FM/clean.json"
fm "--payload: unreadable refuses"             2 payload "$FM/bad.json"
fm "--payload: a missing file refuses"         2 payload "$FM/none.json"
OHMYBUG_SECRET_SCAN=0 fm "--payload: OHMYBUG_SECRET_SCAN=0 reads nothing" 0 payload "$FM/hit.json"
err=$(bash "$G/secret-scan.sh" --payload "$FM/hit.json" 2>&1)
printf '%s' "$err" | LC_ALL=C grep -qF "$AWS" && { echo "FAIL --payload: the full key reached the message"; fails=$((fails + 1)); } || echo "ok   --payload: the key is masked"
tgz "$FM/hit.tgz" "src/ok.ts=x = 1" "conf/leak.yml=k: $AWS" "docs/a.md=fine"
tgz "$FM/name.tgz" "keys/server.pem=x" "a.ts=x"
tgz "$FM/clean.tgz" "src/ok.ts=x = 1"
fm "--snapshot: a key in a member"             3 snapshot "$FM/hit.tgz" "conf/leak.yml:1 AWS access key"
check "--snapshot: the hit members are written, NUL-separated" "$(tr '\0' '|' < "$FM/hits")" "conf/leak.yml|"
fm "--snapshot: a key-named member"            3 snapshot "$FM/name.tgz" "keys/server.pem is a file that holds keys"
check "--snapshot: ...named for the script to drop" "$(tr '\0' '|' < "$FM/hits")" "keys/server.pem|"
fm "--snapshot: clean"                         0 snapshot "$FM/clean.tgz"
check "--snapshot: clean writes no hit list" "$([ -s "$FM/hits" ] && echo yes || echo no)" no
head -c 40 "$FM/hit.tgz" > "$FM/cut.tgz"
fm "--snapshot: a truncated gzip refuses"      2 snapshot "$FM/cut.tgz"
fm "--snapshot: not a gzip refuses"            2 snapshot "$FM/bad.json"
OHMYBUG_SECRET_SCAN=0 fm "--snapshot: OHMYBUG_SECRET_SCAN=0 reads nothing" 0 snapshot "$FM/hit.tgz"
OHMYBUG_TEST_SCAN_RAISE=1 fm "--snapshot: an error inside the scan refuses" 2 snapshot "$FM/clean.tgz"
NOPY="$FM/nopy"; mkdir -p "$NOPY"; ln -sf "$(command -v dirname)" "$NOPY/dirname"
rc=$(PATH="$NOPY" "$BASH" "$G/secret-scan.sh" --snapshot "$FM/hit.tgz" >/dev/null 2>&1; echo $?)
check "file mode without python3: exit 4" "$rc" 4
for lc in en_US.ISO8859-1 ja_JP.eucJP zh_CN.GBK; do
  tgz "$FM/u.tgz" "$(printf '\346\227\245')/k.md=$(printf '\346\227\245') k=$AWS" "a.ts=x"
  LC_ALL=$lc LANG=$lc PYTHONUTF8=0 PYTHONIOENCODING= fm "--snapshot: a key in a non-ASCII member under $lc" 3 snapshot "$FM/u.tgz" "/k.md:1 AWS access key"
  check "--snapshot: the member's bytes survive under $lc" "$(od -An -tx1 < "$FM/hits" | tr -d ' \n')" "e697a52f6b2e6d6400"
done

[ "$fails" = 0 ] && echo "secret-scan: all rows pass" || { echo "secret-scan: $fails failing"; exit 1; }
