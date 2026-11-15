#!/bin/bash
# Run me after touching omb-upload.sh: `hooks/omb-upload-test.sh`
#
# The upload script runs here for real: real git, a real snapshot, the real
# secret scan. Only curl is a stub on PATH: it stores each body it is sent
# and answers from a per-door plan, so every row can say what
# left the machine, in which order, and what the script did with each answer.
# Keys are glued together at run time, as in secret-scan-test.sh.
set -u
G=$(cd "$(dirname "$0")" && pwd)
UP="$G/omb-upload.sh"
# The shell that runs the script: sh by default (dash on Debian and Ubuntu),
# OMB_TEST_SH=bash for the second CI leg.
TSH=${OMB_TEST_SH:-sh}
export PYTHONDONTWRITEBYTECODE=1
ROOT=$(mktemp -d)
trap 'chmod -R u+rwx "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT
fails=0
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
ok() { echo "ok   $*"; }
URL=https://mcp.ohmybug.ai/u/tok_1-A
AWS="AKIA""QWERTYUIOPASDFGH"

# The stub. Doors: repo (POST <url>/repo), payload (POST <url>), delete
# (DELETE <url>). Plan lines per door: "<code>|<body>|<retry-after>"; past the
# plan, 200. Codes: 000 = no answer (curl 7), NNN! = status then a broken
# transfer (curl 55), cut = a 200 whose body was cut (curl 18).
BIN="$ROOT/bin"; mkdir -p "$BIN"
cat > "$BIN/curl" <<'SH'
#!/bin/sh
echo "$*" >> "$STUB/args"
# curl reads ~/.curlrc unless -q is its FIRST argument: any call without it fails the row.
if [ "${1:-}" != -q ]; then echo "CURL noq $*" >> "$STUB/transcript"; printf 000; exit 2; fi
f= m=POST
while [ $# -gt 0 ]; do
  case $1 in -o) o=$2; shift ;; -D) h=$2; shift ;; -X) m=$2; shift ;; -H|-w|--connect-timeout) shift ;; --data-binary) f=${2#@}; shift ;; -*) ;; *) u=$1 ;; esac
  shift
done
case $m:$u in DELETE:*) door=delete ;; POST:*/repo|POST:*/repo[?]*) door=repo ;; POST:*) door=payload ;; *) door=other ;; esac
n=$(cat "$STUB/$door.n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STUB/$door.n"
line=$(sed -n "${n}p" "$STUB/$door.plan" 2>/dev/null)
[ -n "$line" ] || line='200|{"ok":true}|'
code=${line%%|*}; rest=${line#*|}; body=${rest%|*}; ra=${rest##*|}
echo "CURL $door $u" >> "$STUB/transcript"
if [ -n "$f" ]; then
python3 -I - "$f" >> "$STUB/modes" <<'PY'
import os, stat, sys
f = sys.argv[1]
print(oct(stat.S_IMODE(os.stat(os.path.dirname(f)).st_mode)), oct(stat.S_IMODE(os.stat(f).st_mode)), os.path.dirname(f))
PY
cp "$f" "$STUB/$door.$n.sent"
fi
# A connection that never answered writes no body and no headers, and leaves
# whatever files were there before, as curl does.
if [ "$code" = 000 ]; then printf 000; exit 7; fi
# A transfer cut after its status line: curl prints the status and fails.
case $code in *!) printf '%s' "$body" > "$o"; printf 'HTTP/1.1 %s X\r\n' "${code%!}" > "$h"; printf '%s' "${code%!}"; exit 55 ;; esac
if [ "$code" = cut ]; then printf '%s' "$body" > "$o"; printf 'HTTP/1.1 200 X\r\n' > "$h"; printf 200; exit 18; fi
printf '%s' "$body" > "$o"
{ printf 'HTTP/1.1 %s X\r\n' "$code"; [ -n "$ra" ] && printf 'Retry-After: %s\r\n' "$ra"; } > "$h"
printf '%s' "$code"
exit 0
SH
chmod +x "$BIN/curl"

g() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }
fresh() { STUB=$(mktemp -d "$ROOT/stub.XXXXXX"); export STUB; : > "$STUB/transcript"; }
plan() { printf '%s\n' "$2" > "$STUB/$1.plan"; }
# run <dir> <args...>: rc in $rc, stdout+stderr in $out (stdout also in the transcript)
run() {
  local dir=$1; shift
  out=$(cd "$dir" && PATH="$BIN:$PATH" "$TSH" "$UP" "$@" 2>"$STUB/err" | tee -a "$STUB/transcript"; exit "${PIPESTATUS[0]}")
  rc=$?
  out="$out$(cat "$STUB/err")"
}
calls() { grep -c '^CURL' "$STUB/transcript" 2>/dev/null || :; }
seq_() { grep '^CURL' "$STUB/transcript" | cut -d' ' -f2 | tr '\n' ' '; }
sha() { python3 -I -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"; }
names() { tar -tzf "$STUB/repo.1.sent" 2>/dev/null | grep -v '/$' | sort; }
want_rc() { [ "$rc" = "$2" ] && ok "$1" || fail "$1: exit $rc, want $2: $out"; }

export HOME="$ROOT/home"; mkdir -p "$HOME"; HOME=$(cd "$HOME" && pwd -P)
SMUDGED="$ROOT/smudged"
export GIT_CONFIG_GLOBAL="$ROOT/gitconfig"
# No system config either: a CI image that sets safe.directory = * there would
# turn the ownership row below into a pass for the wrong repository.
export GIT_CONFIG_NOSYSTEM=1
printf '[filter "marker"]\n\tsmudge = touch %s; cat\n\tclean = cat\n' "$SMUDGED" > "$GIT_CONFIG_GLOBAL"

# ---- 1. Secret-list parity --------------------------------------------------
# Written out here, not read from anywhere: dropping a name from the script
# or the server's list must redden this row. This is the server's
# snapshot secret list, name for name.
SERVER='.env* *secret* *credential* id_rsa* id_dsa* id_ecdsa* id_ed25519* *.pem *.key *.p12 *.pfx .npmrc .netrc .pgpass .pypirc .git-credentials *.tfstate* *.tfvars* kubeconfig .kube .docker *.ppk *.jks *.keystore .ssh .aws .gnupg'
script=$(python3 - "$UP" <<'PY'
import re, sys
m = re.search(r"^OMB_SECRETS='(.*?)'", open(sys.argv[1]).read(), re.S | re.M)
print(" ".join(m.group(1).split()) if m else "")
PY
)
[ "$script" = "$SERVER" ] && ok "the script's secret list is the server's" || fail "secret list: script has [$script]"

# ---- 2. Pack: what goes into the snapshot and what stays out -------------
fixture() { # $1 dir, $2 commit (1/0)
  local r=$1
  mkdir -p "$r" && g -C "$r" init -q
  mkdir -p "$r/src/deep" "$r/ci" "$r/config/credentials"
  printf 'export const a = 1\n' > "$r/src/deep/a.ts"
  printf 'CIPHERTEXT\n' > "$r/cipher.txt"
  printf 'cipher.txt filter=marker\nci/ export-ignore\n' > "$r/.gitattributes"
  printf 'echo ci\n' > "$r/ci/run.sh"
  printf 'build/\n' > "$r/.gitignore"
  printf 'TOKEN=x\n' > "$r/.env.production"
  printf 'k: v\n' > "$r/Secrets.YML"
  printf 'k: v\n' > "$r/config/credentials/prod.yml"
  printf 'a\n' > "$r/a.txt"
  g -C "$r" add -A
  [ "$2" = 1 ] && g -C "$r" commit -qm one
  mkdir -p "$r/build"; printf 'ignored\n' > "$r/build/out.js"
  printf 'untracked\n' > "$r/src/new.ts"
  printf 'untracked key\n' > "$r/ID_RSA"
  local p n
  set -f
  for p in $SERVER; do
    n=${p//\*/x}
    mkdir -p "$r/sec1" "$r/sec2/$n"
    printf 'secret\n' > "$r/sec1/$n"
    printf 'secret\n' > "$r/sec2/$n/inner.txt"
  done
  set +f
  # The smudge filter runs on checkout of cipher.txt; the fixture's own commit
  # must not count against the packer.
  rm -f "$SMUDGED"
}
objects() { (cd "$1/.git/objects" && find . -type f | sort); }
# The scope: the working copy against HEAD (fixtures hold uncommitted work).
P=--head

R="$ROOT/fx"; fixture "$R" 1
idx=$(shasum -a 256 < "$R/.git/index"); obj=$(objects "$R")
fresh; run "$R/src/deep" "$URL" required "$P"
want_rc "a snapshot from a subdirectory is sent" 0
n=$(names)
for f in src/deep/a.ts src/new.ts cipher.txt .gitignore ci/run.sh a.txt; do
  printf '%s\n' "$n" | grep -qx "$f" || fail "pack: $f is missing from the snapshot (export-ignore or subdirectory)"
done
printf '%s\n' "$n" | grep -q '^build/' && fail "pack: an ignored file was packed"
printf '%s\n' "$n" | grep -iqE 'env|credential|secret|id_rsa' && fail "pack: a secret-named file was packed: $(printf '%s\n' "$n" | grep -iE 'env|credential|secret|id_rsa' | tr '\n' ' ')"
printf '%s\n' "$n" | grep -qE '^sec[12]/.' && fail "pack: a file under an excluded name was packed: $(printf '%s\n' "$n" | grep -E '^sec[12]/.' | tr '\n' ' ')"
[ "$(tar -xzOf "$STUB/repo.1.sent" cipher.txt 2>/dev/null)" = CIPHERTEXT ] || fail "pack: cipher.txt was converted"
[ -e "$SMUDGED" ] && fail "pack: a smudge filter ran while packing"
[ "$(shasum -a 256 < "$R/.git/index")" = "$idx" ] || fail "pack: the user's index was written"
[ "$(objects "$R")" = "$obj" ] || fail "pack: the user's object store was written"
ok "pack: working copy, no ignored or secret-named files at any depth or case, no conversion, index and objects untouched"

R="$ROOT/sha256"; mkdir -p "$R"; g -C "$R" init -q --object-format=sha256
printf 'a\n' > "$R/a.txt"; g -C "$R" add -A; g -C "$R" commit -qm one; printf 'CIPHERTEXT\n' > "$R/cipher.txt"
fresh; run "$R" "$URL" required "$P"
printf '%s\n' "$(names)" | grep -qx cipher.txt && [ "$rc" = 0 ] && ok "pack: a SHA-256 repository" || fail "pack: a SHA-256 repository: $rc $out"

R="$ROOT/nocommit"; fixture "$R" 0
fresh; run "$R" "$URL" required --all
n=$(names); printf '%s\n' "$n" | grep -qx src/deep/a.ts && printf '%s\n' "$n" | grep -qx src/new.ts && ok "pack: a repository with no commit yet" || fail "pack: no commit yet: $rc $out"

SRC="$ROOT/sparse-src"; fixture "$SRC" 1
mkdir -p "$SRC/far"; printf 'export const b = 2\n' > "$SRC/far/b.ts"; g -C "$SRC" add -A; g -C "$SRC" commit -qm two
g -C "$SRC" config uploadpack.allowFilter true
C="$ROOT/sparse"; g clone -q --filter=blob:none --sparse "file://$SRC" "$C" 2>/dev/null
g -C "$C" sparse-checkout set src
g -C "$C" remote set-url origin "file://$ROOT/no-such-remote"
mkdir -p "$C/scratch"; printf 'untracked\n' > "$C/scratch/notes.txt"
fresh; run "$C" "$URL" required "$P"
n=$(names)
if [ "$rc" = 0 ] && printf '%s\n' "$n" | grep -qx src/deep/a.ts && printf '%s\n' "$n" | grep -qx scratch/notes.txt && ! printf '%s\n' "$n" | grep -q '^far/'; then
  ok "pack: a sparse partial clone, nothing fetched, the cone only"
else fail "pack: sparse partial clone: $rc $out / $n"; fi
# The diff of the same sparse clone: the untracked file outside the cone is in
# it, and the skip-worktree files absent from the work tree are not deletions.
python3 -I - "$STUB/payload.1.sent" <<'PY' && ok "sparse: the diff has the file outside the cone; absent skip-worktree files are no deletions" || fail "sparse diff: $(cat "$STUB/payload.1.sent")"
import json, sys
d = json.load(open(sys.argv[1]))["diff"]
sys.exit(0 if "b/scratch/notes.txt" in d and "deleted file" not in d and "far/" not in d else 1)
PY

R="$ROOT/nogit"; mkdir -p "$R"
printf 'print(1)\n' > "$R/main.py"; printf 'CIPHERTEXT\n' > "$R/cipher.txt"; printf 'k\n' > "$R/server.KEY"; printf 'x\n' > "$R/.npmrc"
for x in __pycache__ venv target dist build node_modules/dep src/build .aws .config .cache/sub; do mkdir -p "$R/$x"; printf 'x\n' > "$R/$x/f"; done
NT="$ROOT/nogit-tmp"; mkdir -p "$NT"
fresh; out=$(cd "$R" && TMPDIR="$NT" PATH="$BIN:$PATH" "$TSH" "$UP" "$URL" required --all 2>&1); rc=$?
n=$(names | tr '\n' ' ')
[ "$n" = "cipher.txt main.py src/build/f " ] && [ "$rc" = 0 ] && ok "pack: a folder without git, with its extra exclusions" || fail "pack: no git: got [$n] rc $rc $out"
[ -z "$(ls -A "$NT")" ] && ok "pack: the no-git form leaves no git directory behind" || fail "pack: left behind in TMPDIR: $(ls -A "$NT")"
[ -e "$R/.git" ] && fail "pack: the no-git form created a .git in the folder"
printf '%s' "$out" | grep -q 'folder without git' && ok "manifest: the no-git variant" || fail "manifest: no no-git note: $out"

# Refusals: nothing reaches the door.
refused() { # name, dir, HOME, want text, [env]
  fresh; out=$(cd "$2" && env HOME="$3" ${5:-} PATH="$BIN:$PATH" "$TSH" "$UP" "$URL" required --all 2>&1); rc=$?
  if [ "$rc" != 0 ] && [ "$(calls)" = 0 ] && printf '%s' "$out" | grep -q "$4"; then ok "$1"; else fail "$1: rc $rc, calls $(calls): $out"; fi
}
H2="$ROOT/home2"; mkdir -p "$H2/u"; printf 'x\n' > "$H2/a.py"
refused "no git: a folder above the home folder is refused" "$H2" "$H2/u" "refusing to read"
refused "no git: the home folder is refused" "$H2" "$H2" "refusing to read"
R="$ROOT/fx2"; fixture "$R" 1
refused "an empty HOME is refused, naming that cause" "$R" "" "HOME is not set"
refused "a HOME that cannot be entered is refused" "$R" "$R/no-such-home" "HOME is not set"
H3="$ROOT/dot"; mkdir -p "$H3/proj"; g -C "$H3" init -q; printf 'x\n' > "$H3/proj/a.ts"
refused "a dotfiles repository holding the home folder is refused" "$H3/proj" "$H3" "refusing to read"
H4="$ROOT/ctr"; mkdir -p "$H4"; printf 'print(1)\n' > "$H4/main.py"
refused "a project that is the home folder names the opt-in" "$H4" "$H4" "OMB_SNAPSHOT_HOME_OK=1"
fresh; out=$(cd "$H4" && HOME="$H4" OMB_SNAPSHOT_HOME_OK=1 PATH="$BIN:$PATH" "$TSH" "$UP" "$URL" required --all 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(calls)" = 2 ] && ok "OMB_SNAPSHOT_HOME_OK=1 lets the home-folder project through" || fail "home opt-in: rc $rc $out"

# ---- 4. Scan before any POST -----------------------------------------------
R="$ROOT/scan"; mkdir -p "$R"; g -C "$R" init -q; printf 'a\n' > "$R/a.txt"; g -C "$R" add -A; g -C "$R" commit -qm one
printf 'b\n' >> "$R/a.txt"
# Files committed here are in the snapshot but not in the --head diff.
commit_in() { g -C "$R" add -f -- "$@" && g -C "$R" commit -qm fixture; }
uncommit() { g -C "$R" rm -rq --cached -- "$@" && g -C "$R" commit -qm unfixture; rm -rf "${@/#/$R/}"; }
printf 'k = "%s"\n' "$AWS" > "$R/key.txt"
fresh; run "$R" "$URL" required "$P"
[ "$rc" = 3 ] && [ "$(calls)" = 0 ] && ok "a key in the diff refuses before any POST" || fail "key in diff: rc $rc calls $(calls) $out"
printf '%s' "$out" | grep -qF "$AWS" && fail "the full key reached the output"
printf '%s' "$out" | grep -q 'AWS access key' && ok "the refusal names the shape, masked" || fail "key in diff: no masked hit: $out"
mv "$R/key.txt" "$ROOT/key.txt"
printf 'k = "%s"\n' "$AWS" > "$R/ctx.txt"; commit_in ctx.txt
fresh; run "$R" "$URL" off "$P" ctx.txt
[ "$rc" = 3 ] && [ "$(calls)" = 0 ] && ok "a key in a context file refuses before any POST" || fail "key in context: rc $rc calls $(calls) $out"
uncommit ctx.txt
mkdir -p "$R/conf"; printf 'k = "%s"\n' "$AWS" > "$R/conf/leak.yml"; printf 'fine\n' > "$R/conf/ok.yml"; commit_in conf
fresh; run "$R" "$URL" required "$P"
n=$(names | tr '\n' ' ')
if [ "$rc" = 0 ] && [ "$(calls)" = 2 ] && [ "$n" = "a.txt conf/ok.yml " ]; then ok "a key in a snapshot file leaves that file out, and the hunt goes on"
else fail "key in snapshot: rc $rc [$n] $out"; fi
printf '%s' "$out" | grep -q 'credential match: conf/leak.yml' && ok "manifest: the left-out file is named" || fail "manifest: leak.yml not named: $out"
python3 -I "$G/omb_scan.py" --snapshot "$STUB/repo.1.sent" "$ROOT/hits" >/dev/null 2>&1 && ok "the snapshot sent is the one scanned clean" || fail "the snapshot sent does not scan clean"
# Two dropped files are two names; a control byte inside a name becomes "?", and the manifest stays one line.
cp "$R/conf/leak.yml" "$R/conf/$(printf 'two,x\033.yml')"; commit_in conf
fresh; run "$R" "$URL" required "$P"
first=$(grep '^OhMyBug upload' "$STUB/transcript")
case $first in *'credential match: conf/leak.yml, conf/two,x?.yml.') [ "$(names | tr '\n' ' ')" = "a.txt conf/ok.yml " ] && ok "manifest: two left-out files are two names, a comma in a name kept, control bytes replaced" || fail "two drops: packed [$(names | tr '\n' ' ')]" ;; *) fail "two drops glued or split: $first" ;; esac
uncommit "conf/$(printf 'two,x\033.yml')"
cp "$ROOT/key.txt" "$R/key.txt"
fresh; out=$(cd "$R" && OHMYBUG_SECRET_SCAN=0 PATH="$BIN:$PATH" "$TSH" "$UP" "$URL" required "$P" 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(calls)" = 2 ] && printf '%s' "$out" | grep -q 'Credential scan: off (OHMYBUG_SECRET_SCAN=0)' && ok "OHMYBUG_SECRET_SCAN=0: sent, and the manifest says scan off" || fail "scan off: rc $rc $out"
tar -tzf "$STUB/repo.1.sent" | grep -qx conf/leak.yml && ok "scan off: nothing is dropped either" || fail "scan off: leak.yml dropped"
rm -f "$R/key.txt"; uncommit conf
# No python3: a PATH holding every tool the script needs but python3.
NP="$ROOT/nopy"; mkdir -p "$NP"
for t in git sh bash mktemp dirname rm mkdir cp xargs grep tr paste awk wc tar cat sed env; do ln -sf "$(command -v "$t")" "$NP/$t"; done
cp "$BIN/curl" "$NP/"
fresh; out=$(cd "$R" && PATH="$NP" "$TSH" "$UP" "$URL" required "$P" 2>&1); rc=$?
[ "$rc" = 4 ] && [ "$(calls)" = 0 ] && printf '%s' "$out" | grep -q 'python3 not found' && ok "no python3: exit 4, nothing sent" || fail "no python3: rc $rc calls $(calls) $out"
NC="$ROOT/nocurl"; mkdir -p "$NC"
for t in git sh bash mktemp dirname rm mkdir cp xargs grep tr paste awk wc tar cat sed env python3; do ln -sf "$(command -v "$t")" "$NC/$t"; done
fresh; out=$(cd "$R" && PATH="$NC" "$TSH" "$UP" "$URL" required "$P" 2>&1); rc=$?
[ "$rc" = 4 ] && printf '%s' "$out" | grep -q 'curl not found' && ok "no curl: exit 4, said once" || fail "no curl: rc $rc $out"
# A scan that fails refuses (the payload's scan runs first and raises here;
# a failing snapshot scan is the stand-in detector rows below).
fresh; out=$(cd "$R" && OHMYBUG_TEST_SCAN_RAISE=1 PATH="$BIN:$PATH" "$TSH" "$UP" "$URL" required "$P" 2>&1); rc=$?
[ "$rc" = 1 ] && [ "$(calls)" = 0 ] && ok "a scan that fails refuses, nothing sent" || fail "scan failure: rc $rc calls $(calls) $out"

# The snapshot scan's own outcomes, through a stand-in detector beside a copy
# of the script: one that cannot read the snapshot, one that reports a hit
# without naming a member, and one whose hit survives the second pack (a
# rescan that still hits). None may send anything.
FS="$ROOT/fakescan"; mkdir -p "$FS"; cp "$UP" "$FS/omb-upload.sh"
printf 'z\n' > "$R/z.txt"; commit_in z.txt
for v in 2 3 still; do
  # Imported (the payload builder reads context files with it), it is the real
  # detector; run, it is the stand-in.
  cat > "$FS/omb_scan.py" <<PY
import sys
if __name__ != "__main__":
    exec(open("$G/omb_scan.py").read())
elif sys.argv[1] == "--payload":
    sys.exit(0)
elif "$v" == "still":
    open(sys.argv[3], "wb").write(b"a.txt\0")
    sys.exit(3)
else:
    sys.exit(int("$v"))
PY
  fresh; out=$(cd "$R" && PATH="$BIN:$PATH" "$TSH" "$FS/omb-upload.sh" "$URL" required "$P" 2>&1); rc=$?
  [ "$rc" = 1 ] && [ "$(calls)" = 0 ] && printf '%s' "$out" | grep -q 'could not scan the repository snapshot' && ok "a snapshot scan that ends '$v' sends nothing" || fail "snapshot scan $v: rc $rc calls $(calls) $out"
done
uncommit z.txt
# No detector beside the script: nothing sent, and the sentence names the way on.
rm -f "$FS/omb_scan.py"
fresh; out=$(cd "$R" && PATH="$BIN:$PATH" "$TSH" "$FS/omb-upload.sh" "$URL" required "$P" 2>&1); rc=$?
[ "$rc" = 1 ] && [ "$(calls)" = 0 ] && printf '%s' "$out" | grep -q 'detector (omb_scan.py) is not installed' && printf '%s' "$out" | grep -q 'rung 1), or install the full plugin' && ok "no detector beside the script: refused, naming rung 1 or the full plugin, nothing sent" || fail "no detector: rc $rc calls $(calls) $out"
# A repository git refuses to read is not packed as a folder without git.
fresh; out=$(cd "$R" && GIT_TEST_ASSUME_DIFFERENT_OWNER=1 PATH="$BIN:$PATH" "$TSH" "$UP" "$URL" required "$P" 2>&1); rc=$?
[ "$rc" = 1 ] && [ "$(calls)" = 0 ] && ok "a repository git cannot read (ownership) is refused, not packed without .gitignore" || fail "dubious ownership: rc $rc calls $(calls) $out"

# A json.py or hashlib.py in the repository is never imported, by the payload
# builder, the digest or the reader of a 409 answer (the script runs with the
# repository as cwd). The planted files are packed too, so the digest is
# taken from a first run with them in place.
for m in json hashlib; do printf 'open("%s", "w").close()\nraise SystemExit(9)\n' "$ROOT/imported" > "$R/$m.py"; done; commit_in json.py hashlib.py
fresh; run "$R" "$URL" required "$P"; mine=$(sha "$STUB/repo.1.sent")
fresh; plan repo "409|{\"code\":\"snapshot_taken\",\"sha256\":\"$mine\"}|"; run "$R" "$URL" required "$P"
[ "$rc" = 0 ] && [ "$(seq_)" = "repo payload " ] && [ ! -e "$ROOT/imported" ] && ok "a json.py or hashlib.py in the repository is not imported (builder, digest, answer reader)" || fail "repo json.py: rc $rc calls $(seq_) imported=$([ -e "$ROOT/imported" ] && echo yes || echo no) $out"
uncommit json.py hashlib.py; rm -f "$ROOT/imported"

# ---- 5. Order, bytes, the private directory --------------------------------
fresh; run "$R" "$URL" required "$P"
[ "$(grep '^CURL' "$STUB/transcript" | cut -d' ' -f2 | tr '\n' ' ')" = "repo payload " ] && ok "the snapshot goes first, then the payload" || fail "order: $(cat "$STUB/transcript")"
grep -q "^CURL repo $URL/repo\$" "$STUB/transcript" && grep -q "^CURL payload $URL\$" "$STUB/transcript" && ok "the doors are <upload_url>/repo and <upload_url>" || fail "doors: $(cat "$STUB/transcript")"
head -n 1 "$STUB/transcript" | grep -q '^OhMyBug upload → mcp.ohmybug.ai: diff ' && ok "the manifest is printed before the first POST" || fail "manifest order: $(cat "$STUB/transcript")"
python3 -I - "$STUB/payload.1.sent" "$R" <<'PY' && ok "the payload is {diff, files}: git's diff of the working copy, no context files with a snapshot" || fail "payload bytes"
import json, subprocess, sys
p = json.load(open(sys.argv[1]))
want = subprocess.run(["git", "-C", sys.argv[2], "diff", "--no-ext-diff", "--no-textconv", "HEAD"], capture_output=True, text=True).stdout
sys.exit(0 if sorted(p) == ["diff", "files"] and p["files"] == [] and p["diff"] == want and "+b" in want else 1)
PY
packed=$(tar -tzf "$STUB/repo.1.sent" | grep -vc '/$')
grep -q "snapshot of $packed file" "$STUB/transcript" && grep -q 'diff 1 KB (1 file)' "$STUB/transcript" && grep -q 'and 24 more patterns' "$STUB/transcript" && ok "manifest: the counts" || fail "manifest counts ($packed): $(head -n 1 "$STUB/transcript")"
first=$(sed -n 1p "$STUB/modes")
fresh; run "$R" "$URL" required "$P"
python3 - "$first" "$(sed -n 1p "$STUB/modes")" <<'PY' && ok "a private 0700 directory, files nobody else reads, removed, new per run" || fail "private directory"
import os, sys
rows = [r.split(" ", 2) for r in sys.argv[1:]]
bad = [r for r in rows if r[0] != "0o700" or int(r[1], 8) & 0o077 or os.path.exists(r[2])]
sys.exit(1 if bad or rows[0][2] == rows[1][2] else 0)
PY

# Diff mode: no snapshot, context files listed by git only.
printf 'ctx\n' > "$R/c.txt"; ln -s a.txt "$R/link.txt"; printf 'ign\n' > "$R/ig.log"; printf '*.log\n' > "$R/.git/info/exclude"
fresh; run "$R" "$URL" off "$P" c.txt link.txt ig.log
if [ "$rc" = 0 ] && [ "$(calls)" = 1 ] && grep -q '^CURL payload' "$STUB/transcript"; then ok "diff mode: the payload alone"; else fail "diff mode: rc $rc $out"; fi
python3 - "$STUB/payload.1.sent" <<'PY' && ok "diff mode: a listed context file is sent; a symlink and an ignored file are not" || fail "diff mode context: $(cat "$STUB/payload.1.sent")"
import json, sys
p = json.load(open(sys.argv[1]))
sys.exit(0 if [f["path"] for f in p["files"]] == ["c.txt"] else 1)
PY
printf '%s' "$out" | grep -q 'no repository snapshot (diff mode), context files: c.txt' && printf '%s' "$out" | grep -q 'Not sent.*link.txt, ig.log' && ok "manifest: the diff-mode variant names sent and skipped context" || fail "manifest diff mode: $out"
rm -f "$R/c.txt" "$R/link.txt" "$R/ig.log"
CL="$ROOT/clean"; mkdir -p "$CL"; g -C "$CL" init -q; printf 'a\n' > "$CL/a.txt"; g -C "$CL" add -A; g -C "$CL" commit -qm one
fresh; run "$CL" "$URL" required --head
[ "$rc" = 1 ] && [ "$(calls)" = 0 ] && printf '%s' "$out" | grep -q 'the diff is empty' && ok "an empty diff refuses" || fail "empty diff: rc $rc $out"

# ---- 5b. Bytes, names and failures the payload must survive --------------
# A step of the pack that fails stops everything: an unreadable file fails git add.
# Root reads a mode-000 file, so the row cannot fail git add there: skipped.
if [ "$(id -u)" = 0 ]; then echo "skip a failed git add inside the pack (running as root)"; else
printf 'x\n' > "$R/locked.txt"; chmod 000 "$R/locked.txt"
fresh; run "$R" "$URL" required "$P"
[ "$rc" = 1 ] && [ "$(calls)" = 0 ] && ok "a failed git add inside the pack sends nothing" || fail "pack step failure: rc $rc calls $(calls) $out"
chmod 600 "$R/locked.txt"; rm -f "$R/locked.txt"
fi
# The no-git probe reads git in the C locale: a git that answers in another language still means "no repository".
GB="$ROOT/gitbin"; mkdir -p "$GB"
printf '#!/bin/sh\nif [ "${LC_ALL:-}" != C ] && [ "$1 $2" = "rev-parse --git-dir" ]; then echo "fatal: kein Git-Repository" >&2; exit 128; fi\nexec %s "$@"\n' "$(command -v git)" > "$GB/git"; chmod +x "$GB/git"
NG="$ROOT/nogit2"; mkdir -p "$NG"; printf 'x\n' > "$NG/main.py"
fresh; out=$(cd "$NG" && PATH="$GB:$BIN:$PATH" "$TSH" "$UP" "$URL" required --all 2>&1); rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'folder without git' && ok "the no-git probe is locale-proof" || fail "no-git probe locale: rc $rc $out"
# CRLF and a lone CR in a working-tree file reach the payload as git wrote them.
printf 'a\r\n' > "$R/w.bat"; commit_in w.bat; printf 'a\r\nb\r\nc\rd\n' > "$R/w.bat"
fresh; run "$R" "$URL" required "$P"
python3 -I - "$STUB/payload.1.sent" <<'PY' && ok "CRLF and a lone CR reach the payload unchanged" || fail "CRLF: $out"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))["diff"]
sys.exit(0 if "+b\r\n" in d and "+c\rd\n" in d and " a\r\n" in d else 1)
PY
printf 'a\r\n' > "$R/w.bat"; uncommit w.bat
# Context files: a folder linked from ABOVE the repository is fine, a link inside it is not;
# a file that is not UTF-8 is left out and named; none go with a snapshot.
printf 'ctx\n' > "$R/c.txt"; printf 'caf\351\n' > "$R/latin.txt"; commit_in c.txt latin.txt; ln -s "$ROOT" "$ROOT/viaroot"
fresh; run "$R" "$URL" off "$P" "$ROOT/viaroot/$(basename "$R")/c.txt" latin.txt
python3 - "$STUB/payload.1.sent" <<'PY' && printf '%s' "$out" | grep -q 'Not sent.*latin.txt' && ok "context: a symlinked prefix above the repo is fine; a non-UTF-8 file is left out and named" || fail "context prefix/latin: $out"
import json, sys
sys.exit(0 if [f["path"] for f in json.load(open(sys.argv[1]))["files"]] == ["c.txt"] else 1)
PY
fresh; run "$R" "$URL" required "$P" c.txt
python3 - "$STUB/payload.1.sent" <<'PY' && ok "context files never go with a snapshot" || fail "context with snapshot: $(cat "$STUB/payload.1.sent")"
import json, sys
sys.exit(0 if json.load(open(sys.argv[1]))["files"] == [] else 1)
PY
uncommit c.txt latin.txt; rm -f "$ROOT/viaroot"
# The masked hits of a snapshot file are shown, not discarded.
mkdir -p "$R/conf"; printf 'k = "%s"\n' "$AWS" > "$R/conf/leak.yml"; commit_in conf
fresh; run "$R" "$URL" required "$P"
printf '%s' "$out" | grep -q 'conf/leak.yml:1 AWS access key (AKIA...GH)' && ok "the snapshot's masked hits are shown" || fail "snapshot hits hidden: $out"
uncommit conf

