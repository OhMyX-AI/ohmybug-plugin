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
f= m=POST
while [ $# -gt 0 ]; do
  case $1 in -o) o=$2; shift ;; -D) h=$2; shift ;; -X) m=$2; shift ;; -H|-w|--connect-timeout) shift ;; --data-binary) f=${2#@}; shift ;; -*) ;; *) u=$1 ;; esac
  shift
done
case $m:$u in DELETE:*) door=delete ;; POST:*/repo) door=repo ;; POST:*) door=payload ;; *) door=other ;; esac
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
patch_in() { printf 'diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1,2 @@\n a\n+%s\n' "$2" > "$1"; }

export HOME="$ROOT/home"; mkdir -p "$HOME"; HOME=$(cd "$HOME" && pwd -P)
SMUDGED="$ROOT/smudged"
export GIT_CONFIG_GLOBAL="$ROOT/gitconfig"
# No system config either: a CI image that sets safe.directory = * there would
# turn the ownership row below into a pass for the wrong repository.
export GIT_CONFIG_NOSYSTEM=1
printf '[filter "marker"]\n\tsmudge = touch %s; cat\n\tclean = cat\n' "$SMUDGED" > "$GIT_CONFIG_GLOBAL"

# ---- 1. Secret-list parity --------------------------------------------------
# Written out here, not read from anywhere: dropping a name from the script,
# the skill or the server's list must redden this row. This is the server's
# snapshot secret list, name for name.
SERVER='.env* *secret* *credential* id_rsa* id_dsa* id_ecdsa* id_ed25519* *.pem *.key *.p12 *.pfx .npmrc .netrc .pgpass .pypirc .git-credentials *.tfstate* *.tfvars* kubeconfig .kube .docker *.ppk *.jks *.keystore .ssh .aws .gnupg'
script=$(python3 - "$UP" <<'PY'
import re, sys
m = re.search(r"^OMB_SECRETS='(.*?)'", open(sys.argv[1]).read(), re.S | re.M)
print(" ".join(m.group(1).split()) if m else "")
PY
)
skill=$(python3 - "$G/../skills/bughunter/SKILL.md" <<'PY'
import re, sys
m = re.search(r"OMB_SECRETS=\((.*?)\)", open(sys.argv[1]).read(), re.S)
print(" ".join(re.findall(r"'([^']*)'", m.group(1))) if m else "")
PY
)
[ "$script" = "$SERVER" ] && ok "the script's secret list is the server's" || fail "secret list: script has [$script]"
[ "$skill" = "$SERVER" ] && ok "the skill's OMB_SECRETS is the server's" || fail "secret list: SKILL.md has [$skill]"

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
P="$ROOT/p.patch"; patch_in "$P" b

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
fresh; run "$R" "$URL" required "$P"
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

R="$ROOT/nogit"; mkdir -p "$R"
printf 'print(1)\n' > "$R/main.py"; printf 'CIPHERTEXT\n' > "$R/cipher.txt"; printf 'k\n' > "$R/server.KEY"; printf 'x\n' > "$R/.npmrc"
for x in __pycache__ venv target dist build node_modules/dep src/build .aws .config .cache/sub; do mkdir -p "$R/$x"; printf 'x\n' > "$R/$x/f"; done
NT="$ROOT/nogit-tmp"; mkdir -p "$NT"
fresh; out=$(cd "$R" && TMPDIR="$NT" PATH="$BIN:$PATH" "$TSH" "$UP" "$URL" required "$P" 2>&1); rc=$?
n=$(names | tr '\n' ' ')
[ "$n" = "cipher.txt main.py src/build/f " ] && [ "$rc" = 0 ] && ok "pack: a folder without git, with its extra exclusions" || fail "pack: no git: got [$n] rc $rc $out"
[ -z "$(ls -A "$NT")" ] && ok "pack: the no-git form leaves no git directory behind" || fail "pack: left behind in TMPDIR: $(ls -A "$NT")"
[ -e "$R/.git" ] && fail "pack: the no-git form created a .git in the folder"
printf '%s' "$out" | grep -q 'folder without git' && ok "manifest: the no-git variant" || fail "manifest: no no-git note: $out"

# Refusals: nothing reaches the door.
refused() { # name, dir, HOME, want text, [env]
  fresh; out=$(cd "$2" && env HOME="$3" ${5:-} PATH="$BIN:$PATH" "$TSH" "$UP" "$URL" required "$P" 2>&1); rc=$?
  if [ "$rc" != 0 ] && [ "$(calls)" = 0 ] && printf '%s' "$out" | grep -q "$4"; then ok "$1"; else fail "$1: rc $rc, calls $(calls): $out"; fi
}
H2="$ROOT/home2"; mkdir -p "$H2/u"; printf 'x\n' > "$H2/a.py"
refused "no git: a folder above the home folder is refused" "$H2" "$H2/u" "refusing to pack"
refused "no git: the home folder is refused" "$H2" "$H2" "refusing to pack"
R="$ROOT/fx2"; fixture "$R" 1
refused "an empty HOME is refused, naming that cause" "$R" "" "HOME is not set"
refused "a HOME that cannot be entered is refused" "$R" "$R/no-such-home" "HOME is not set"
H3="$ROOT/dot"; mkdir -p "$H3/proj"; g -C "$H3" init -q; printf 'x\n' > "$H3/proj/a.ts"
refused "a dotfiles repository holding the home folder is refused" "$H3/proj" "$H3" "refusing to pack"
H4="$ROOT/ctr"; mkdir -p "$H4"; printf 'print(1)\n' > "$H4/main.py"
refused "a project that is the home folder names the opt-in" "$H4" "$H4" "OMB_SNAPSHOT_HOME_OK=1"
fresh; out=$(cd "$H4" && HOME="$H4" OMB_SNAPSHOT_HOME_OK=1 PATH="$BIN:$PATH" "$TSH" "$UP" "$URL" required "$P" 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(calls)" = 2 ] && ok "OMB_SNAPSHOT_HOME_OK=1 lets the home-folder project through" || fail "home opt-in: rc $rc $out"

# ---- 4. Scan before any POST -----------------------------------------------
R="$ROOT/scan"; mkdir -p "$R"; g -C "$R" init -q; printf 'a\n' > "$R/a.txt"; g -C "$R" add -A; g -C "$R" commit -qm one
KP="$ROOT/key.patch"; patch_in "$KP" "k = \"$AWS\""
fresh; run "$R" "$URL" required "$KP"
[ "$rc" = 3 ] && [ "$(calls)" = 0 ] && ok "a key in the diff refuses before any POST" || fail "key in diff: rc $rc calls $(calls) $out"
printf '%s' "$out" | grep -qF "$AWS" && fail "the full key reached the output"
printf '%s' "$out" | grep -q 'AWS access key' && ok "the refusal names the shape, masked" || fail "key in diff: no masked hit: $out"
printf 'k = "%s"\n' "$AWS" > "$ROOT/ctx.txt"; cp "$ROOT/ctx.txt" "$R/ctx.txt"
fresh; run "$R" "$URL" off "$P" ctx.txt
[ "$rc" = 3 ] && [ "$(calls)" = 0 ] && ok "a key in a context file refuses before any POST" || fail "key in context: rc $rc calls $(calls) $out"
rm -f "$R/ctx.txt"
mkdir -p "$R/conf"; printf 'k = "%s"\n' "$AWS" > "$R/conf/leak.yml"; printf 'fine\n' > "$R/conf/ok.yml"
fresh; run "$R" "$URL" required "$P"
n=$(names | tr '\n' ' ')
if [ "$rc" = 0 ] && [ "$(calls)" = 2 ] && [ "$n" = "a.txt conf/ok.yml " ]; then ok "a key in a snapshot file leaves that file out, and the hunt goes on"
else fail "key in snapshot: rc $rc [$n] $out"; fi
printf '%s' "$out" | grep -q 'credential match: conf/leak.yml' && ok "manifest: the left-out file is named" || fail "manifest: leak.yml not named: $out"
python3 -I "$G/omb_scan.py" --snapshot "$STUB/repo.1.sent" "$ROOT/hits" >/dev/null 2>&1 && ok "the snapshot sent is the one scanned clean" || fail "the snapshot sent does not scan clean"
# Two dropped files are two names; a control byte inside a name becomes "?", and the manifest stays one line.
cp "$R/conf/leak.yml" "$R/conf/$(printf 'two,x\033.yml')"
fresh; run "$R" "$URL" required "$P"
first=$(grep '^OhMyBug upload' "$STUB/transcript")
case $first in *'credential match: conf/leak.yml, conf/two,x?.yml.') [ "$(names | tr '\n' ' ')" = "a.txt conf/ok.yml " ] && ok "manifest: two left-out files are two names, a comma in a name kept, control bytes replaced" || fail "two drops: packed [$(names | tr '\n' ' ')]" ;; *) fail "two drops glued or split: $first" ;; esac
rm -f "$R/conf/$(printf 'two,x\033.yml')"
fresh; out=$(cd "$R" && OHMYBUG_SECRET_SCAN=0 PATH="$BIN:$PATH" "$TSH" "$UP" "$URL" required "$KP" 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(calls)" = 2 ] && printf '%s' "$out" | grep -q 'Credential scan: off (OHMYBUG_SECRET_SCAN=0)' && ok "OHMYBUG_SECRET_SCAN=0: sent, and the manifest says scan off" || fail "scan off: rc $rc $out"
tar -tzf "$STUB/repo.1.sent" | grep -qx conf/leak.yml && ok "scan off: nothing is dropped either" || fail "scan off: leak.yml dropped"
rm -rf "$R/conf"
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
for v in 2 3 still; do
  cat > "$FS/omb_scan.py" <<PY
import sys
if sys.argv[1] == "--payload": sys.exit(0)
if "$v" == "still":
    open(sys.argv[3], "wb").write(b"a.txt\0")
    sys.exit(3)
sys.exit(int("$v"))
PY
  fresh; out=$(cd "$R" && PATH="$BIN:$PATH" "$TSH" "$FS/omb-upload.sh" "$URL" required "$P" 2>&1); rc=$?
  [ "$rc" = 1 ] && [ "$(calls)" = 0 ] && ok "a snapshot scan that ends '$v' sends nothing" || fail "snapshot scan $v: rc $rc calls $(calls) $out"
done
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
for m in json hashlib; do printf 'open("%s", "w").close()\nraise SystemExit(9)\n' "$ROOT/imported" > "$R/$m.py"; done
fresh; run "$R" "$URL" required "$P"; mine=$(sha "$STUB/repo.1.sent")
fresh; plan repo "409|{\"code\":\"snapshot_taken\",\"sha256\":\"$mine\"}|"; run "$R" "$URL" required "$P"
[ "$rc" = 0 ] && [ "$(seq_)" = "repo payload " ] && [ ! -e "$ROOT/imported" ] && ok "a json.py or hashlib.py in the repository is not imported (builder, digest, answer reader)" || fail "repo json.py: rc $rc calls $(seq_) imported=$([ -e "$ROOT/imported" ] && echo yes || echo no) $out"
rm -f "$R/json.py" "$R/hashlib.py" "$ROOT/imported"

# ---- 5. Order, bytes, the private directory --------------------------------
fresh; run "$R" "$URL" required "$P"
[ "$(grep '^CURL' "$STUB/transcript" | cut -d' ' -f2 | tr '\n' ' ')" = "repo payload " ] && ok "the snapshot goes first, then the payload" || fail "order: $(cat "$STUB/transcript")"
grep -q "^CURL repo $URL/repo\$" "$STUB/transcript" && grep -q "^CURL payload $URL\$" "$STUB/transcript" && ok "the doors are <upload_url>/repo and <upload_url>" || fail "doors: $(cat "$STUB/transcript")"
head -n 1 "$STUB/transcript" | grep -q '^OhMyBug upload → mcp.ohmybug.ai: diff ' && ok "the manifest is printed before the first POST" || fail "manifest order: $(cat "$STUB/transcript")"
python3 - "$STUB/payload.1.sent" "$P" <<'PY' && ok "the payload carries the diff, no context files with a snapshot" || fail "payload bytes"
import json, sys
p = json.load(open(sys.argv[1]))
sys.exit(0 if p == {"diff": open(sys.argv[2]).read(), "files": []} else 1)
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
EP="$ROOT/empty.patch"; : > "$EP"
fresh; run "$R" "$URL" required "$EP"
[ "$rc" = 1 ] && [ "$(calls)" = 0 ] && ok "an empty diff refuses" || fail "empty diff: rc $rc"

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
fresh; out=$(cd "$NG" && PATH="$GB:$BIN:$PATH" "$TSH" "$UP" "$URL" required "$P" 2>&1); rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'folder without git' && ok "the no-git probe is locale-proof" || fail "no-git probe locale: rc $rc $out"
# CRLF and a lone CR survive; a diff that is not UTF-8 refuses, naming its file.
printf 'diff --git a/w.bat b/w.bat\n--- a/w.bat\n+++ b/w.bat\n@@ -1 +1,3 @@\n a\r\n+b\r\n+c\rd\n' > "$ROOT/crlf.patch"
fresh; run "$R" "$URL" required "$ROOT/crlf.patch"
python3 - "$STUB/payload.1.sent" "$ROOT/crlf.patch" <<'PY' && ok "CRLF and a lone CR reach the payload unchanged" || fail "CRLF: $out"
import json, sys
sys.exit(0 if json.load(open(sys.argv[1], encoding="utf-8"))["diff"].encode() == open(sys.argv[2], "rb").read() else 1)
PY
printf 'diff --git a/ok.py b/ok.py\n--- a/ok.py\n+++ b/ok.py\n@@ -1 +1 @@\n+x\ndiff --git a/latin.txt b/latin.txt\n--- a/latin.txt\n+++ b/latin.txt\n@@ -1 +1 @@\n+caf\351\n' > "$ROOT/latin.patch"
fresh; run "$R" "$URL" required "$ROOT/latin.patch"
python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1]))["diff"]; sys.exit(0 if "ok.py" in d and "latin" not in d else 1)' "$STUB/payload.1.sent" 2>/dev/null \
  && [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'Left out of the diff as not UTF-8 text: latin.txt' && printf '%s' "$out" | grep -q '(1 file)' && ok "a file whose diff is not UTF-8 is left out and named; the rest goes" || fail "non-UTF-8 diff: rc $rc $out"