# ---- 5c. Diff names, old python, secret-named context, signals ------------
# A real file whose secret name holds a line break and an escape: named in the
# manifest with both replaced, and the manifest stays one true line.
CTL="$R/$(printf '.env\nX\033Y')"
if { printf 'z\n' > "$CTL"; } 2>/dev/null; then
  fresh; run "$R" "$URL" required "$P"
  first=$(head -n 1 "$STUB/transcript")
  case $first in *'secret-named: .env?X?Y.'*'Credential scan'*) ok "control bytes in a name are replaced; the manifest is one line" ;; *) fail "control bytes: $first" ;; esac
  printf '%s' "$first" | grep -q 'diff 1 KB (1 file)' && ok "...and its numbers are not shifted" || fail "shifted manifest: $first"
  rm -f "$CTL"
else echo "skip a file name with a line break (this file system refuses it)"; fi
# python3 older than 3.7 refuses in one sentence.
OP="$ROOT/oldpy"; mkdir -p "$OP"
printf '#!/bin/sh\ncase "$*" in *"version_info < (3, 7)"*) exit 1 ;; esac\nexec %s "$@"\n' "$(command -v python3)" > "$OP/python3"; chmod +x "$OP/python3"
fresh; out=$(cd "$R" && PATH="$OP:$BIN:$PATH" "$TSH" "$UP" "$URL" required "$P" 2>&1); rc=$?
[ "$rc" = 4 ] && [ "$(calls)" = 0 ] && [ "$out" = "omb-upload: python3 3.7 or newer is needed; nothing was sent" ] && ok "python3 older than 3.7: one sentence, exit 4" || fail "old python: rc $rc $out"
# A secret-named context file is never sent, even when git lists it.
printf 'registry=x\n' > "$R/.npmrc"; printf 'fine\n' > "$R/c.txt"; commit_in .npmrc c.txt
fresh; run "$R" "$URL" off "$P" .npmrc c.txt
python3 - "$STUB/payload.1.sent" <<'PY' && printf '%s' "$out" | grep -q 'Not sent.*\.npmrc' && ok "a secret-named context file is left out and named" || fail "secret context: $out"
import json, sys
sys.exit(0 if [f["path"] for f in json.load(open(sys.argv[1]))["files"]] == ["c.txt"] else 1)
PY
grep -q "^0o700 0o600 " "$STUB/modes" && ok "the payload file is readable by its owner only" || fail "payload mode: $(cat "$STUB/modes")"
uncommit .npmrc c.txt
# The payload scan that cannot run refuses on its own (diff mode: no snapshot scan to fail instead).
fresh; out=$(cd "$R" && OHMYBUG_TEST_SCAN_RAISE=1 PATH="$BIN:$PATH" "$TSH" "$UP" "$URL" off "$P" 2>&1); rc=$?
[ "$rc" = 1 ] && [ "$(calls)" = 0 ] && printf '%s' "$out" | grep -q 'could not scan the payload' && ok "an unscannable payload is not sent (diff mode)" || fail "payload scan failure: rc $rc $out"
# The pattern count is not a glob over the current folder.
printf 'k\n' > "$R/a.key"; printf 'k\n' > "$R/b.key"; commit_in a.key b.key
fresh; run "$R" "$URL" required "$P"
printf '%s' "$out" | grep -q 'and 24 more patterns' && ok "the pattern count ignores files in the folder" || fail "pattern count: $out"
uncommit a.key b.key
# Context files given with a snapshot are named as not sent.
fresh; run "$R" "$URL" required "$P" a.txt
printf '%s' "$out" | grep -q 'context files are not sent with a repository snapshot' && ! printf '%s' "$out" | grep -q 'Not sent (' && ok "context files with a snapshot: said once, as not sent with a snapshot" || fail "context note: $out"
# A signal mid-POST removes the private folder. Under dash where there is one:
# bash runs the EXIT trap on TERM by itself, dash only through the script's trap.
SIGSH=$(command -v dash || echo sh)
mkdir -p "$ROOT/slowbin"
printf '#!/bin/sh\nfor a; do case $a in @*) dirname "${a#@}" > "$STUB/dir" ;; esac; done\n/bin/sleep 3\nprintf 000; exit 7\n' > "$ROOT/slowbin/curl"; chmod +x "$ROOT/slowbin/curl"
fresh; (cd "$R" && PATH="$ROOT/slowbin:$BIN:$PATH" exec "$SIGSH" "$UP" "$URL" off "$P" >/dev/null 2>&1) & pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$STUB/dir" ] && break; /bin/sleep 0.2; done
kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
dir=$(cat "$STUB/dir" 2>/dev/null)
[ -n "$dir" ] && [ ! -e "$dir" ] && ok "TERM mid-POST removes the private folder" || fail "TERM: folder [$dir] left"
fresh; (cd "$R" && PATH="$ROOT/slowbin:$BIN:$PATH" exec "$TSH" "$UP" "$URL" off "$P" >/dev/null 2>&1) & pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$STUB/dir" ] && break; /bin/sleep 0.2; done
kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rc=$?
[ "$rc" = 75 ] && ok "TERM mid-POST exits 75, as a stopped call reads" || fail "TERM: exit $rc, want 75"
# A file name that is not UTF-8 and hits is dropped, where the file system allows such names (not macOS).
if ( cd "$R" && printf 'k = "%s"\n' "$AWS" > "$(printf 'caf\351.txt')" ) 2>/dev/null && [ -e "$R/$(printf 'caf\351.txt')" ]; then
  commit_in "$(printf 'caf\351.txt')"
  fresh; run "$R" "$URL" required "$P"
  [ "$rc" = 0 ] && ! names | grep -q caf && ok "a non-UTF-8 name that hits is dropped" || fail "non-UTF-8 name: rc $rc $out"
  uncommit "$(printf 'caf\351.txt')"