# Secret-named files are out of the diff as they are out of the snapshot, and named.
printf 'diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n+ok\ndiff --git a/.env.local b/.env.local\nnew file mode 100644\n--- /dev/null\n+++ b/.env.local\n@@ -0,0 +1 @@\n+PORT=1\ndiff --git a/config/Secrets/db.yml b/config/Secrets/db.yml\n--- a/config/Secrets/db.yml\n+++ b/config/Secrets/db.yml\n@@ -1 +1 @@\n+x\ndiff --git "a/k\\303\\251y.PEM" "b/k\\303\\251y.PEM"\n--- "a/k\\303\\251y.PEM"\n+++ "b/k\\303\\251y.PEM"\n@@ -1 +1 @@\n+y\n' > "$ROOT/sec.patch"
fresh; run "$R" "$URL" required "$ROOT/sec.patch"
python3 - "$STUB/payload.1.sent" <<'PY' && ok "secret-named files are left out of the diff" || fail "diff secret names: $(cat "$STUB/payload.1.sent" 2>/dev/null) $out"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))["diff"]
sys.exit(0 if "a/a.txt" in d and ".env" not in d and "Secrets" not in d and "PEM" not in d else 1)
PY
printf '%s' "$out" | grep -q 'Left out of the diff as secret-named: .env.local, config/Secrets/db.yml, kéy.PEM' && printf '%s' "$out" | grep -q '(1 file)' && ok "manifest: the left-out diff files are named" || fail "manifest diff secrets: $out"
# Context files: a folder linked from ABOVE the repository is fine, a link inside it is not;
# a file that is not UTF-8 is left out and named; none go with a snapshot.
printf 'ctx\n' > "$R/c.txt"; printf 'caf\351\n' > "$R/latin.txt"; ln -s "$ROOT" "$ROOT/viaroot"
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
rm -f "$R/c.txt" "$R/latin.txt" "$ROOT/viaroot"
# The masked hits of a snapshot file are shown, not discarded.
mkdir -p "$R/conf"; printf 'k = "%s"\n' "$AWS" > "$R/conf/leak.yml"
fresh; run "$R" "$URL" required "$P"
printf '%s' "$out" | grep -q 'conf/leak.yml:1 AWS access key (AKIA...GH)' && ok "the snapshot's masked hits are shown" || fail "snapshot hits hidden: $out"
rm -rf "$R/conf"