else echo "skip a non-UTF-8 file name (this file system refuses it)"; fi
# The real curl: a server that takes the snapshot, then needs 40 s to answer, is
# not cut as a stall and sent the snapshot again.
# It takes 40 s; OMB_TEST_SKIP_SLOW=1 skips it where that is too long (mutant runs).
if [ -n "${OMB_TEST_SKIP_SLOW:-}" ]; then echo "skip the slow-answer row (OMB_TEST_SKIP_SLOW)"; else
REALCURL=$(command -v curl)
cat > "$ROOT/srv.py" <<'PY'
import http.server, sys, time
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers["content-length"]))
        open(sys.argv[2], "a").write(self.path + "\n")
        if self.path.endswith("/repo"):
            time.sleep(40)
        self.send_response(200); self.end_headers(); self.wfile.write(b'{"ok":true}')
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(s.server_port))
s.serve_forever()
PY
python3 "$ROOT/srv.py" "$ROOT/port" "$ROOT/srvlog" >/dev/null 2>&1 & srv=$!
trap 'kill "$srv" 2>/dev/null; chmod -R u+rwx "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$ROOT/port" ] && break; /bin/sleep 0.3; done
mkdir -p "$ROOT/realbin"
cat > "$ROOT/realbin/curl" <<SH
#!/bin/sh
for a; do shift; case \$a in https://mcp.ohmybug.ai/*) a="http://127.0.0.1:$(cat "$ROOT/port")/\${a#https://mcp.ohmybug.ai/}" ;; esac; set -- "\$@" "\$a"; done
exec "$REALCURL" "\$@"
SH
chmod +x "$ROOT/realbin/curl"
out=$(cd "$R" && PATH="$ROOT/realbin:$PATH" "$TSH" "$UP" "$URL" required "$P" 2>&1); rc=$?
kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null
[ "$rc" = 0 ] && [ "$(grep -c '/repo$' "$ROOT/srvlog")" = 1 ] && ok "a slow answer after the snapshot is waited for, not resent" || fail "slow answer: rc $rc, repo posts $(grep -c '/repo$' "$ROOT/srvlog" 2>/dev/null): $out"
fi

# ---- 6. The contract table, one row per cell --------------------------------
# Door 1 (POST <url>/repo): R1-R10; the retire door (DELETE <url>): D1-D3;
# door 2 (POST <url>): P1-P8. Every row asserts the exact requests made.
st() { # name, want rc, repo plan, payload plan, delete plan, argv[2], want requests, [text], [text absent]
  fresh; plan repo "$3"; plan payload "$4"; plan delete "$5"; run "$R" "$URL" "$6" "$P"
  local seq; seq=$(seq_)
  if [ "$rc" != "$2" ]; then fail "$1: exit $rc, want $2: $out"; return; fi
  if [ "$seq" != "$7" ]; then fail "$1: requests [$seq], want [$7]"; return; fi
  if [ -n "${8:-}" ] && ! printf '%s' "$out" | grep -qF -- "$8"; then fail "$1: output lacks '$8': $out"; return; fi
  if [ -n "${9:-}" ] && printf '%s' "$out" | grep -qF -- "$9"; then fail "$1: output has '$9': $out"; return; fi
  ok "$1"
}
taken() { printf '409|{"code":"snapshot_taken","sha256":"%s","snapshot_bytes":445}|' "$1"; }
fresh; run "$R" "$URL" required "$P"; MINE=$(sha "$STUB/repo.1.sent")
OTHER=$(printf '%064d' 7)
NEXT='{"ok":true,"retired":true,"review_id":"rev_1","next":"submit the review again with upload: true"}'
AGAIN="with awaiting_upload true, run the same command again"
GONE_T="the ticket is used or expired"
st "R1 snapshot 200, payload 200: two requests in order, exit 0" 0 '' '' '' required "repo payload "
st "R2 409 taken with my sha256: no DELETE, the payload goes" 0 "$(taken "$MINE")" '' '' required "repo payload " "already holds this snapshot"
st "R3+D1 409 taken with another sha256: one DELETE, no payload, submit again" 1 "$(taken "$OTHER")" '' "200|$NEXT|" required "repo delete " "Submit again as above"
grep -qxF 'submit the review again with upload: true' "$STUB/transcript" && ok "R3+D1 ...the answer's next is printed on its own line" || fail "R3+D1 next not printed: $out"
grep -q "^CURL delete $URL\$" "$STUB/transcript" && ok "R3+D1 ...the DELETE goes to the bare upload_url" || fail "R3+D1 DELETE url: $(cat "$STUB/transcript")"
st "R3+D1 a 200 with no next prints the body" 1 "$(taken "$OTHER")" '' '200|{"ok":true,"retired":true}|' required "repo delete " '"retired":true'
st "R3+D1 a next with a line break or control byte is printed as one line" 1 "$(taken "$OTHER")" '' '200|{"ok":true,"next":"line one\nline\u001b two"}|' required "repo delete "
grep -qxF 'line one line  two' "$STUB/transcript" && ok "R3+D1 ...the next line is one line, control bytes as spaces" || fail "R3+D1 next control bytes: $(cat "$STUB/transcript")"
st "R3+D2 DELETE 404: used or expired" 1 "$(taken "$OTHER")" '' '404|{}|' required "repo delete " "$GONE_T"
st "R3+D2 DELETE 410 ticket_gone: used or expired" 1 "$(taken "$OTHER")" '' '410|{"code":"ticket_gone"}|' required "repo delete " "$GONE_T"
st "R3+D3 DELETE 500: 75" 75 "$(taken "$OTHER")" '' '500|{}|' required "repo delete " "$AGAIN"
st "R3+D3 DELETE no answer: 75" 75 "$(taken "$OTHER")" '' '000|x|' required "repo delete " "$AGAIN"
st "R3+D3 DELETE 200 cut: 75, not retired" 75 "$(taken "$OTHER")" '' "cut|$NEXT|" required "repo delete " "$AGAIN" "Submit again"
st "R3+D3 DELETE 429 with Retry-After: 75 with the seconds" 75 "$(taken "$OTHER")" '' '429|{}|9' required "repo delete " "in about 9 seconds"
st "R3+D3 DELETE 503 with Retry-After: 75 with the seconds" 75 "$(taken "$OTHER")" '' '503|{}|20' required "repo delete " "in about 20 seconds"
st "R3+D3 DELETE 403: final, the ticket named" 1 "$(taken "$OTHER")" '' '403|{}|' required "repo delete " "retire the ticket was refused (HTTP 403"
st "R4 409 taken without sha256: exit 1, no DELETE, no payload" 1 '409|{"code":"snapshot_taken"}|' '' '' required "repo " "did not say which"
st "R4 ...an empty sha256 is no sha256" 1 '409|{"code":"snapshot_taken","sha256":""}|' '' '' required "repo " "did not say which"
st "R5 404: gone, the payload not sent" 1 '404|{}|' '' '' required "repo " "$GONE_T; the payload was not sent"
st "R5 410: gone" 1 '410|{}|' '' '' required "repo " "get_findings"
st "R6 413: the body printed, same answer again" 1 '413|{"code":"snapshot_too_large","error":"use /me/policy"}|' '' '' required "repo " "/me/policy"
printf '%s' "$out" | grep -qF 'The same command would get the same answer' && ok "R6 ...says a rerun gets the same answer" || fail "R6 rerun sentence: $out"
st "R6 413 then a broken upload (curl 55): the status is kept" 1 '413!|{"code":"snapshot_too_large"}|' '' '' required "repo " "refused (HTTP 413"
st "R7 408 (the server stopped receiving at 300 s): final, with the remedies" 1 '408!||' '' '' required "repo " "the snapshot did not reach the server in 5 minutes"
printf '%s' "$out" | grep -qF 'Tell the user: diff mode at https://mcp.ohmybug.ai/me/policy, or push and hunt the pushed commit.' && ok "R7 ...names the two remedies, no partial upload" || fail "R7 remedies: $out"
for c in snapshot_busy snapshot_intake_full rate_limited; do
  st "R8 429 $c with Retry-After: 75 with the seconds, one request" 75 "429|{\"code\":\"$c\"}|7" '' '' required "repo " "run the same command again in about 7 seconds"
done
st "R8 503 with Retry-After: 75 with the seconds" 75 '503|{}|30' '' '' required "repo " "in about 30 seconds"
st "R8 429 without Retry-After: 75, no seconds" 75 '429|{}|' '' '' required "repo " "$AGAIN;" "in about"
st "R8 a Retry-After too long is not read" 75 '429|{}|99999999999999999999' '' '' required "repo " "$AGAIN;" "in about"
st "R9 400: refused" 1 '400|{"code":"not_gzip"}|' '' '' required "repo " "refused (HTTP 400"
st "R9 403: refused" 1 '403|{}|' '' '' required "repo " "refused (HTTP 403"
st "R9 409 of another kind: refused" 1 '409|{"code":"other"}|' '' '' required "repo " "refused (HTTP 409"
st "R9 a redirect is not followed" 1 '302|{}|' '' '' required "repo " "refused (HTTP 302"
for c in 500 502; do
  st "R10 $c: 75, no seconds, no payload" 75 "$c|{}|9" '' '' required "repo " "$AGAIN;" "in about"