# ---- 5c. Diff names, old python, secret-named context, signals ------------
# Inside a hunk, "--- x" is a removed "-- x" line and "+++ x" an added "++ x":
# never a file name. A mode-only change has no ---/+++ lines: its name comes
# from the diff --git header alone.
printf 'diff --git a/db.sql b/db.sql\n--- a/db.sql\n+++ b/db.sql\n@@ -1,2 +1,2 @@\n--- secret table\n+++ credentials below\n x\ndiff --git a/.env b/.env\nold mode 100644\nnew mode 100755\n' > "$ROOT/sql.patch"
fresh; run "$R" "$URL" required "$ROOT/sql.patch"
python3 - "$STUB/payload.1.sent" <<'PY' && printf '%s' "$out" | grep -q 'secret-named: .env\.' && ok "hunk lines are not file names; a mode-only secret-named file is still left out" || fail "hunk names: $out"
import json, sys
d = json.load(open(sys.argv[1]))["diff"]
sys.exit(0 if "--- secret table" in d and "a/.env" not in d else 1)
PY
# A quoted name with control bytes: replaced in the manifest, which stays one true line.
printf 'diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n+ok\ndiff --git "a/.env\\nX\\033Y" "b/.env\\nX\\033Y"\n--- "a/.env\\nX\\033Y"\n+++ "b/.env\\nX\\033Y"\n@@ -1 +1 @@\n+z\n' > "$ROOT/ctl.patch"
fresh; run "$R" "$URL" required "$ROOT/ctl.patch"
first=$(head -n 1 "$STUB/transcript")
case $first in *'secret-named: .env?X?Y.'*'Credential scan'*) ok "control bytes in a name are replaced; the manifest is one line" ;; *) fail "control bytes: $first" ;; esac
printf '%s' "$first" | grep -q 'diff 1 KB (1 file)' && ok "...and its numbers are not shifted" || fail "shifted manifest: $first"
# python3 older than 3.7 refuses in one sentence.
OP="$ROOT/oldpy"; mkdir -p "$OP"
printf '#!/bin/sh\ncase "$*" in *"version_info < (3, 7)"*) exit 1 ;; esac\nexec %s "$@"\n' "$(command -v python3)" > "$OP/python3"; chmod +x "$OP/python3"
fresh; out=$(cd "$R" && PATH="$OP:$BIN:$PATH" "$TSH" "$UP" "$URL" required "$P" 2>&1); rc=$?
[ "$rc" = 4 ] && [ "$(calls)" = 0 ] && [ "$out" = "omb-upload: python3 3.7 or newer is needed; nothing was sent" ] && ok "python3 older than 3.7: one sentence, exit 4" || fail "old python: rc $rc $out"
# A secret-named context file is never sent, even when git lists it.
printf 'registry=x\n' > "$R/.npmrc"; git -C "$R" add -f .npmrc; printf 'fine\n' > "$R/c.txt"
fresh; run "$R" "$URL" off "$P" .npmrc c.txt
python3 - "$STUB/payload.1.sent" <<'PY' && printf '%s' "$out" | grep -q 'Not sent.*\.npmrc' && ok "a secret-named context file is left out and named" || fail "secret context: $out"
import json, sys
sys.exit(0 if [f["path"] for f in json.load(open(sys.argv[1]))["files"]] == ["c.txt"] else 1)
PY
grep -q "^0o700 0o600 " "$STUB/modes" && ok "the payload file is readable by its owner only" || fail "payload mode: $(cat "$STUB/modes")"
git -C "$R" rm -q --cached .npmrc; rm -f "$R/.npmrc" "$R/c.txt"
# The payload scan that cannot run refuses on its own (diff mode: no snapshot scan to fail instead).
fresh; out=$(cd "$R" && OHMYBUG_TEST_SCAN_RAISE=1 PATH="$BIN:$PATH" "$TSH" "$UP" "$URL" off "$P" 2>&1); rc=$?
[ "$rc" = 1 ] && [ "$(calls)" = 0 ] && printf '%s' "$out" | grep -q 'could not scan the payload' && ok "an unscannable payload is not sent (diff mode)" || fail "payload scan failure: rc $rc $out"
# A missing diff file: a sentence, not a traceback.
fresh; run "$R" "$URL" required "$ROOT/no-such.patch"
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'cannot read the diff file' && ok "a missing diff file is refused in one sentence" || fail "missing diff: $out"
# The pattern count is not a glob over the current folder.
printf 'k\n' > "$R/a.key"; printf 'k\n' > "$R/b.key"
fresh; run "$R" "$URL" required "$P"
printf '%s' "$out" | grep -q 'and 24 more patterns' && ok "the pattern count ignores files in the folder" || fail "pattern count: $out"
rm -f "$R/a.key" "$R/b.key"
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
  fresh; run "$R" "$URL" required "$P"
  [ "$rc" = 0 ] && ! names | grep -q caf && ok "a non-UTF-8 name that hits is dropped" || fail "non-UTF-8 name: rc $rc $out"
  rm -f "$R/$(printf 'caf\351.txt')"
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
git -C "$R" checkout -q -- a.txt
# After an edit, the old ticket's digest is a mismatch: the rerun retires, never pairs.
printf 'edit\n' >> "$R/a.txt"
st "digest: ...the same stored digest after an edit is R3" 1 "$(taken "$MINE")" '' "200|$NEXT|" required "repo delete " "Submit again"
git -C "$R" checkout -q -- a.txt