done
st "R10 no answer (curl 7): 75" 75 '000|x|' '' '' required "repo " "$AGAIN;"
st "R10 a 1xx as the last status: no answer, 75" 75 '100|x|' '' '' required "repo " "$AGAIN;"
st "R10 a 200 cut mid-body (curl 18): no answer, 75" 75 'cut|{"ok":true}|' '' '' required "repo " "$AGAIN;"
st "R11 400 snapshot_mark_unknown on the marked snapshot: final, the ticket kept, rerun with required" 1 '400|{"code":"snapshot_mark_unknown"}|' '' '' partial "repo " "Run the same command again with required in place of partial, and update the plugin."
grep -q "^CURL repo $URL/repo?pack=partial\$" "$STUB/transcript" && ok "R11 ...the marked request went to /repo?pack=partial" || fail "R11 url: $(cat "$STUB/transcript")"
st "R12 410 snapshot_partial: a deep ticket, retired, submit the deep hunt again" 1 '410|{"code":"snapshot_partial"}|' '' '' partial "repo " "this was a deep-hunt ticket and it is retired"
st "R13 410 without a code on the marked snapshot: used or expired, as before" 1 '410|{}|' '' '' partial "repo " "$GONE_T; the payload was not sent" "deep-hunt"
st "U1 payload 410 snapshot_partial_unsupported: not started, nothing billed, submit again" 1 '' '410|{"code":"snapshot_partial_unsupported"}|' '' partial "repo payload " "the hunt was not started and nothing was billed"
st "P1 200: exit 0, the body printed" 0 '' '200|{"ok":true,"status":"running"}|' '' required "repo payload " '"status":"running"'
st "P1 200 duplicate: exit 0" 0 '' '200|{"ok":true,"status":"running","duplicate":true}|' '' required "repo payload " '"duplicate":true'
st "P2 409 snapshot_required in diff mode: get_findings, then the value it gives" 1 '' '409|{"code":"snapshot_required"}|' '' off "payload " "run the command again with the snapshot value it gives"
st "P3 404: gone" 1 '' '404|{}|' '' required "repo payload " "$GONE_T. Call get_findings"
st "P3 410: gone" 1 '' '410|{}|' '' required "repo payload " "$GONE_T. Call get_findings"
st "P3 410 snapshot_partial_unsupported: gone, the body printed" 1 '' '410|{"code":"snapshot_partial_unsupported"}|' '' required "repo payload " "snapshot_partial_unsupported"
st "P4 413: refused, same answer again" 1 '' '413|{"code":"too_large"}|' '' required "repo payload " "The same command would get the same answer"
st "P5 429 with Retry-After: 75 with the seconds" 75 '' '429|{"code":"rate_limited"}|5' '' required "repo payload " "in about 5 seconds"
st "P5 503 with Retry-After 120: 75 with the seconds" 75 '' '503|{}|120' '' required "repo payload " "in about 120 seconds"
st "P6 408 (the server stopped receiving at 300 s): final" 1 '' '408||' '' required "repo payload " "the payload did not reach the server in 5 minutes"
st "P6 408 in diff mode: no diff-mode advice" 1 '' '408||' '' off "payload " "Tell the user: push and hunt the pushed commit." "diff mode at"
st "P7 500: 75, no seconds" 75 '' '500|{}|9' '' required "repo payload " "$AGAIN;" "in about"
st "P7 no answer: 75" 75 '' '000|x|' '' required "repo payload " "$AGAIN;"
st "P7 a 200 cut mid-body: 75" 75 '' 'cut|{"ok":true}|' '' required "repo payload " "$AGAIN;"
st "P8 400 snapshot_mark_unknown: refused" 1 '' '400|{"code":"snapshot_mark_unknown"}|' '' required "repo payload " "the payload was refused (HTTP 400"
st "P8 409 snapshot_required after a snapshot was sent: refused" 1 '' '409|{"code":"snapshot_required"}|' '' required "repo payload " "the payload was refused (HTTP 409"
st "P8 409 of another kind in diff mode: refused" 1 '' '409|{"code":"other"}|' '' off "payload " "the payload was refused (HTTP 409"
# dispatch: off sends no /repo and required no payload mark (covered above:
# "the payload carries the diff" compares the whole payload); here, the URLs.
st "dispatch: off sends no /repo" 0 '' '' '' off "payload "

# The digest: real git, real packs. Same tree, twice, 2 s apart: equal; one edit: different.
fresh; run "$R" "$URL" required "$P"; d1=$(sha "$STUB/repo.1.sent")
/bin/sleep 2
fresh; run "$R" "$URL" required "$P"; d2=$(sha "$STUB/repo.1.sent")
[ "$d1" = "$d2" ] && [ "$d1" = "$MINE" ] && ok "digest: the same working copy packs to the same bytes, 2 s apart" || fail "digest: unstable pack $d1 / $d2 / $MINE"
printf 'edit\n' >> "$R/a.txt"
fresh; run "$R" "$URL" required "$P"; d3=$(sha "$STUB/repo.1.sent")
[ "$d3" != "$d1" ] && ok "digest: an edit packs to other bytes" || fail "digest: an edit kept the digest"
printf 'a\nb\n' > "$R/a.txt"
# After an edit, the old ticket's digest is a mismatch: the rerun retires, never pairs.
printf 'edit\n' >> "$R/a.txt"
st "digest: ...the same stored digest after an edit is R3" 1 "$(taken "$MINE")" '' "200|$NEXT|" required "repo delete " "Submit again"
printf 'a\nb\n' > "$R/a.txt"

# No clock and no retry in the script, and one curl shape.
python3 -I - "$UP" <<'PY' && ok "no clock: no date, sleep, --max-time or retry in the script" || fail "no clock: the script reads a clock or retries"
import re, sys
code = "\n".join(l for l in open(sys.argv[1]).read().splitlines() if not l.lstrip().startswith("#"))
# One request per door: three call sites (snapshot, retire, payload), two curl lines in req().
sys.exit(1 if re.search(r"\$\(date\b|\bdate \+|\bsleep\b|--max-time|--retry", code)
         or len(re.findall(r"^\s*req (POST|DELETE) ", code, re.M)) != 3 or code.count("curl -q -sS") != 2 else 0)
PY
fresh; plan delete "200|$NEXT|"; plan repo "$(taken "$OTHER")"; run "$R" "$URL" required "$P"
grep -q -- '-X POST -H content-type: application/gzip --data-binary @.* https://mcp.ohmybug.ai/u/tok_1-A/repo$' "$STUB/args" \
  && grep -q -- '-X DELETE https://mcp.ohmybug.ai/u/tok_1-A$' "$STUB/args" && ! grep -- '-X DELETE' "$STUB/args" | grep -q content-type \
  && ok "content-type: the snapshot is application/gzip; the DELETE carries no body" || fail "content-type: $(cat "$STUB/args")"
fresh; run "$R" "$URL" required "$P"
grep -q -- '-X POST -H content-type: application/json --data-binary @.* https://mcp.ohmybug.ai/u/tok_1-A$' "$STUB/args" && ok "content-type: the payload is application/json" || fail "content-type payload: $(cat "$STUB/args")"
grep -v -- '^-q -sS --connect-timeout 10 --speed-limit 1 --speed-time 120 ' "$STUB/args" | grep -q . && fail "curl: a request without the connect and stall limits: $(cat "$STUB/args")" || ok "curl: every request has the 10 s connect limit and ends after 120 s with no byte moving"

# ---- 6b. --base: the script writes the diff; the branch name has a ref's shape
# The branch has a commit past the merge base, and origin/main one the branch
# lacks: the diff is against the merge base, never against origin/main's tip.
BR="$ROOT/based"; mkdir -p "$BR"; g -C "$BR" init -q; printf 'a\n' > "$BR/a.txt"; g -C "$BR" add -A; g -C "$BR" commit -qm one
MB=$(git -C "$BR" rev-parse HEAD)
printf 'theirs\n' > "$BR/theirs.txt"; g -C "$BR" add theirs.txt; g -C "$BR" commit -qm theirs
g -C "$BR" update-ref refs/remotes/origin/main HEAD; g -C "$BR" reset -q --hard "$MB"
printf 'mine\n' > "$BR/mine.txt"; g -C "$BR" add mine.txt; g -C "$BR" commit -qm mine
printf 'b\n' >> "$BR/a.txt"; printf 'n\n' > "$BR/new.txt"; g -C "$BR" add -N new.txt
fresh; run "$BR" "$URL" off --base main
python3 -I - "$STUB/payload.1.sent" "$BR" "$MB" <<'PY' && [ "$rc" = 0 ] && ok "--base: the diff is against the merge base: the branch's commit and working tree in, origin/main's own commit out" || fail "--base diff: rc $rc $out"
import json, subprocess, sys
want = subprocess.run(["git", "-C", sys.argv[2], "diff", "--no-textconv", "--no-ext-diff", sys.argv[3]], capture_output=True, text=True).stdout
got = json.load(open(sys.argv[1]))["diff"]
sys.exit(0 if got == want and "+mine" in got and "+n" in got and "theirs" not in got else 1)
PY
# A colour setting, a relative-diff setting and a secret-named change: the
# script's own diff has no colour, full paths, and no .env.
printf 'K=1\n' > "$BR/.env"; g -C "$BR" add -N .env
g -C "$BR" config color.ui always; g -C "$BR" config color.diff always; g -C "$BR" config diff.relative true
fresh; run "$BR/" "$URL" off --base main
python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1]))["diff"]; sys.exit(0 if "\x1b" not in d and ".env" not in d and "b/mine.txt" in d else 1)' "$STUB/payload.1.sent" 2>/dev/null \
  && [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'secret-named: .env' && ok "--base: color.ui=always and diff.relative: no colour, .env left out and named" || fail "--base colour: rc $rc $out"
g -C "$BR" config --unset color.ui; g -C "$BR" config --unset color.diff; g -C "$BR" config --unset diff.relative; git -C "$BR" rm -q --cached .env; rm -f "$BR/.env"
# A Latin-1 file in the working tree: left out and named, the rest goes.
printf 'caf\351\n' > "$BR/latin.txt"; g -C "$BR" add -N latin.txt
fresh; run "$BR" "$URL" off --base main
python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1]))["diff"]; sys.exit(0 if "latin" not in d and "b/mine.txt" in d else 1)' "$STUB/payload.1.sent" 2>/dev/null \
  && [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'not UTF-8 text: latin.txt' && ok "--base: a Latin-1 file is left out of the diff and named, the rest sent" || fail "--base latin: rc $rc $out"
git -C "$BR" rm -q --cached latin.txt; rm -f "$BR/latin.txt"
for b in "main'; touch $ROOT/pwned2; '" "-p" "--output=x" "ma in" 'ma$in' "" ; do
  fresh; run "$BR" "$URL" off --base "$b"
  [ "$rc" = 1 ] && [ "$(calls)" = 0 ] && printf '%s' "$out" | grep -q 'is not a branch name this script accepts' && ok "--base refuses [$b] before anything" || fail "--base [$b]: rc $rc calls $(calls) $out"
done
[ -e "$ROOT/pwned2" ] && fail "--base: a branch name was evaluated"
fresh; run "$BR" "$URL" off --base nosuch
[ "$rc" = 1 ] && [ "$(calls)" = 0 ] && printf '%s' "$out" | grep -q 'no merge base with origin/nosuch' && ok "--base: a branch with no merge base refuses, nothing sent" || fail "--base nosuch: rc $rc $out"
fresh; run "$BR" "$URL" off --base
[ "$rc" = 1 ] && [ "$(calls)" = 0 ] && ok "--base with no name refuses" || fail "--base empty: rc $rc $out"

# Context files outside the repository, relative and absolute: not sent, named.
printf 'out\n' > "$ROOT/outside.txt"
fresh; run "$R" "$URL" off "$P" ../outside.txt "$ROOT/outside.txt"
python3 -I -c 'import json, sys; sys.exit(0 if json.load(open(sys.argv[1]))["files"] == [] else 1)' "$STUB/payload.1.sent" 2>/dev/null \
  && printf '%s' "$out" | grep -q "Not sent (secret-named, .*): $ROOT/outside.txt\. Not sent (a path with '..'; .*): \.\./outside.txt\." && ok "context outside the repository (absolute; relative with '..'): not sent, each named with its reason" || fail "outside context: $out"
# A context file whose name is not UTF-8: skipped and named, no traceback (where the file system allows such names).
NU="$R/$(printf 'n\351.txt')"
if { printf 'x\n' > "$NU"; } 2>/dev/null && [ -e "$NU" ]; then
  fresh; run "$R" "$URL" off "$P" "$NU"
  [ "$rc" = 0 ] && ! printf '%s' "$out" | grep -q Traceback && printf '%s' "$out" | grep -q 'Not sent.*n.*\.txt' && ok "a context file name that is not UTF-8 is skipped and named" || fail "non-UTF-8 context name: rc $rc $out"
  rm -f "$NU"
else echo "skip a non-UTF-8 context file name (this file system refuses it)"; fi

# A .git that git cannot read (a worktree or submodule whose git folder moved)
# is a broken repository, never a folder without git: it would be packed
# without its .gitignore. Newer git names the broken gitfile itself; older git
# says "not a git repository", and the script's own walk-up catches that.
BW="$ROOT/brokenwt"; mkdir -p "$BW/sub"; printf 'gitdir: %s/gone\n' "$ROOT" > "$BW/.git"; printf 'x\n' > "$BW/sub/a.py"; printf 'secret.log\n' > "$BW/.gitignore"
for at in "$BW" "$BW/sub"; do
  fresh; run "$at" "$URL" required "$P"
  [ "$rc" = 1 ] && [ "$(calls)" = 0 ] && printf '%s' "$out" | grep -qE '\.git is there but git cannot read it|git cannot read this repository' && ok "a .git file whose folder is gone refuses ($(basename "$at")), nothing sent" || fail "broken .git ($at): rc $rc calls $(calls) $out"
done

# ---- 6c. The diff is git's, written with no settings, read by path -------
payload_diff() { python3 -I -c 'import json, sys; sys.stdout.write(json.load(open(sys.argv[1]))["diff"])' "$STUB/payload.1.sent"; }
# A reference diff of the same two states, by a git with no settings at all.
refdiff() { # repo from [to]: to = the working copy when absent
  ( cd "$1" && env -i PATH="$PATH" HOME="$ROOT/nohome" GIT_CONFIG_NOSYSTEM=1 LC_ALL=C \
      git -c core.quotePath=true diff --no-color --no-ext-diff --no-textconv -M --submodule=short "$2" ${3:+"$3"} ); }
mkdir -p "$ROOT/nohome"

# a file without a final newline, changed on both sides: git's own markers, no filter.
# Same size and the same mtime as when it was added, and the index file of
# that same second: git sees the edit only through its racy-entry check,
# which a copied index keeps only when the copy keeps the index's mtime.
T1="$ROOT/t1"; mkdir -p "$T1"; g -C "$T1" init -q; printf 'x' > "$T1/nonl.txt"; touch -t 202001010000 "$T1/nonl.txt"; g -C "$T1" add -A; g -C "$T1" commit -qm one
printf 'y' > "$T1/nonl.txt"; touch -t 202001010000 "$T1/nonl.txt" "$T1/.git/index"
fresh; run "$T1" "$URL" off --head
[ "$rc" = 0 ] && [ "$(payload_diff | grep -c '^\\ No newline at end of file')" = 2 ] && [ "$(payload_diff)" = "$(refdiff "$T1" HEAD)" ] \
  && ok "no final newline on both sides: both markers, the diff is git's" || fail "no newline: rc $rc $out / $(payload_diff)"

# --base reads the working copy as a commit would: a never-added file is in,
# an ignored one is out, and the user's index and status do not move.
T2="$ROOT/t2"; mkdir -p "$T2"; g -C "$T2" init -q; printf 'a\n' > "$T2/a.txt"; printf 'ign.log\n' > "$T2/.gitignore"; g -C "$T2" add -A; g -C "$T2" commit -qm one
g -C "$T2" update-ref refs/remotes/origin/main HEAD
printf 'b\n' >> "$T2/a.txt"; printf 'brand new\n' > "$T2/never.txt"; printf 'ignored\n' > "$T2/ign.log"
st0=$(git -C "$T2" status --porcelain); ix0=$(sha "$T2/.git/index")
fresh; run "$T2" "$URL" off --base main
[ "$rc" = 0 ] && payload_diff | grep -q '^+++ b/never.txt' && ! payload_diff | grep -q 'ign.log' \
  && [ "$st0" = "$(git -C "$T2" status --porcelain)" ] && [ "$ix0" = "$(sha "$T2/.git/index")" ] \
  && ok "--base: a never-added file is in, an ignored one out; index and status untouched" || fail "--base untracked: rc $rc $out"
printf '%s' "$out" | grep -q 'The diff includes 1 untracked file git does not ignore: never.txt' && ok "...and the manifest names the untracked file" || fail "manifest untracked: $out"
fresh; run "$T2" --dry-run off --base main
[ "$rc" = 0 ] && [ "$(calls)" = 0 ] && printf '%s\n' "$out" | grep -qx 'never.txt (new, untracked)' && printf '%s\n' "$out" | grep -qx 'a.txt' \
  && ok "--dry-run lists the untracked file as new, sends nothing" || fail "dry-run: rc $rc calls $(calls) $out"
# The dry run prints the manifest line the upload would, byte for byte, with
# a snapshot and without, and makes no request.
for sv in required off; do
  fresh; run "$T2" --dry-run "$sv" --base main; m1=$(printf '%s\n' "$out" | grep '^OhMyBug upload'); c1=$(calls)
  fresh; run "$T2" "$URL" "$sv" --base main; m2=$(printf '%s\n' "$out" | grep '^OhMyBug upload')
  [ -n "$m1" ] && [ "$m1" = "$m2" ] && [ "$c1" = 0 ] && [ "$rc" = 0 ] \
    && ok "--dry-run $sv: the same manifest line as the $sv upload, no request" || fail "dry-run manifest $sv: calls $c1 / [$m1] / [$m2]"
done
for i in 1 2 3 4 5 6; do printf 'u\n' > "$T2/u$i.txt"; done
fresh; run "$T2" --dry-run off --base main
printf '%s' "$out" | grep -q 'The diff includes 7 untracked files git does not ignore: never.txt, u1.txt, u2.txt, u3.txt, u4.txt and 2 more' \
  && ok "...many untracked files: the first five named, then and N more" || fail "many untracked: $out"
rm -f "$T2"/u?.txt

# every setting that changes git's diff format, set in the repository, in
# the user's config and in the environment, run from a subfolder: the payload
# is byte-equal to the clean run. A moved submodule, a rename and a quoted name.
T3="$ROOT/t3"; mkdir -p "$T3/src"; g -C "$T3" init -q
mkdir -p "$ROOT/t3sm"; g -C "$ROOT/t3sm" init -q; printf 's\n' > "$ROOT/t3sm/s"; g -C "$ROOT/t3sm" add -A; g -C "$ROOT/t3sm" commit -qm s
g -C "$T3" -c protocol.file.allow=always submodule add -q "$ROOT/t3sm" smod 2>/dev/null
printf 'a\nb\nc\n\nd\ne\nf\ng\n' > "$T3/a.txt"; printf 'r1\nr2\nr3\nr4\nr5\n' > "$T3/ren.txt"; printf 'q\n' > "$T3/src/sp ace.txt"
printf '*.txt diff=evil\n' > "$T3/.gitattributes"
g -C "$T3" add -A; g -C "$T3" commit -qm base
( cd "$T3/smod" && printf 't\n' > s && g commit -qam s2 )
printf 'a\nb\nc\n\nd\nE\nf\ng\n' > "$T3/a.txt"; g -C "$T3" mv ren.txt ren2.txt; printf 'r6\n' >> "$T3/ren2.txt"; printf 'Q\n' > "$T3/src/sp ace.txt"
fresh; run "$T3/src" "$URL" off --head; ref=$(payload_diff)
[ "$rc" = 0 ] && printf '%s' "$ref" | grep -q '^rename from ren.txt' && printf '%s' "$ref" | grep -q '^+Subproject commit' && printf '%s' "$ref" | grep -q '^diff --git a/a.txt b/a.txt' \
  || fail "the clean run is not the expected git diff: rc $rc $out / $ref"
HOSTILE="$ROOT/t3global"; cp "$GIT_CONFIG_GLOBAL" "$HOSTILE"
for kv in diff.noprefix=true diff.mnemonicPrefix=true diff.submodule=log diff.relative=true color.ui=always color.diff=always \
          diff.suppressBlankEmpty=true diff.context=0 diff.interHunkContext=9 diff.renames=false diff.algorithm=patience \
          diff.external=/bin/false diff.orderFile=/nonexistent diff.ignoreSubmodules=all core.quotePath=false \
          diff.indentHeuristic=false core.abbrev=40 diff.srcPrefix=zz/ diff.dstPrefix=yy/ diff.renameLimit=1; do
  git -C "$T3" config "${kv%%=*}" "${kv#*=}"; git config --file "$HOSTILE" "${kv%%=*}" "${kv#*=}"
done
git -C "$T3" config diff.evil.textconv 'sed s/a/ZZ/'; git -C "$T3" config diff.evil.command /bin/false
printf '*.txt diff=evil\n' > "$T3/.git/info/attributes"
fresh; out=$(cd "$T3/src" && GIT_CONFIG_GLOBAL="$HOSTILE" GIT_DIFF_OPTS=-u0 GIT_EXTERNAL_DIFF=/bin/false \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=diff.noprefix GIT_CONFIG_VALUE_0=true PATH="$BIN:$PATH" "$TSH" "$UP" "$URL" off --head 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(payload_diff)" = "$ref" ] && ok "hostile settings (repository, user, environment, subfolder): the payload is byte-equal to the clean run" \
  || fail "hostile: rc $rc $out / $(payload_diff | head -5)"
# --only is below the current folder, as a literal path.
fresh; run "$T3/src" "$URL" off --head --only 'sp ace.txt'
[ "$rc" = 0 ] && [ "$(payload_diff | grep -c '^diff --git')" = 1 ] && payload_diff | grep -q '^diff --git "a/src/sp ace.txt"\|^diff --git a/src/sp ace.txt' \
  && ok "--only from a subfolder: that file only, under its full path" || fail "--only: rc $rc $(payload_diff | grep '^diff')"
for o in /etc/passwd ../a.txt 'src/../x' ''; do
  fresh; run "$T3/src" "$URL" off --head --only "$o"
  [ "$rc" = 1 ] && [ "$(calls)" = 0 ] && ok "--only refuses [$o]" || fail "--only [$o]: rc $rc"
done

# a conflicted merge reads as the working file, markers and all; the user's
# index keeps its three stages.
T4="$ROOT/t4"; mkdir -p "$T4"; g -C "$T4" init -q; printf 'a\nb\nc\n' > "$T4/m.txt"; g -C "$T4" add -A; g -C "$T4" commit -qm base
b4=$(git -C "$T4" symbolic-ref --short HEAD)  # main, or master on git before 2.28
g -C "$T4" checkout -q -b other; printf 'a\nOTHER\nc\n' > "$T4/m.txt"; g -C "$T4" commit -qam other
g -C "$T4" checkout -q "$b4"; printf 'a\nMINE\nc\n' > "$T4/m.txt"; g -C "$T4" commit -qam mine
g -C "$T4" merge other >/dev/null 2>&1 || :
fresh; run "$T4" "$URL" off --head
[ "$rc" = 0 ] && payload_diff | grep -q '^+<<<<<<<' && ! payload_diff | grep -qi 'unmerged' && [ "$(git -C "$T4" ls-files -u | wc -l | tr -d ' ')" = 3 ] \
  && ok "unmerged: the working file with its markers, the index keeps 3 stages" || fail "unmerged: rc $rc $out / $(payload_diff)"

# the real curl with a hostile ~/.curlrc (retry, follow, fail, an output
# file): -q first ignores it, so one POST, 75, the body printed, no file.
REALCURL=$(command -v curl)
cat > "$ROOT/srv5.py" <<'PY'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers["content-length"]))
        open(sys.argv[2], "a").write(self.path + "\n")
        self.send_response(503); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(b'{"code":"busy5"}')
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(s.server_port))
s.serve_forever()
PY
python3 -I "$ROOT/srv5.py" "$ROOT/port5" "$ROOT/srvlog5" >/dev/null 2>&1 & srv5=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$ROOT/port5" ] && break; /bin/sleep 0.3; done
mkdir -p "$ROOT/realbin5" "$ROOT/crc"
cat > "$ROOT/realbin5/curl" <<SH
#!/bin/sh
for a; do shift; case \$a in https://mcp.ohmybug.ai/*) a="http://127.0.0.1:$(cat "$ROOT/port5")/\${a#https://mcp.ohmybug.ai/}" ;; esac; set -- "\$@" "\$a"; done
exec "$REALCURL" "\$@"
SH
chmod +x "$ROOT/realbin5/curl"
printf 'retry = 3\nretry-delay = 0\nlocation\nfail\noutput = "%s/crc-out"\n' "$ROOT" > "$ROOT/crc/.curlrc"
out=$(cd "$R" && HOME="$ROOT/crc" CURL_HOME="$ROOT/crc" PATH="$ROOT/realbin5:$PATH" "$TSH" "$UP" "$URL" required "$P" 2>&1); rc=$?
kill "$srv5" 2>/dev/null; wait "$srv5" 2>/dev/null
[ "$rc" = 75 ] && [ "$(grep -c '/repo$' "$ROOT/srvlog5" 2>/dev/null)" = 1 ] && printf '%s' "$out" | grep -q 'busy5' && [ ! -e "$ROOT/crc-out" ] \
  && ok "a hostile ~/.curlrc is ignored: one POST, 75, the body printed, no output file" || fail "curlrc: rc $rc posts $(grep -c '/repo$' "$ROOT/srvlog5" 2>/dev/null) out-file $([ -e "$ROOT/crc-out" ] && echo yes) $out"

# a context file reached through a symlink, a folder or the file itself,
# inside the repository: skipped and named, nothing read.
mkdir -p "$R/real"; printf 'ctx\n' > "$R/real/c.txt"; ln -s real "$R/linkdir"; ln -s real/c.txt "$R/linkfile.txt"; commit_in real linkdir linkfile.txt
fresh; run "$R" "$URL" off "$P" linkdir/c.txt linkfile.txt
python3 -I -c 'import json, sys; sys.exit(0 if json.load(open(sys.argv[1]))["files"] == [] else 1)' "$STUB/payload.1.sent" 2>/dev/null \
  && printf '%s' "$out" | grep -q 'Not sent.*linkdir/c.txt, linkfile.txt' && ok "context through an in-repository symlink (folder, file): skipped and named" || fail "symlink context: $out"
fresh; run "$R" "$URL" off "$P" real/c.txt
python3 -I -c 'import json, sys; sys.exit(0 if [f["path"] for f in json.load(open(sys.argv[1]))["files"]] == ["real/c.txt"] else 1)' "$STUB/payload.1.sent" 2>/dev/null \
  && ok "...the same file by its own path is sent" || fail "real path: $out"
uncommit real linkdir linkfile.txt

# secret names from a subfolder: none in the diff, all named; a listed .env context file is not sent.
T7="$ROOT/t7"; mkdir -p "$T7/conf" "$T7/secrets" "$T7/src"; g -C "$T7" init -q
printf 'K=1\n' > "$T7/.env"; printf 's\n' > "$T7/conf/My.Secret.yml"; printf 's\n' > "$T7/secrets/x.txt"; printf 'a\n' > "$T7/src/a.py"
g -C "$T7" add -f -A; g -C "$T7" commit -qm base
printf 'K=2\n' > "$T7/.env"; printf 't\n' > "$T7/conf/My.Secret.yml"; printf 't\n' > "$T7/secrets/x.txt"; printf 'b\n' >> "$T7/src/a.py"
fresh; run "$T7/src" "$URL" off --head ../.env
d7=$(payload_diff)
[ "$rc" = 0 ] && ! printf '%s' "$d7" | grep -qiE 'env|secret' && printf '%s' "$d7" | grep -q 'src/a.py' \
  && printf '%s' "$out" | grep -q 'secret-named: .env, conf/My.Secret.yml, secrets/x.txt' \
  && python3 -I -c 'import json, sys; sys.exit(0 if json.load(open(sys.argv[1]))["files"] == [] else 1)' "$STUB/payload.1.sent" \
  && printf '%s' "$out" | grep -q "Not sent (a path with '..'; .*): ../.env" \
  && ok "secret names from a subfolder: left out by git, named; a context file given with '..' not sent, its own reason" || fail "secrets: rc $rc $out / $d7"
# The same .env from the top, without '..': listed by git, still not sent, the secret-name reason.
fresh; run "$T7" "$URL" off --head .env
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'Not sent (secret-named, .*): .env' \
  && python3 -I -c 'import json, sys; sys.exit(0 if json.load(open(sys.argv[1]))["files"] == [] else 1)' "$STUB/payload.1.sent" \
  && ok "a listed .env context file from the top is not sent, named as secret-named" || fail "top .env context: rc $rc $out"

# a Latin-1 file is left out and named, the UTF-8 one goes; a Latin-1 file renamed and edited: both names out.
T8="$ROOT/t8"; mkdir -p "$T8"; g -C "$T8" init -q; printf 'caf\351\n' > "$T8/lat.txt"; printf 'ok\n' > "$T8/u.txt"; printf 'caf\351 1\n2\n3\n4\n' > "$T8/old.txt"
g -C "$T8" add -A; g -C "$T8" commit -qm base
printf 'caf\351 2\n' > "$T8/lat.txt"; printf 'ok2\n' >> "$T8/u.txt"
fresh; run "$T8" "$URL" off --head
[ "$rc" = 0 ] && payload_diff | grep -q 'b/u.txt' && ! payload_diff | grep -q 'lat.txt' && printf '%s' "$out" | grep -q 'not UTF-8 text: lat.txt' \
  && ok "a Latin-1 file is left out and named, the UTF-8 one sent" || fail "latin: rc $rc $out"
g -C "$T8" mv old.txt new.txt; printf '5\n' >> "$T8/new.txt"
fresh; run "$T8" "$URL" off --head
[ "$rc" = 0 ] && ! payload_diff | grep -qE 'old.txt|new.txt' && printf '%s' "$out" | grep -q 'not UTF-8 text: .*new.txt' && printf '%s' "$out" | grep -q 'not UTF-8 text: .*old.txt' \
  && ok "a Latin-1 file renamed and edited: both names left out, exit 0" || fail "rename: rc $rc $out / $(payload_diff | grep '^diff')"

# a file name that is not UTF-8, made without the file system: the payload is JSON, the manifest one line.
T9="$ROOT/t9"; mkdir -p "$T9"; g -C "$T9" init -q; printf 'a\n' > "$T9/a.txt"; g -C "$T9" add -A; g -C "$T9" commit -qm base
b9=$(printf 'x\n' | git -C "$T9" hash-object -w --stdin)
printf '100644 blob %s\tbad\377name.txt\0' "$b9" | git -C "$T9" update-index -z --add --index-info
t9=$(git -C "$T9" write-tree); c9=$(git -C "$T9" -c user.name=t -c user.email=t@t commit-tree -p HEAD -m bad "$t9"); git -C "$T9" update-ref HEAD "$c9"
fresh; run "$T9" "$URL" off --commits 1
[ "$rc" = 0 ] && python3 -I -c 'import json, sys; json.load(open(sys.argv[1]))' "$STUB/payload.1.sent" && [ "$(grep -c '^OhMyBug upload' "$STUB/transcript")" = 1 ] \
  && payload_diff | grep -qF '"a/bad\377name.txt"' && ok "a non-UTF-8 file name: quoted by git, the payload is JSON, one manifest line" || fail "bad name: rc $rc $out"

# the third argument is a scope word; a diff file is no longer an input.
printf 'diff --git a/a.txt b/a.txt\n' > "$ROOT/some.patch"
for a3 in "$ROOT/some.patch" --whatever ''; do
  fresh; run "$R" "$URL" off "$a3"
  [ "$rc" = 1 ] && [ "$(calls)" = 0 ] && printf '%s' "$out" | grep -q 'the third argument is the scope' && ok "a third argument [$a3] that is no scope refuses, nothing sent" || fail "[$a3]: rc $rc $out"
done

# the scopes that replaced the ladder functions, ported row for row: a
# repository with secret names at every depth, a staged file, a non-ASCII name,
# from the root and a subfolder, and a folder with no git.
dnames() { printf '%s\n' "$out" | sed -n '/^OhMyBug upload/,$p' | sed 1d | sed 's/ (new, untracked)$//' | sort | tr '\n' ' '; }
dry() { fresh; run "$1" --dry-run off "${@:2}"; [ "$(calls)" = 0 ] || fail "--dry-run made a request"; }
LD="$ROOT/t11/r"; mkdir -p "$LD"; g -C "$LD" init -q
( cd "$LD" && mkdir -p deploy sub secrets config/credentials src/solver
  for f in .env .env.local .envrc .env-production sub/.ENV id_rsa id_dsa id_ecdsa id_ed25519 deploy/id_ed25519 \
           cert.pem server.KEY cert.p12 cert.pfx API_SECRETS.txt aws_credentials secrets/config.yml \
           config/credentials/gcp.json src/.env; do printf 's\n' > "$f"; done
  printf 'a\n' > a.py; printf 'm\n' > src/solver/m.py )
dry "$LD" --all
[ "$(dnames)" = "a.py src/solver/m.py " ] && ok "--all before the first commit: code only, no secret at any depth" || fail "unborn: [$(dnames)] $out"
g -C "$LD" add -A; g -C "$LD" commit -qm base
dry "$LD" --all --only src/solver/
[ "$(dnames)" = "src/solver/m.py " ] && ok "--all --only a folder: the folder only" || fail "folder: [$(dnames)]"
printf 'b\n' >> "$LD/a.py"; g -C "$LD" add a.py; printf 'n\n' > "$LD/sub/new.py"; printf 'r\n' > "$LD/résumé.py"
st11=$(git -C "$LD" status --porcelain); ix11=$(sha "$LD/.git/index")
dry "$LD" --head
[ "$(dnames)" = "a.py résumé.py sub/new.py " ] && ok "--head: staged, unstaged and new files, a non-ASCII name too" || fail "head: [$(dnames)]"
[ "$st11" = "$(git -C "$LD" status --porcelain)" ] && [ "$ix11" = "$(sha "$LD/.git/index")" ] && ok "...the user's index does not move" || fail "index moved"
git clone -q "$LD" "$ROOT/t11/h" 2>/dev/null
( cd "$ROOT/t11/h" && printf 'c1\n' > c1.py && g add c1.py && g commit -qm c1 && printf 'c2\n' > src/solver/c2.py && g add src/solver/c2.py && g commit -qm c2 \
  && printf 'dirty\n' >> c1.py && printf 'u\n' > untracked.py )