# No clock and no retry in the script, and one curl shape.
python3 -I - "$UP" <<'PY' && ok "no clock: no date, sleep, --max-time or retry in the script" || fail "no clock: the script reads a clock or retries"
import re, sys
code = "\n".join(l for l in open(sys.argv[1]).read().splitlines() if not l.lstrip().startswith("#"))
# One request per door: three call sites (snapshot, retire, payload), two curl lines in req().
sys.exit(1 if re.search(r"\$\(date\b|\bdate \+|\bsleep\b|--max-time|--retry", code)
         or len(re.findall(r"^\s*req (POST|DELETE) ", code, re.M)) != 3 or code.count("curl -sS") != 2 else 0)
PY
fresh; plan delete "200|$NEXT|"; plan repo "$(taken "$OTHER")"; run "$R" "$URL" required "$P"
grep -q -- '-X POST -H content-type: application/gzip --data-binary @.* https://mcp.ohmybug.ai/u/tok_1-A/repo$' "$STUB/args" \
  && grep -q -- '-X DELETE https://mcp.ohmybug.ai/u/tok_1-A$' "$STUB/args" && ! grep -- '-X DELETE' "$STUB/args" | grep -q content-type \
  && ok "content-type: the snapshot is application/gzip; the DELETE carries no body" || fail "content-type: $(cat "$STUB/args")"