dry "$ROOT/t11/h" --commits 1; [ "$(dnames)" = "src/solver/c2.py " ] && ok "--commits 1: the last commit, no working-copy edit" || fail "last1: [$(dnames)]"
dry "$ROOT/t11/h" --commits 2; [ "$(dnames)" = "c1.py src/solver/c2.py " ] && ok "--commits 2: both commits only" || fail "last2: [$(dnames)]"
dry "$ROOT/t11/h" --commits 9; [ "$(dnames)" = "a.py c1.py src/solver/c2.py src/solver/m.py " ] && ok "--commits 9 on 3 commits: the whole history, secrets out" || fail "last9: [$(dnames)]"
dry "$LD" --commits 9; [ "$(dnames)" = "a.py src/solver/m.py " ] && ok "--commits 9 here: the committed history only" || fail "commits9: [$(dnames)]"
printf 's\n' > "$LD/.env.new"; printf 's\n' > "$LD/secrets/new.yml"; printf 's\n' > "$LD/sub/id_rsa"
dry "$LD/src" --head; [ "$(dnames)" = "a.py résumé.py sub/new.py " ] && ok "--head from a subfolder: the whole repository, new secrets out" || fail "sub head: [$(dnames)]"
dry "$LD/src" --all; [ "$(dnames)" = "a.py résumé.py src/solver/m.py sub/new.py " ] && ok "--all from a subfolder: the whole repository" || fail "sub all: [$(dnames)]"
dry "$LD/src" --all --only solver/; [ "$(dnames)" = "src/solver/m.py " ] && ok "--all --only from a subfolder: below it" || fail "sub folder: [$(dnames)]"
NGT="$ROOT/t11/ng"; mkdir -p "$NGT/k"; printf 'q\n' > "$NGT/q.py"; printf 's\n' > "$NGT/.env"; printf 's\n' > "$NGT/k/a.pem"
dry "$NGT" --all; [ "$(dnames)" = "q.py " ] && [ ! -e "$NGT/.git" ] && ok "a folder without git, --all: code only, no .git left" || fail "nogit: [$(dnames)] $out"
fresh; run "$NGT" "$URL" off --head
[ "$rc" = 1 ] && [ "$(calls)" = 0 ] && printf '%s' "$out" | grep -q 'only --all applies' && ok "a folder without git refuses another scope" || fail "nogit head: rc $rc $out"
for nn in 0 01 1000 x ''; do
  fresh; run "$LD" "$URL" off --commits "$nn"
  [ "$rc" = 1 ] && [ "$(calls)" = 0 ] && ok "--commits [$nn] refuses" || fail "--commits [$nn]: rc $rc"
done

# git older than 2.25: exit 4, the version found and the fix named, nothing sent.
OG="$ROOT/oldgit"; mkdir -p "$OG"
printf '#!/bin/sh\n[ "$1" = version ] && { echo "git version 2.24.0"; exit 0; }\nexec %s "$@"\n' "$(command -v git)" > "$OG/git"; chmod +x "$OG/git"
fresh; out=$(cd "$R" && PATH="$OG:$BIN:$PATH" "$TSH" "$UP" "$URL" required "$P" 2>&1); rc=$?
[ "$rc" = 4 ] && [ "$(calls)" = 0 ] && [ "$out" = "omb-upload: git 2.24.0 found, 2.25 or newer is needed: update git; nothing was sent" ] \
  && ok "git 2.24: exit 4, the version found and the fix, nothing sent" || fail "old git: rc $rc $out"

# ---- 6d. Partial and shallow clones, many files, snapshot of HEAD, arguments
# A blobless partial clone: --base needs a blob the clone never fetched; the
# real repository fetches it before the bare one diffs. (allowAnySHA1InWant:
# git 2.25 fetches a missing object over file:// only with it.)
PS="$ROOT/pc-src"; mkdir -p "$PS/secrets"; g -C "$PS" init -q; printf 'v1\n' > "$PS/a.txt"; printf 's1\n' > "$PS/secrets/x.txt"; g -C "$PS" add -A; g -C "$PS" commit -qm one
c1=$(git -C "$PS" rev-parse HEAD); printf 'v2\n' > "$PS/a.txt"; printf 's2\n' > "$PS/secrets/x.txt"; g -C "$PS" commit -qam two; g -C "$PS" config uploadpack.allowFilter true; g -C "$PS" config uploadpack.allowAnySHA1InWant true
PC="$ROOT/pc"; g clone -q --filter=blob:none "file://$PS" "$PC" 2>/dev/null
g -C "$PC" update-ref refs/remotes/origin/main "$c1"; printf 'v3\n' > "$PC/a.txt"
git -C "$PC" rev-list --objects --missing=print "$c1" 2>/dev/null | grep -q "^?" \
  || fail "partial clone: the old blob is already present, so the row proves nothing"
fresh; run "$PC" "$URL" off --base main
[ "$rc" = 0 ] && payload_diff | grep -q '^-v1' && payload_diff | grep -q '^+v3' && ok "a blobless partial clone: --base reaches an unfetched blob, exit 0" || fail "partial clone: rc $rc $out"
# 2000 small files and one Latin-1 file: one cat-file read, and 8 diff runs
# whatever the file count (3 in the real repository, then in the bare one:
# every name, the kept names, the one candidate's own diff, the diff, its names).
MF="$ROOT/many"; mkdir -p "$MF/f"; g -C "$MF" init -q
python3 -I -c 'import sys
for i in range(2000): open("%s/f/%04d.txt" % (sys.argv[1], i), "w").write("x%d\n" % i)
open(sys.argv[1] + "/latin.txt", "wb").write(b"caf\xe9\n")' "$MF"
GW="$ROOT/gitwrap"; mkdir -p "$GW"; : > "$ROOT/gitcalls"
printf '#!/bin/sh\necho "$*" >> %s\nexec %s "$@"\n' "$ROOT/gitcalls" "$(command -v git)" > "$GW/git"; chmod +x "$GW/git"
fresh; out=$(cd "$MF" && PATH="$GW:$BIN:$PATH" "$TSH" "$UP" "$URL" off --all 2>&1); rc=$?
ncat=$(grep -c 'cat-file --batch' "$ROOT/gitcalls"); ndt=$(grep -c 'diff-tree' "$ROOT/gitcalls")
[ "$rc" = 0 ] && [ "$ncat" = 1 ] && [ "$ndt" = 8 ] && printf '%s' "$out" | grep -q 'not UTF-8 text: latin.txt' && printf '%s' "$out" | grep -q '(2000 files)' \
  && ok "2000 files and one Latin-1 file: one cat-file read, $ndt diff runs, the Latin-1 file named" || fail "many files: rc $rc cat-file $ncat diff-tree $ndt $(printf '%s' "$out" | head -c 300)"
# --commits with a snapshot: the snapshot is HEAD's tree, not the dirty working copy.
SH5="$ROOT/snaphead"; mkdir -p "$SH5"; g -C "$SH5" init -q; printf 'one\n' > "$SH5/a.txt"; g -C "$SH5" add -A; g -C "$SH5" commit -qm one
printf 'two\n' > "$SH5/a.txt"; g -C "$SH5" commit -qam two; printf 'dirty\n' > "$SH5/a.txt"; printf 'new\n' > "$SH5/untracked.txt"
fresh; run "$SH5" "$URL" required --commits 1
[ "$rc" = 0 ] && [ "$(tar -xzOf "$STUB/repo.1.sent" a.txt 2>/dev/null)" = two ] && ! tar -tzf "$STUB/repo.1.sent" | grep -q untracked.txt \
  && printf '%s' "$out" | grep -q 'repository snapshot of HEAD of' && ok "--commits with a snapshot: the snapshot is HEAD's tree, and says so" || fail "snapshot of HEAD: rc $rc $(tar -xzOf "$STUB/repo.1.sent" a.txt 2>/dev/null) $out"
# A shallow clone with fewer commits than asked: refused, never the whole tree as new.
g clone -q --depth 1 "file://$PS" "$ROOT/shallow" 2>/dev/null
fresh; run "$ROOT/shallow" "$URL" off --commits 3
[ "$rc" = 1 ] && [ "$(calls)" = 0 ] && printf '%s' "$out" | grep -q 'this clone is shallow and holds 3 or fewer commits: fetch more history (git fetch --deepen=3)' \
  && ok "a shallow clone and --commits 3: refused, nothing sent" || fail "shallow: rc $rc $out"
# A context file name that starts with '-' is refused; one from a subfolder is sent under its full path.
fresh; run "$R" "$URL" off "$P" -x.txt
[ "$rc" = 1 ] && [ "$(calls)" = 0 ] && printf '%s' "$out" | grep -q "may not start with '-'" && ok "a context file name starting with '-' refuses" || fail "dash context: rc $rc $out"
mkdir -p "$R/sub"; printf 'c\n' > "$R/sub/c.py"; commit_in sub
fresh; run "$R/sub" "$URL" off --head c.py ./c.py
python3 -I -c 'import json, sys; sys.exit(0 if [f["path"] for f in json.load(open(sys.argv[1]))["files"]] == ["sub/c.py", "sub/c.py"] else 1)' "$STUB/payload.1.sent" 2>/dev/null \
  && ok "a context file from a subfolder is sent under its full path" || fail "subfolder context: $out"
uncommit sub
# --only . at the top with another --only: no narrowing at all.
fresh; run "$T3" "$URL" off --head --only . --only a.txt
[ "$rc" = 0 ] && payload_diff | grep -q 'ren2.txt' && ok "--only . at the top with another --only: the whole repository" || fail "--only . plus: rc $rc $(payload_diff | grep '^diff')"

# A treeless clone (--filter=tree:0): the trees too are fetched in the real
# repository before the bare one diffs, a secret-named folder's as well (the
# bare one lists every name to say which were left out).
fresh; g clone -q --filter=tree:0 "file://$PS" "$ROOT/tc" 2>/dev/null
g -C "$ROOT/tc" update-ref refs/remotes/origin/main "$c1"; printf 'v3\n' > "$ROOT/tc/a.txt"
run "$ROOT/tc" "$URL" off --base main
[ "$rc" = 0 ] && payload_diff | grep -q '^-v1' && payload_diff | grep -q '^+v3' && printf '%s' "$out" | grep -q 'secret-named: secrets/x.txt' \
  && ok "a treeless partial clone: --base, exit 0, the secret-named folder left out and named" || fail "treeless clone: rc $rc $out"
# 50 unfetched blobs and a changed symlink in a blobless clone: ONE fetch for
# all of them (counted by a wrapped upload-pack on the remote side).
P50="$ROOT/p50-src"; mkdir -p "$P50"; g -C "$P50" init -q
for i in $(seq 1 50); do printf 'old %d\n' "$i" > "$P50/f$i.txt"; done; ln -s f1.txt "$P50/ln"
g -C "$P50" add -A; g -C "$P50" commit -qm one; b50=$(git -C "$P50" rev-parse HEAD)
for i in $(seq 1 50); do printf 'new %d\n' "$i" > "$P50/f$i.txt"; done; rm "$P50/ln"; ln -s f2.txt "$P50/ln"
g -C "$P50" add -A; g -C "$P50" commit -qm two
g -C "$P50" config uploadpack.allowFilter true; g -C "$P50" config uploadpack.allowAnySHA1InWant true
printf '#!/bin/sh\necho fetch >> %s\nexec git-upload-pack "$@"\n' "$ROOT/p50-count" > "$ROOT/p50-up"; chmod +x "$ROOT/p50-up"
g clone -q --filter=blob:none --upload-pack="$ROOT/p50-up" "file://$P50" "$ROOT/p50" 2>/dev/null
g -C "$ROOT/p50" config remote.origin.uploadpack "$ROOT/p50-up"; g -C "$ROOT/p50" update-ref refs/remotes/origin/main "$b50"
miss=$(git -C "$ROOT/p50" rev-list --objects --missing=print "$b50" | grep -c '^?')
: > "$ROOT/p50-count"; fresh; run "$ROOT/p50" "$URL" off --base main
nf=$(wc -l < "$ROOT/p50-count" | tr -d ' ')
[ "$rc" = 0 ] && [ "$miss" = 51 ] && [ "$nf" = 1 ] && payload_diff | grep -q '^-f1.txt' && payload_diff | grep -q '^+f2.txt' && [ "$(payload_diff | grep -c '^+new ')" = 50 ] \
  && ok "a blobless clone, 51 unfetched blobs (a symlink's among them): one fetch, the link's change in the diff" || fail "one fetch: rc $rc missing $miss fetches $nf $out"
# The snapshot of a blobless clone whose 30 HEAD blobs were never fetched
# (--no-checkout): --commits 1 with a snapshot makes exactly 2 fetches, one
# for the diff (the one changed file) and one for the pack (the other 29), and
# the tar holds every file.
SP="$ROOT/sp-src"; mkdir -p "$SP"; g -C "$SP" init -q
for i in $(seq 1 30); do printf 'f %d\n' "$i" > "$SP/f$i.txt"; done; g -C "$SP" add -A; g -C "$SP" commit -qm one
printf 'changed\n' >> "$SP/f1.txt"; g -C "$SP" commit -qam two
g -C "$SP" config uploadpack.allowFilter true; g -C "$SP" config uploadpack.allowAnySHA1InWant true
g clone -q --no-checkout --filter=blob:none --upload-pack="$ROOT/p50-up" "file://$SP" "$ROOT/sp" 2>/dev/null
g -C "$ROOT/sp" config remote.origin.uploadpack "$ROOT/p50-up"
miss=$(git -C "$ROOT/sp" rev-list --objects --missing=print HEAD | grep -c '^?')
: > "$ROOT/p50-count"; fresh; run "$ROOT/sp" "$URL" required --commits 1
nf=$(wc -l < "$ROOT/p50-count" | tr -d ' ')
[ "$rc" = 0 ] && [ "$miss" = 31 ] && [ "$nf" = 2 ] && [ "$(tar -tzf "$STUB/repo.1.sent" | grep -c '^f[0-9]*\.txt$')" = 30 ] \
  && [ "$(tar -xzOf "$STUB/repo.1.sent" f30.txt)" = 'f 30' ] \
  && ok "the snapshot of a blobless clone: every file packed, one fetch for the pack and one for the diff" || fail "blobless snapshot: rc $rc missing $miss fetches $nf $out"
# The remote is gone: the read fails with a sentence, never a traceback.
g -C "$ROOT/p50" remote set-url origin "file://$ROOT/no-such-remote"; g -C "$ROOT/p50" config --unset remote.origin.uploadpack
fresh; g clone -q --filter=blob:none "file://$P50" "$ROOT/p50b" 2>/dev/null; g -C "$ROOT/p50b" update-ref refs/remotes/origin/main "$b50"
g -C "$ROOT/p50b" remote set-url origin "file://$ROOT/no-such-remote"
run "$ROOT/p50b" "$URL" off --base main
# (git 2.25 stops at the listing, newer git at the blob read: the same partial-clone sentence.)
[ "$rc" = 1 ] && [ "$(calls)" = 0 ] && printf '%s' "$out" | grep -q 'a partial clone whose remote is out of reach?); nothing was sent' && ! printf '%s' "$out" | grep -q Traceback \
  && ok "a blobless clone whose remote is gone: one sentence, nothing sent" || fail "remote gone: rc $rc $out"
# Non-UTF-8 bytes: only what reaches the diff counts. A Latin-1 byte far from
# the edit is sent; one inside the hunk leaves its file out, named; a symlink
# whose target is not UTF-8 is left out, named; a binary file (a NUL in its
# first 8000 bytes) is sent as git writes it, not named.
U8="$ROOT/u8"; mkdir -p "$U8"; g -C "$U8" init -q
python3 -I -c 'import sys
d = sys.argv[1]
open(d + "/far.txt", "wb").write(b"caf\xe9\n" + b"".join(b"line %d\n" % i for i in range(30)))
open(d + "/near.txt", "wb").write(b"caf\xe9\nend\n")
open(d + "/bin.dat", "wb").write(b"\0\xe9\xff" + b"x" * 10)' "$U8"
ln -s "$(printf 'caf\351')" "$U8/badlink"; ln -s ok "$U8/goodlink"
g -C "$U8" add -A; g -C "$U8" commit -qm one
printf 'line 29 edited\n' >> "$U8/far.txt"; printf 'end2\n' >> "$U8/near.txt"; printf 'y' >> "$U8/bin.dat"
rm "$U8/badlink"; ln -s "$(printf 'caf\351 2')" "$U8/badlink"; rm "$U8/goodlink"; ln -s ok2 "$U8/goodlink"
fresh; run "$U8" "$URL" off --head
[ "$rc" = 0 ] && payload_diff | grep -q '^+line 29 edited' && payload_diff | grep -q 'Binary files a/bin.dat and b/bin.dat differ' && payload_diff | grep -q '^+ok2' \
  && printf '%s' "$out" | grep -q 'not UTF-8 text: badlink, near.txt$\|not UTF-8 text: badlink, near.txt\.' && ! printf '%s' "$out" | grep -q 'UTF-8 text:.*\(far.txt\|bin.dat\|goodlink\)' \
  && ok "non-UTF-8 bytes: far from the edit sent, in the hunk or a link target left out and named, a binary file sent" || fail "utf-8 precision: rc $rc $out / $(payload_diff | grep '^diff')"
# More than 200 files whose changes are not UTF-8: refused, nothing sent.
L2="$ROOT/l201"; mkdir -p "$L2"; g -C "$L2" init -q
python3 -I -c 'import sys
for i in range(201): open("%s/l%03d.txt" % (sys.argv[1], i), "wb").write(b"caf\xe9\n")' "$L2"
fresh; run "$L2" "$URL" off --all
[ "$rc" = 1 ] && [ "$(calls)" = 0 ] && printf '%s' "$out" | grep -q 'more than 200 changed files are not UTF-8 text' && ok "201 non-UTF-8 files: refused, nothing sent" || fail "201 latin: rc $rc $(printf '%s' "$out" | tail -c 300)"
# 201 binary files whose bytes are not UTF-8: binary to git, so no candidates and no refusal.
B2="$ROOT/b201"; mkdir -p "$B2"; g -C "$B2" init -q
python3 -I -c 'import sys
for i in range(201): open("%s/b%03d.bin" % (sys.argv[1], i), "wb").write(b"\0\xe9\xff%d" % i)' "$B2"
fresh; run "$B2" "$URL" off --all
[ "$rc" = 0 ] && [ "$(payload_diff | grep -c '^Binary files')" = 201 ] && ! printf '%s' "$out" | grep -q 'not UTF-8' && ok "201 binary files: sent as git writes them, none a candidate" || fail "201 binary: rc $rc $(printf '%s' "$out" | tail -c 300)"
# Six non-UTF-8 and six secret-named files: each list in the manifest names five, then and 1 more.
mkdir -p "$ROOT/cap"; python3 -I -c 'import sys
for i in range(6):
    open("%s/m%d.txt" % (sys.argv[1], i), "wb").write(b"caf\xe9\n")
    open("%s/k%d.pem" % (sys.argv[1], i), "w").write("k\n")
open(sys.argv[1] + "/ok.txt", "w").write("ok\n")' "$ROOT/cap"
g -C "$ROOT/cap" init -q; fresh; run "$ROOT/cap" --dry-run off --all
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'secret-named: k0.pem, k1.pem, k2.pem, k3.pem, k4.pem and 1 more\.' \
  && printf '%s' "$out" | grep -q 'not UTF-8 text: m0.txt, m1.txt, m2.txt, m3.txt, m4.txt and 1 more\.' \
  && ok "the manifest names five secret-named and five non-UTF-8 files, then and N more" || fail "manifest caps: rc $rc $out"
# --commits with a snapshot in a sparse checkout: skip-worktree files are left
# out of the snapshot, as for the working copy.
SPC="$ROOT/spc"; g clone -q "$SRC" "$SPC" 2>/dev/null; g -C "$SPC" sparse-checkout init --cone 2>/dev/null; g -C "$SPC" sparse-checkout set src 2>/dev/null
fresh; run "$SPC" "$URL" required --commits 1
[ "$rc" = 0 ] && [ -n "$(git -C "$SPC" ls-files -t | grep '^S far/')" ] && ! tar -tzf "$STUB/repo.1.sent" | grep -q '^far/' && tar -tzf "$STUB/repo.1.sent" | grep -q '^src/deep/a.ts' \
  && ok "--commits with a snapshot in a sparse checkout: skip-worktree files left out" || fail "commits sparse snapshot: rc $rc $out / $(tar -tzf "$STUB/repo.1.sent" 2>/dev/null | tr '\n' ' ')"
# --only . and --only ./ from a subfolder: that folder; ./ at the top: the whole repository.
for o in . ./; do
  fresh; run "$T3/src" "$URL" off --head --only "$o"
  [ "$rc" = 0 ] && [ "$(payload_diff | grep '^diff' | tr '\n' ' ')" = 'diff --git a/src/sp ace.txt b/src/sp ace.txt ' ] \
    && ok "--only [$o] from a subfolder: that folder only" || fail "--only [$o] sub: rc $rc $(payload_diff | grep '^diff')"
done
fresh; run "$T3" "$URL" off --head --only ./
[ "$rc" = 0 ] && payload_diff | grep -q 'ren2.txt' && payload_diff | grep -q 'sp ace' && ok "--only ./ at the top: the whole repository" || fail "--only ./ top: rc $rc $(payload_diff | grep '^diff')"