fresh; run "$R" "$URL" required "$P"
grep -q -- '-X POST -H content-type: application/json --data-binary @.* https://mcp.ohmybug.ai/u/tok_1-A$' "$STUB/args" && ok "content-type: the payload is application/json" || fail "content-type payload: $(cat "$STUB/args")"
grep -v -- '--connect-timeout 10 --speed-limit 1 --speed-time 120 ' "$STUB/args" | grep -q . && fail "curl: a request without the connect and stall limits: $(cat "$STUB/args")" || ok "curl: every request has the 10 s connect limit and ends after 120 s with no byte moving"

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

# The secret-name filter on a plain unified diff (diff -ruN): .env is left out and named.
printf 'diff -ruN a/app.py b/app.py\n--- a/app.py\t2026-01-01 00:00:00\n+++ b/app.py\t2026-01-02 00:00:00\n@@ -1 +1,2 @@\n x\n+y\ndiff -ruN a/.env b/.env\n--- a/.env\t2026-01-01 00:00:00\n+++ b/.env\t2026-01-02 00:00:00\n@@ -0,0 +1 @@\n+K=1\n' > "$ROOT/plain.patch"
fresh; run "$R" "$URL" off "$ROOT/plain.patch"
python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1]))["diff"]; sys.exit(0 if "app.py" in d and ".env" not in d else 1)' "$STUB/payload.1.sent" 2>/dev/null \
  && [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'secret-named: .env' && ok "plain diff -ruN: .env left out and named" || fail "plain diff: rc $rc $out"