# ---- 6e. The partial copy: argv[2] partial, the list, the mark ----------------
# Rows PP1-PP14 (the partial path's own numbering, apart from the payload
# door's P rows above).
# A fixture where the list is known: the change calls part_helper_name, which
# two unchanged files use; a manifest sits at the top; the rest is left out.
# tarnames: the members of the snapshot sent, one per line, exactly as stored.
tarnames() { python3 -I -c 'import sys, tarfile
for m in sorted(tarfile.open(sys.argv[1]).getmembers(), key=lambda m: m.name):
    if not m.isdir(): print(repr(m.name[2:] if m.name.startswith("./") else m.name))' "$STUB/repo.1.sent"; }
want_names() { printf '%s\n' "$@" | python3 -I -c 'import sys
for l in sorted(sys.stdin.read().split("\n")[:-1]): print(repr(l))'; }
PF="$ROOT/pf"; mkdir -p "$PF/src" "$PF/lib" "$PF/docs"; g -C "$PF" init -q
printf '{"name":"pf"}\n' > "$PF/package.json"
printf 'def compute():\n    return 1\n' > "$PF/src/core.py"
printf 'part_helper_name(1)\n' > "$PF/lib/use.py"; printf 'part_helper_name(2)\n' > "$PF/lib/use2.py"
printf 'x = 1\n' > "$PF/lib/other.py"; printf 'part_helper_name\n' > "$PF/docs/guide.md"
g -C "$PF" add -A; g -C "$PF" commit -qm base
printf 'def compute():\n    return part_helper_name(1)\n' > "$PF/src/core.py"
PWANT=$(want_names src/core.py package.json lib/use.py lib/use2.py)
# A python3 on PATH that counts the runs of the file list.
PYW="$ROOT/pywrap"; mkdir -p "$PYW"
printf '#!/bin/sh
case "$*" in *omb_paths.py*) echo run >> "%s/pathruns" ;; esac
exec %s "$@"
' "$ROOT" "$(command -v python3)" > "$PYW/python3"; chmod +x "$PYW/python3"
pathruns() { wc -l < "$ROOT/pathruns" 2>/dev/null | tr -d ' ' || echo 0; }
: > "$ROOT/pathruns"
fresh; out=$(cd "$PF" && PATH="$PYW:$BIN:$PATH" "$TSH" "$UP" "$URL" partial --head 2>&1); rc=$?
[ "$(pathruns)" = 1 ] || fail "PP2 the file list ran $(pathruns) times, want 1"
[ "$rc" = 0 ] && [ "$(tarnames)" = "$PWANT" ] && grep -q "^CURL repo $URL/repo?pack=partial\$" "$STUB/transcript" && [ "$(seq_)" = "repo payload " ] \
  && ok "PP2 partial: the snapshot is exactly the list, and only its request carries ?pack=partial" || fail "PP2 partial: rc $rc [$(tarnames | tr '\n' ' ')] $(cat "$STUB/transcript")"
grep -q "^CURL payload $URL\$" "$STUB/transcript" || fail "PP2 the payload door got a mark: $(cat "$STUB/transcript")"
printf '%s' "$out" | grep -q '+ partial repository snapshot: 4 of 6 files (1 of 1 changed, 1 build manifest, 2 files that use the changed names), ' \
  && printf '%s' "$out" | grep -q 'Left out: every other file, git-ignored files, submodules, 0 secret-named files' \
  && ok "PP2 ...the manifest says partial, N of M, by kind, and what is left out" || fail "PP2 manifest: $out"
PSHA=$(sha "$STUB/repo.1.sent"); PLINE=$(printf '%s\n' "$out" | grep '^OhMyBug upload')
: > "$ROOT/pathruns"
fresh; out=$(cd "$PF" && PATH="$PYW:$BIN:$PATH" "$TSH" "$UP" "$URL" required --head 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(tarnames | wc -l | tr -d ' ')" = 6 ] && grep -q "^CURL repo $URL/repo\$" "$STUB/transcript" && [ "$(pathruns)" = 0 ] \
  && ok "PP1 required on the same working copy: the file list never runs; the whole snapshot, no mark" || fail "PP1 required: list runs $(pathruns), rc $rc [$(tarnames | tr '\n' ' ')] $(cat "$STUB/transcript")"
# PP12: the same working copy packs to the same bytes, and a ticket that holds them takes the payload.
fresh; plan repo "$(taken "$PSHA")"; run "$PF" "$URL" partial --head
[ "$rc" = 0 ] && [ "$(sha "$STUB/repo.1.sent")" = "$PSHA" ] && [ "$(seq_)" = "repo payload " ] \
  && ok "PP12 partial twice: the same bytes, and a 409 snapshot_taken with that digest sends the payload" || fail "PP12 determinism: rc $rc $(seq_) $out"
# PP13: the dry run packs the same list and prints the same line, with no request.
fresh; run "$PF" --dry-run partial --head
[ "$rc" = 0 ] && [ "$(calls)" = 0 ] && [ "$(printf '%s\n' "$out" | grep '^OhMyBug upload')" = "$PLINE" ] \
  && ok "PP13 --dry-run partial: the upload's manifest line, no request" || fail "PP13 dry run: rc $rc calls $(calls) [$out] want [$PLINE]"
# PP3/PP5: the list fails (a stand-in that exits 2): the whole copy, unmarked, the reason named, exit 0.
FP="$ROOT/fakepaths"; mkdir -p "$FP"; cp "$UP" "$G/omb_scan.py" "$FP/"; printf 'import sys\nsys.stderr.write("first\\nboom\\033 here\\n")\nraise SystemExit(2)\n' > "$FP/omb_paths.py"
fresh; out=$(cd "$PF" && PATH="$BIN:$PATH" "$TSH" "$FP/omb-upload.sh" "$URL" partial --head 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(tarnames | wc -l | tr -d ' ')" = 6 ] && grep -q "^CURL repo $URL/repo\$" "$STUB/transcript" \
  && printf '%s' "$out" | grep -q 'A partial copy was asked for and not built (the file list could not be built: boom  here), so the whole working copy goes' \
  && ok "PP3/PP5 a list that fails: the whole copy, no mark, the reason in the manifest, exit 0" || fail "PP3/PP5 list failure: rc $rc $(cat "$STUB/transcript") $out"
# PP4: a diff of deletions only: no changed file is in the tree, so the whole copy.
g -C "$PF" add -A; g -C "$PF" commit -qm two; git -C "$PF" rm -q lib/other.py
fresh; run "$PF" "$URL" partial --head
[ "$rc" = 0 ] && [ "$(tarnames | wc -l | tr -d ' ')" = 5 ] && grep -q "^CURL repo $URL/repo\$" "$STUB/transcript" \
  && printf '%s' "$out" | grep -q 'not built (no changed file is in the working copy)' \
  && ok "PP4 deletions only: the whole copy, no mark, the reason named" || fail "PP4 deletions: rc $rc $(cat "$STUB/transcript") $out"
g -C "$PF" reset -q --hard
# PP6: --all, and a folder without git: the whole copy, no mark.
fresh; run "$PF" "$URL" partial --all
[ "$rc" = 0 ] && grep -q "^CURL repo $URL/repo\$" "$STUB/transcript" && printf '%s' "$out" | grep -q 'not built (all of it is new code)' \
  && ok "PP6 --all partial: the whole copy, no mark" || fail "PP6 --all: rc $rc $(cat "$STUB/transcript") $out"
fresh; run "$NGT" "$URL" partial --all
[ "$rc" = 0 ] && grep -q "^CURL repo $URL/repo\$" "$STUB/transcript" && printf '%s' "$out" | grep -q 'folder without git' \
  && ok "PP6 a folder without git, partial: the whole copy, no mark" || fail "PP6 no git: rc $rc $(cat "$STUB/transcript") $out"
# PP7: user and environment settings that would change grep's or git's output
# reach no list call: the same snapshot bytes as the clean run.
printf 'def compute():\n    return part_helper_name(7)\n' > "$PF/src/core.py"
fresh; run "$PF" "$URL" partial --head; P7A=$(sha "$STUB/repo.1.sent")
HG="$ROOT/p7global"; cp "$GIT_CONFIG_GLOBAL" "$HG"
for kv in grep.lineNumber=true grep.column=true grep.fullName=true grep.patternType=perl core.quotePath=false diff.noprefix=true; do git config --file "$HG" "${kv%%=*}" "${kv#*=}"; done
printf 'lib/use.py binary\n' > "$PF/.git/info/attributes"
fresh; out=$(cd "$PF" && GIT_CONFIG_GLOBAL="$HG" GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=grep.lineNumber GIT_CONFIG_VALUE_0=true PATH="$BIN:$PATH" "$TSH" "$UP" "$URL" partial --head 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(sha "$STUB/repo.1.sent")" = "$P7A" ] && [ "$(tarnames)" = "$PWANT" ] \
  && ok "PP7 grep and diff settings (user, environment, attributes): the same list and bytes" || fail "PP7 settings: rc $rc [$(tarnames | tr '\n' ' ')] $out"
rm -f "$PF/.git/info/attributes"
# L7 through the script: a tree past the line names the cut in the manifest.
fresh; out=$(cd "$PF" && OMB_TEST_MODE=1 OMB_TEST_PATHS_LIMITS="3 1000000000" PATH="$BIN:$PATH" "$TSH" "$UP" "$URL" partial --head 2>&1); rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q '1 build manifest, files that use the changed names not searched (more than 200,000 files))' \
  && [ "$(tarnames)" = "$(want_names src/core.py package.json)" ] && grep -q "^CURL repo $URL/repo?pack=partial\$" "$STUB/transcript" \
  && ok "L7m past the line: head and manifests only, still partial, the manifest says so" || fail "L7m manifest: rc $rc $out"
# PP11: a credential in a file of the list: left out, the list built again on
# the second pack, named in the manifest; the copy sent scans clean.
printf 'part_helper_name(3)\nk = "%s"\n' "$AWS" > "$PF/lib/use2.py"; g -C "$PF" add -A; g -C "$PF" commit -qm leak
printf 'def compute():\n    return part_helper_name(9)\n' > "$PF/src/core.py"
fresh; run "$PF" "$URL" partial --head
[ "$rc" = 0 ] && [ "$(tarnames)" = "$(want_names src/core.py package.json lib/use.py)" ] && printf '%s' "$out" | grep -q 'credential match: lib/use2.py' \
  && grep -q "^CURL repo $URL/repo?pack=partial\$" "$STUB/transcript" && python3 -I "$G/omb_scan.py" --snapshot "$STUB/repo.1.sent" "$ROOT/hits" >/dev/null 2>&1 \
  && ok "PP11 a credential in a listed file: left out, the list built again, named, the copy sent scans clean" || fail "PP11 rescan: rc $rc [$(tarnames | tr '\n' ' ')] $out"
g -C "$PF" reset -q --hard HEAD~1
# PP11g: the second list GROWS. grow_name is in 9 files (past 8: no caller);
# a_name brings in g1, whose credential drops it; now grow_name is in 8, all
# 8 come in, and g2 holds a credential too. Every pass drops its hits; the copy
# sent holds g3..g9 and scans clean (one repack used to die here).
mkdir -p "$PF/gr"
for i in 1 2 3 4 5 6 7 8 9; do printf 'grow_name(%s)\n' "$i" > "$PF/gr/g$i.py"; done
printf 'a_name(1)\ngrow_name(1)\nk = "%s"\n' "$AWS" > "$PF/gr/g1.py"
printf 'grow_name(2)\nk = "%s"\n' "$AWS" > "$PF/gr/g2.py"
g -C "$PF" add -A; g -C "$PF" commit -qm grow
printf 'def compute():\n    return a_name(grow_name(9))\n' > "$PF/src/core.py"
fresh; run "$PF" "$URL" partial --head
[ "$rc" = 0 ] && [ "$(tarnames)" = "$(want_names src/core.py package.json gr/g3.py gr/g4.py gr/g5.py gr/g6.py gr/g7.py gr/g8.py gr/g9.py)" ] \
  && printf '%s' "$out" | grep -q 'gr/g1.py' && printf '%s' "$out" | grep -q 'gr/g2.py' \
  && python3 -I "$G/omb_scan.py" --snapshot "$STUB/repo.1.sent" "$ROOT/hits" >/dev/null 2>&1 \
  && ok "PP11g a list that grows after a drop: each pass drops its hits, the copy sent scans clean" || fail "PP11g grow: rc $rc [$(tarnames | tr '\n' ' ')] $out"
g -C "$PF" checkout -q -- src/core.py 2>/dev/null; g -C "$PF" reset -q --hard HEAD~1
# PP8: paths with a space, a quote, a leading '-', a line break and (where the
# file system allows it) bytes that are not UTF-8: the exact members.
odd="$(printf 'sp ace.py\nquo"te.py\n-dash.py\nnew\nline.py')"
PO="$ROOT/podd"; mkdir -p "$PO"; g -C "$PO" init -q; printf 'pass\n' > "$PO/m.py"; printf 'x = 1\n' > "$PO/other.py"
( cd "$PO" && printf 'odd_name_call()\n' > 'sp ace.py' && printf 'odd_name_call()\n' > 'quo"te.py' && printf 'odd_name_call()\n' > ./-dash.py && printf 'odd_name_call()\n' > "$(printf 'new\nline.py')" )
NONU=; if ( cd "$PO" && printf 'odd_name_call()\n' > "$(printf 'caf\351.py')" ) 2>/dev/null && [ -e "$PO/$(printf 'caf\351.py')" ]; then NONU=1; fi
g -C "$PO" add -A; g -C "$PO" commit -qm base; printf 'pass\nodd_name_call()\n' > "$PO/m.py"
fresh; run "$PO" "$URL" partial --head
want=$(python3 -I -c 'import sys
n = ["m.py", "sp ace.py", "quo\"te.py", "-dash.py", "new\nline.py"] + (["caf\udce9.py"] if sys.argv[1] else [])
for x in sorted(n): print(repr(x))' "$NONU")
[ "$rc" = 0 ] && [ "$(tarnames)" = "$want" ] && grep -q "^CURL repo $URL/repo?pack=partial\$" "$STUB/transcript" && ok "PP8 odd paths (space, quote, leading '-', line break$([ -n "$NONU" ] && echo ', not UTF-8')): the exact members" || fail "PP8 odd paths: rc $rc [$(tarnames)] want [$want] $out"
# PP9: a sparse checkout: a file outside the cone that uses the name is not in the working tree's index, so not in the copy.
SPS="$ROOT/sps-src"; mkdir -p "$SPS/src" "$SPS/far"; g -C "$SPS" init -q
printf 'pass\n' > "$SPS/src/a.py"; printf 'far_helper_name()\n' > "$SPS/far/b.py"; printf 'far_helper_name()\n' > "$SPS/src/c.py"
g -C "$SPS" add -A; g -C "$SPS" commit -qm one
SPP="$ROOT/sps"; g clone -q "file://$SPS" "$SPP" 2>/dev/null; g -C "$SPP" sparse-checkout init --cone 2>/dev/null; g -C "$SPP" sparse-checkout set src 2>/dev/null
printf 'pass\nfar_helper_name()\n' > "$SPP/src/a.py"
fresh; run "$SPP" "$URL" partial --head
[ "$rc" = 0 ] && [ -n "$(git -C "$SPP" ls-files -t | grep '^S far/')" ] && [ "$(tarnames)" = "$(want_names src/a.py src/c.py)" ] \
  && ok "PP9 a sparse checkout: the list never reaches outside the cone" || fail "PP9 sparse: rc $rc [$(tarnames | tr '\n' ' ')] $out"
# PP10: a blobless clone whose HEAD blobs were never fetched: still one fetch
# for the pack, and the list searches every file of the tree.
BLS="$ROOT/bl-src"; mkdir -p "$BLS"; g -C "$BLS" init -q
for i in $(seq 1 20); do printf 'v %d\n' "$i" > "$BLS/f$i.py"; done; printf 'blob_helper_name()\n' > "$BLS/f20.py"
g -C "$BLS" add -A; g -C "$BLS" commit -qm one; printf 'blob_helper_name()\n' >> "$BLS/f1.py"; g -C "$BLS" commit -qam two
g -C "$BLS" config uploadpack.allowFilter true; g -C "$BLS" config uploadpack.allowAnySHA1InWant true
g clone -q --no-checkout --filter=blob:none --upload-pack="$ROOT/p50-up" "file://$BLS" "$ROOT/bl" 2>/dev/null
g -C "$ROOT/bl" config remote.origin.uploadpack "$ROOT/p50-up"
: > "$ROOT/p50-count"; fresh; run "$ROOT/bl" "$URL" partial --commits 1
nf=$(wc -l < "$ROOT/p50-count" | tr -d ' ')
[ "$rc" = 0 ] && [ "$nf" = 2 ] && [ "$(tarnames)" = "$(want_names f1.py f20.py)" ] && grep -q "^CURL repo $URL/repo?pack=partial\$" "$STUB/transcript" \
  && ok "PP10 a blobless clone: one fetch for the diff, one for the pack, and the list finds the caller" || fail "PP10 blobless: rc $rc fetches $nf [$(tarnames | tr '\n' ' ')] $out"
# PP14: against a server that never sends pack, argv required: every byte and
# request as the plugin before the partial copy existed.
OLD="$ROOT/old"; mkdir -p "$OLD"; cp "$G/omb_scan.py" "$OLD/"
if git -C "$G" show 3186e5a:plugins/bughunter/hooks/omb-upload.sh > "$OLD/omb-upload.sh" 2>/dev/null; then
  argsof() { sed -E 's#[^ ]*/(body|hdr|payload\.json|s\.tgz)#T/\1#g' "$STUB/args"; }
  for sc in "--head" "--commits 1" "--all"; do
    fresh; out=$(cd "$PF" && PATH="$BIN:$PATH" "$TSH" "$OLD/omb-upload.sh" "$URL" required $sc 2>&1); o1=$out; s1=$(sha "$STUB/repo.1.sent"); p1=$(sha "$STUB/payload.1.sent"); q1=$(seq_); a1=$(argsof)
    fresh; run "$PF" "$URL" required $sc
    [ "$out" = "$o1" ] && [ "$(sha "$STUB/repo.1.sent")" = "$s1" ] && [ "$(sha "$STUB/payload.1.sent")" = "$p1" ] && [ "$(seq_)" = "$q1" ] && [ "$(argsof)" = "$a1" ] \
      && ok "PP14 required $sc: output, snapshot, payload and requests byte for byte as before" \
      || fail "PP14 required $sc: out $([ "$out" = "$o1" ] && echo same || echo "[$out] / [$o1]"), snapshot $([ "$(sha "$STUB/repo.1.sent")" = "$s1" ] && echo same || echo differs), payload $([ "$(sha "$STUB/payload.1.sent")" = "$p1" ] && echo same || echo differs), requests [$(seq_)] / [$q1], args $([ "$(argsof)" = "$a1" ] && echo same || echo "[$(argsof)] / [$a1]")"
  done
elif [ -n "${CI:-}" ]; then fail "PP14 the older script is not in this clone's history (CI fetches it: fetch-depth 0)"
else echo "skip PP14 (the older script is not in this clone's history)"; fi
# PP15: a secret-named file that uses the name takes no caller slot (the
# manifest counts one caller, not two); a commit whose only change is binary
# packs the whole snapshot of HEAD, and says why.
P15="$ROOT/p15"; mkdir -p "$P15"; g -C "$P15" init -q; printf 'pass\n' > "$P15/m.py"
printf 'bin_call_name()\n' > "$P15/u.py"; printf 'bin_call_name()\n' > "$P15/app_secret.py"; printf '\0a' > "$P15/data.bin"
g -C "$P15" add -A; g -C "$P15" commit -qm base; printf 'pass\nbin_call_name()\n' > "$P15/m.py"; g -C "$P15" commit -qam call
fresh; run "$P15" "$URL" partial --commits 1
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q '(1 of 1 changed, 0 build manifests, 1 file that uses the changed names)' && [ "$(tarnames)" = "$(want_names m.py u.py)" ] \
  && ok "PP15 a secret-named file is no caller" || fail "PP15 secret caller: rc $rc [$(tarnames | tr '\n' ' ')] $out"
printf '\0b' > "$P15/data.bin"; g -C "$P15" commit -qam bin
fresh; run "$P15" "$URL" partial --commits 1
[ "$rc" = 0 ] && grep -q "^CURL repo $URL/repo\$" "$STUB/transcript" \
  && printf '%s' "$out" | grep -q 'not built (every changed file is over 4 MiB, binary or a git-lfs pointer), so the whole snapshot of HEAD goes' \
  && ok "PP15 only a binary change: the whole snapshot of HEAD, the reason named" || fail "PP15 binary only: rc $rc $out"


# ---- 6b. The server's secret-file and nested-repository rules (snapshot-recipe.ts) ----
# SF: kubeconfig files and prefixed .env files leave the snapshot unless their
# name ends in a lower-case source extension; the case of the name aside.
SF="$ROOT/sf"; mkdir -p "$SF/src" "$SF/conf"; g -C "$SF" init -q
printf 'x = 1\n' > "$SF/src/a.py"; printf 'PASSWORD=hunter2\n' > "$SF/prod.env"; printf 'PASSWORD=hunter2\n' > "$SF/conf/Stage.ENV"
printf 'apiVersion: v1\n' > "$SF/conf/my-kubeconfig.yaml"; printf 'apiVersion: v1\n' > "$SF/conf/kube_config"; printf 'A=1\n' > "$SF/.env.local"
printf 'def load(): pass\n' > "$SF/src/load.env.py"; printf 'package k\n' > "$SF/src/kubeconfig_loader.go"
g -C "$SF" add -A; g -C "$SF" commit -qm base; printf 'x = 2\n' > "$SF/src/a.py"
fresh; run "$SF" "$URL" required --head
[ "$rc" = 0 ] && [ "$(names)" = "$(printf '%s\n' src/a.py src/kubeconfig_loader.go src/load.env.py | sort)" ] \
  && ok "SF secret files: prod.env, Stage.ENV, my-kubeconfig.yaml, kube_config, .env.local out; load.env.py and kubeconfig_loader.go (source) in" \
  || fail "SF secret files: rc $rc [$(names | tr '\n' ' ')]"
# NR: nested repositories. An untracked repo with a commit and one without, a
# bare one (HEAD beside a config holding a token), a gitlink, and a .gnupg
# folder: none reaches the tar, each named once on stderr with the server's
# sentence; the gitlink, unchanged, is no deletion in the diff.
NR="$ROOT/nr"; mkdir -p "$NR/src" "$NR/.gnupg"; g -C "$NR" init -q
printf 'x = 1\n' > "$NR/src/a.py"; printf 'key\n' > "$NR/.gnupg/pubring.kbx"
g -C "$NR" add src; g -C "$NR" commit -qm base
g -C "$NR" update-index --add --cacheinfo "160000,$(g -C "$NR" rev-parse HEAD),sub"; g -C "$NR" commit -qm sub
mkdir -p "$NR/sub" "$NR/nest1" "$NR/nest2" "$NR/mirror.git"; g -C "$NR/nest1" init -q; printf 'n\n' > "$NR/nest1/n.py"; g -C "$NR/nest1" add -A; g -C "$NR/nest1" commit -qm n
g -C "$NR/nest2" init -q; printf 'n\n' > "$NR/nest2/n.py"
printf 'ref: refs/heads/main\n' > "$NR/mirror.git/HEAD"; printf '[remote "o"]\n\turl = https://tok@example.invalid/r\n' > "$NR/mirror.git/config"
printf 'x = 2\n' > "$NR/src/a.py"
fresh; run "$NR" "$URL" required --head
[ "$rc" = 0 ] && [ "$(names)" = src/a.py ] && [ "$(printf '%s' "$out" | grep -c 'left out nested repositories and submodules (to hunt a working repository among them, submit it on its own, from inside it):')" = 1 ] \
  && printf '%s' "$out" | grep -qx '  nest1' && printf '%s' "$out" | grep -qx '  nest2' && printf '%s' "$out" | grep -qx '  mirror.git' && printf '%s' "$out" | grep -qx '  sub' \
  && ! grep -q 'sub' "$STUB/payload.1.sent" \
  && ok "NR nested repos (with and without commits, bare, gitlink) and .gnupg out of the tar, named once; the gitlink is no deletion in the diff" \
  || fail "NR nested: rc $rc [$(names | tr '\n' ' ')] $out"
# NE: nothing left once secret-named files and nested repositories are out
# (top-level .gitignore alone does not count): the server's sentence, exit 1,
# no snapshot sent.
NE="$ROOT/ne"; mkdir -p "$NE/inner"; g -C "$NE" init -q; printf '*.log\n' > "$NE/.gitignore"; printf 'A=1\n' > "$NE/.env"
g -C "$NE/inner" init -q; printf 'i\n' > "$NE/inner/i.py"
fresh; run "$NE" "$URL" required --all
[ "$rc" = 1 ] && ! grep -q '^CURL repo' "$STUB/transcript" && printf '%s' "$out" | grep -q '^nothing to pack: this folder has no files after ignored, secret-named and nested-repository paths are left out' \
  && ok "NE nothing left to pack: the server's sentence, exit 1, nothing sent" || fail "NE empty: rc $rc $out"
# NG: a folder without git: a nested repository in it is named and left out.
NG="$ROOT/ng"; mkdir -p "$NG/inner"; printf 'x = 1\n' > "$NG/a.py"; g -C "$NG/inner" init -q; printf 'i\n' > "$NG/inner/i.py"; g -C "$NG/inner" add -A; g -C "$NG/inner" commit -qm i
fresh; run "$NG" "$URL" required --all
[ "$rc" = 0 ] && [ "$(names)" = a.py ] && printf '%s' "$out" | grep -qx '  inner' && ok "NG folder without git: the nested repository named and left out" || fail "NG no-git nested: rc $rc [$(names | tr '\n' ' ')] $out"
# The archive's pathspec list ends in the server's spare repeat of its first secret exclude.
grep -q "set -- \"\$@\" ':(exclude,icase,glob)\*\*/.env\*'" "$UP" && ok "the archive list ends in the spare .env* exclude" || fail "no spare exclude"

# ---- 7. URL and arguments ------------------------------------------------------
for bad in "https://evil.example/u/tok" "http://mcp.ohmybug.ai/u/tok" "https://mcp.ohmybug.ai/u/x; touch $ROOT/pwned" "https://mcp.ohmybug.ai/u/" "https://mcp.ohmybug.ai.evil/u/tok" "https://mcp.ohmybug.ai/u/a/../b"; do
  fresh; run "$R" "$bad" required "$P"
  [ "$rc" = 1 ] && [ "$(calls)" = 0 ] && ok "refused before anything runs: $bad" || fail "URL $bad: rc $rc calls $(calls)"
done
[ -e "$ROOT/pwned" ] && fail "a URL was evaluated"
for m in maybe Partial Required ''; do
  fresh; run "$R" "$URL" "$m" "$P"
  [ "$rc" = 1 ] && [ "$(calls)" = 0 ] && ! grep -q '^OhMyBug upload' "$STUB/transcript" && ok "dispatch: argv[2] '$m' refuses before anything" || fail "dispatch $m: rc $rc calls $(calls)"
done
# argv[2] is read once, at the dispatch, which sets snap; no mode variable is left to read it again.
[ "$(grep -c 'case \$2 in' "$UP")" = 1 ] && ! grep -qE '\$\{?mode\b' "$UP" && ok "dispatch: argv[2] is read at one place only" || fail "dispatch: argv[2] read outside the dispatch"

echo "omb-upload: $([ "$fails" = 0 ] && echo ok || echo "$fails failing")"
[ "$fails" = 0 ]