# The same without the diff lines (--- / +++ headers only), and a removed "-- x" line that is not a header.
printf -- '--- a/app.py\n+++ b/app.py\n@@ -1,2 +1 @@\n--- x\n x\n--- .env\n+++ .env\n@@ -0,0 +1 @@\n+K=1\n' > "$ROOT/bare.patch"
fresh; run "$R" "$URL" off "$ROOT/bare.patch"
python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1]))["diff"]; sys.exit(0 if "--- x" in d and "K=1" not in d else 1)' "$STUB/payload.1.sent" 2>/dev/null \
  && [ "$rc" = 0 ] && ok "headers only: .env left out, a removed '-- x' line kept as content" || fail "bare headers: rc $rc $out"
# Fail closed: a section that names no file, or a diff in colours, sends nothing.
printf 'diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-a\n+b\nSome note with no header\n+K=1\n' > "$ROOT/noname.patch"
printf 'just some text\n+K=1\n' > "$ROOT/noname2.patch"
printf '\033[1mdiff --git a/.env b/.env\033[m\n\033[1m--- a/.env\033[m\n\033[1m+++ b/.env\033[m\n\033[36m@@ -0,0 +1 @@\033[m\n\033[32m+K=1\033[m\n' > "$ROOT/color.patch"
for p in noname noname2 color; do
  fresh; run "$R" "$URL" off "$ROOT/$p.patch"
  [ "$rc" = 1 ] && [ "$(calls)" = 0 ] && printf '%s' "$out" | grep -qE 'names no file|belongs to no file|terminal colours' && ok "fail closed: $p sends nothing" || fail "fail closed $p: rc $rc calls $(calls) $out"
done
# Context files outside the repository, relative and absolute: not sent, named.
printf 'out\n' > "$ROOT/outside.txt"
fresh; run "$R" "$URL" off "$P" ../outside.txt "$ROOT/outside.txt"
python3 -I -c 'import json, sys; sys.exit(0 if json.load(open(sys.argv[1]))["files"] == [] else 1)' "$STUB/payload.1.sent" 2>/dev/null \
  && printf '%s' "$out" | grep -q "Not sent.*\.\./outside.txt, $ROOT/outside.txt" && ok "context outside the repository (relative, absolute): not sent, named" || fail "outside context: $out"
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

# ---- 7. URL and arguments ------------------------------------------------------
for bad in "https://evil.example/u/tok" "http://mcp.ohmybug.ai/u/tok" "https://mcp.ohmybug.ai/u/x; touch $ROOT/pwned" "https://mcp.ohmybug.ai/u/" "https://mcp.ohmybug.ai.evil/u/tok" "https://mcp.ohmybug.ai/u/a/../b"; do
  fresh; run "$R" "$bad" required "$P"
  [ "$rc" = 1 ] && [ "$(calls)" = 0 ] && ok "refused before anything runs: $bad" || fail "URL $bad: rc $rc calls $(calls)"
done
[ -e "$ROOT/pwned" ] && fail "a URL was evaluated"
for m in maybe partial Required ''; do
  fresh; run "$R" "$URL" "$m" "$P"
  [ "$rc" = 1 ] && [ "$(calls)" = 0 ] && ! grep -q '^OhMyBug upload' "$STUB/transcript" && ok "dispatch: argv[2] '$m' refuses before anything" || fail "dispatch $m: rc $rc calls $(calls)"
done
# argv[2] is read once, at the dispatch, which sets snap; no mode variable is left to read it again.
[ "$(grep -c 'case \$2 in' "$UP")" = 1 ] && ! grep -qE '\$\{?mode\b' "$UP" && ok "dispatch: argv[2] is read at one place only" || fail "dispatch: argv[2] read outside the dispatch"

echo "omb-upload: $([ "$fails" = 0 ] && echo ok || echo "$fails failing")"
[ "$fails" = 0 ]
