#!/bin/bash
# Run me after touching omb-upload.sh: `hooks/omb-upload-test.sh`
#
# The upload script runs here for real: real git, a real snapshot, the real
# secret scan. Only curl (and sleep) are stubs on PATH: the stub stores each
# body it is sent and answers from a per-door plan, so every row can say what
# left the machine, in which order, and what the script did with each answer.
# Keys are glued together at run time, as in secret-scan-test.sh.
set -u
G=$(cd "$(dirname "$0")" && pwd)
UP="$G/../skills/bughunter/omb-upload.sh"
export PYTHONDONTWRITEBYTECODE=1
ROOT=$(mktemp -d)
trap 'chmod -R u+rwx "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT
fails=0
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
ok() { echo "ok   $*"; }
URL=https://mcp.ohmybug.ai/u/tok_1-A
AWS="AKIA""QWERTYUIOPASDFGH"

# The stub. Plan lines per door: "<code>|<body>|<retry-after>"; past the plan, 200.
BIN="$ROOT/bin"; mkdir -p "$BIN"
cat > "$BIN/curl" <<'SH'
#!/bin/sh
echo "$*" >> "$STUB/args"
while [ $# -gt 0 ]; do
  case $1 in -o) o=$2; shift ;; -D) h=$2; shift ;; --data-binary) f=${2#@}; shift ;; -*) ;; *) u=$1 ;; esac
  shift
done
case $u in */repo) door=repo ;; *) door=payload ;; esac
n=$(cat "$STUB/$door.n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STUB/$door.n"
line=$(sed -n "${n}p" "$STUB/$door.plan" 2>/dev/null)
[ -n "$line" ] || line='200|{"ok":true}|'
code=${line%%|*}; rest=${line#*|}; body=${rest%|*}; ra=${rest##*|}
echo "CURL $door $u" >> "$STUB/transcript"
python3 - "$f" >> "$STUB/modes" <<'PY'
import os, stat, sys
f = sys.argv[1]
print(oct(stat.S_IMODE(os.stat(os.path.dirname(f)).st_mode)), oct(stat.S_IMODE(os.stat(f).st_mode)), os.path.dirname(f))
PY
cp "$f" "$STUB/$door.$n.sent"
# A connection that never answered writes no body and no headers.
if [ "$code" = 000 ]; then rm -f "$o" "$h"; printf 000; exit 7; fi
printf '%s' "$body" > "$o"
{ printf 'HTTP/1.1 %s X\r\n' "$code"; [ -n "$ra" ] && printf 'Retry-After: %s\r\n' "$ra"; } > "$h"
printf '%s' "$code"
exit 0
SH
printf '#!/bin/sh\necho "$1" >> "$STUB/sleeps"\n' > "$BIN/sleep"
chmod +x "$BIN/curl" "$BIN/sleep"

g() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }
fresh() { STUB=$(mktemp -d "$ROOT/stub.XXXX"); export STUB; : > "$STUB/transcript"; }
plan() { printf '%s\n' "$2" > "$STUB/$1.plan"; }
# run <dir> <args...>: rc in $rc, stdout+stderr in $out (stdout also in the transcript)
run() {
  local dir=$1; shift
  out=$(cd "$dir" && PATH="$BIN:$PATH" sh "$UP" "$@" 2>"$STUB/err" | tee -a "$STUB/transcript"; exit "${PIPESTATUS[0]}")
  rc=$?
  out="$out$(cat "$STUB/err")"
}
calls() { grep -c '^CURL' "$STUB/transcript" 2>/dev/null || :; }
names() { tar -tzf "$STUB/repo.1.sent" 2>/dev/null | grep -v '/$' | sort; }
want_rc() { [ "$rc" = "$2" ] && ok "$1" || fail "$1: exit $rc, want $2: $out"; }
patch_in() { printf 'diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1,2 @@\n a\n+%s\n' "$2" > "$1"; }

export HOME="$ROOT/home"; mkdir -p "$HOME"; HOME=$(cd "$HOME" && pwd -P)
SMUDGED="$ROOT/smudged"
export GIT_CONFIG_GLOBAL="$ROOT/gitconfig"
printf '[filter "marker"]\n\tsmudge = touch %s; cat\n\tclean = cat\n' "$SMUDGED" > "$GIT_CONFIG_GLOBAL"

# ---- 1. Secret-list parity --------------------------------------------------
# Written out here, not read from anywhere: dropping a name from the script,
# the skill or the server's list must redden this row. This is the server's
# SNAPSHOT_SECRETS, name for name.
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

# ---- 2. Pack: the server's snapshot-recipe cases, ported ------------------
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
fresh; out=$(cd "$R" && TMPDIR="$NT" PATH="$BIN:$PATH" sh "$UP" "$URL" required "$P" 2>&1); rc=$?
n=$(names | tr '\n' ' ')
[ "$n" = "cipher.txt main.py src/build/f " ] && [ "$rc" = 0 ] && ok "pack: a folder without git, with its extra exclusions" || fail "pack: no git: got [$n] rc $rc $out"
[ -z "$(ls -A "$NT")" ] && ok "pack: the no-git form leaves no git directory behind" || fail "pack: left behind in TMPDIR: $(ls -A "$NT")"
[ -e "$R/.git" ] && fail "pack: the no-git form created a .git in the folder"
printf '%s' "$out" | grep -q 'folder without git' && ok "manifest: the no-git variant" || fail "manifest: no no-git note: $out"

# Refusals: nothing reaches the door.
refused() { # name, dir, HOME, want text, [env]
  fresh; out=$(cd "$2" && env HOME="$3" ${5:-} PATH="$BIN:$PATH" sh "$UP" "$URL" required "$P" 2>&1); rc=$?
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
fresh; out=$(cd "$H4" && HOME="$H4" OMB_SNAPSHOT_HOME_OK=1 PATH="$BIN:$PATH" sh "$UP" "$URL" required "$P" 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(calls)" = 2 ] && ok "OMB_SNAPSHOT_HOME_OK=1 lets the home-folder project through" || fail "home opt-in: rc $rc $out"

# ---- 3. Path list ----------------------------------------------------------
R="$ROOT/fx3"; fixture "$R" 1
printf 'src/deep/a.ts\n.env.production\nsec2\n' > "$ROOT/paths"
fresh; out=$(cd "$R" && OMB_SNAPSHOT_PATHS="$ROOT/paths" PATH="$BIN:$PATH" sh "$UP" "$URL" required "$P" 2>&1); rc=$?
[ "$(names | tr '\n' ' ')" = "src/deep/a.ts " ] && ok "path list: only the listed files, a listed secret still left out" || fail "path list: got [$(names | tr '\n' ' ')] $out"
printf '%s' "$out" | grep -q 'snapshot 1 of [0-9]* files (path list)' && ok "manifest: the path-list variant" || fail "manifest: path list: $out"
: > "$ROOT/empty-paths"
fresh; out=$(cd "$R" && OMB_SNAPSHOT_PATHS="$ROOT/empty-paths" PATH="$BIN:$PATH" sh "$UP" "$URL" required "$P" 2>&1); rc=$?
[ "$rc" = 1 ] && [ "$(calls)" = 0 ] && ok "an empty path list refuses, never packs everything" || fail "empty path list: rc $rc calls $(calls)"

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
python3 "$G/../skills/bughunter/omb_scan.py" --snapshot "$STUB/repo.1.sent" "$ROOT/hits" 2>/dev/null && ok "the snapshot sent is the one scanned clean" || fail "the snapshot sent does not scan clean"
fresh; out=$(cd "$R" && OHMYBUG_SECRET_SCAN=0 PATH="$BIN:$PATH" sh "$UP" "$URL" required "$KP" 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(calls)" = 2 ] && printf '%s' "$out" | grep -q 'Credential scan: off (OHMYBUG_SECRET_SCAN=0)' && ok "OHMYBUG_SECRET_SCAN=0: sent, and the manifest says scan off" || fail "scan off: rc $rc $out"
tar -tzf "$STUB/repo.1.sent" | grep -qx conf/leak.yml && ok "scan off: nothing is dropped either" || fail "scan off: leak.yml dropped"
rm -rf "$R/conf"
# No python3: a PATH holding every tool the script needs but python3.
NP="$ROOT/nopy"; mkdir -p "$NP"
for t in git sh bash mktemp dirname rm mkdir cp xargs grep tr paste awk wc tar cat sed env; do ln -sf "$(command -v "$t")" "$NP/$t"; done
cp "$BIN/curl" "$BIN/sleep" "$NP/"
fresh; out=$(cd "$R" && PATH="$NP" sh "$UP" "$URL" required "$P" 2>&1); rc=$?
[ "$rc" = 4 ] && [ "$(calls)" = 0 ] && printf '%s' "$out" | grep -q 'python3 not found' && ok "no python3: exit 4, nothing sent" || fail "no python3: rc $rc calls $(calls) $out"
NC="$ROOT/nocurl"; mkdir -p "$NC"
for t in git sh bash mktemp dirname rm mkdir cp xargs grep tr paste awk wc tar cat sed env python3; do ln -sf "$(command -v "$t")" "$NC/$t"; done
fresh; out=$(cd "$R" && PATH="$NC" sh "$UP" "$URL" required "$P" 2>&1); rc=$?
[ "$rc" = 4 ] && printf '%s' "$out" | grep -q 'curl not found' && ok "no curl: exit 4, said once" || fail "no curl: rc $rc $out"
# An unscannable snapshot is not sent.
fresh; out=$(cd "$R" && OHMYBUG_TEST_SCAN_RAISE=1 PATH="$BIN:$PATH" sh "$UP" "$URL" required "$P" 2>&1); rc=$?
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
  fresh; out=$(cd "$R" && PATH="$BIN:$PATH" sh "$FS/omb-upload.sh" "$URL" required "$P" 2>&1); rc=$?
  [ "$rc" = 1 ] && [ "$(calls)" = 0 ] && ok "a snapshot scan that ends '$v' sends nothing" || fail "snapshot scan $v: rc $rc calls $(calls) $out"
done
# A repository git refuses to read is not packed as a folder without git.
fresh; out=$(cd "$R" && GIT_TEST_ASSUME_DIFFERENT_OWNER=1 PATH="$BIN:$PATH" sh "$UP" "$URL" required "$P" 2>&1); rc=$?
[ "$rc" = 1 ] && [ "$(calls)" = 0 ] && ok "a repository git cannot read (ownership) is refused, not packed without .gitignore" || fail "dubious ownership: rc $rc calls $(calls) $out"

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
grep -q "snapshot $packed file" "$STUB/transcript" && grep -q 'diff 1 KB (1 file)' "$STUB/transcript" && grep -q 'and 24 more patterns' "$STUB/transcript" && ok "manifest: the counts" || fail "manifest counts ($packed): $(head -n 1 "$STUB/transcript")"
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
printf 'x\n' > "$R/locked.txt"; chmod 000 "$R/locked.txt"
fresh; run "$R" "$URL" required "$P"
[ "$rc" = 1 ] && [ "$(calls)" = 0 ] && ok "a failed git add inside the pack sends nothing" || fail "pack step failure: rc $rc calls $(calls) $out"
chmod 600 "$R/locked.txt"; rm -f "$R/locked.txt"
# The no-git probe reads git in the C locale: a git that answers in another language still means "no repository".
GB="$ROOT/gitbin"; mkdir -p "$GB"
printf '#!/bin/sh\nif [ "${LC_ALL:-}" != C ] && [ "$1 $2" = "rev-parse --git-dir" ]; then echo "fatal: kein Git-Repository" >&2; exit 128; fi\nexec %s "$@"\n' "$(command -v git)" > "$GB/git"; chmod +x "$GB/git"
NG="$ROOT/nogit2"; mkdir -p "$NG"; printf 'x\n' > "$NG/main.py"
fresh; out=$(cd "$NG" && PATH="$GB:$BIN:$PATH" sh "$UP" "$URL" required "$P" 2>&1); rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'folder without git' && ok "the no-git probe is locale-proof" || fail "no-git probe locale: rc $rc $out"
# CRLF and a lone CR survive; a diff that is not UTF-8 refuses, naming its file.
printf 'diff --git a/w.bat b/w.bat\n--- a/w.bat\n+++ b/w.bat\n@@ -1 +1,2 @@\n a\r\n+b\r\n+c\rd\n' > "$ROOT/crlf.patch"
fresh; run "$R" "$URL" required "$ROOT/crlf.patch"
python3 - "$STUB/payload.1.sent" "$ROOT/crlf.patch" <<'PY' && ok "CRLF and a lone CR reach the payload unchanged" || fail "CRLF: $out"
import json, sys
sys.exit(0 if json.load(open(sys.argv[1], encoding="utf-8"))["diff"].encode() == open(sys.argv[2], "rb").read() else 1)
PY
printf 'diff --git a/ok.py b/ok.py\n--- a/ok.py\n+++ b/ok.py\n@@ -1 +1 @@\n+x\ndiff --git a/latin.txt b/latin.txt\n--- a/latin.txt\n+++ b/latin.txt\n@@ -1 +1 @@\n+caf\351\n' > "$ROOT/latin.patch"
fresh; run "$R" "$URL" required "$ROOT/latin.patch"
[ "$rc" = 1 ] && [ "$(calls)" = 0 ] && printf '%s' "$out" | grep -q 'the diff of latin.txt is not valid UTF-8' && ok "a diff that is not UTF-8 refuses, naming the file" || fail "non-UTF-8 diff: rc $rc $out"
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
# A path list written on Windows (CRLF) still matches; a path that matches nothing is named, not fatal.
printf 'a.txt\r\nno/such.txt\r\n' > "$ROOT/crpaths"
fresh; out=$(cd "$R" && OMB_SNAPSHOT_PATHS="$ROOT/crpaths" PATH="$BIN:$PATH" sh "$UP" "$URL" required "$P" 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(names | tr '\n' ' ')" = "a.txt " ] && printf '%s' "$out" | grep -q 'listed paths not in the working copy: no/such.txt' && ok "path list: CR trimmed, an unmatched path named" || fail "path list CR/unmatched: rc $rc [$(names | tr '\n' ' ')] $out"
# The masked hits of a snapshot file are shown, not discarded.
mkdir -p "$R/conf"; printf 'k = "%s"\n' "$AWS" > "$R/conf/leak.yml"
fresh; run "$R" "$URL" required "$P"
printf '%s' "$out" | grep -q 'conf/leak.yml:1 AWS access key (AKIA...GH)' && ok "the snapshot's masked hits are shown" || fail "snapshot hits hidden: $out"
rm -rf "$R/conf"

# ---- 6. Status table ---------------------------------------------------------
st() { # name, want rc, repo plan, payload plan, mode, [want calls "repo payload ..."], [text]
  fresh; plan repo "$3"; plan payload "$4"; run "$R" "$URL" "$5" "$P"
  local seq; seq=$(grep '^CURL' "$STUB/transcript" | cut -d' ' -f2 | tr '\n' ' ')
  if [ "$rc" != "$2" ]; then fail "$1: exit $rc, want $2: $out"; return; fi
  if [ -n "${6:-}" ] && [ "$seq" != "$6" ]; then fail "$1: calls [$seq], want [$6]"; return; fi
  if [ -n "${7:-}" ] && ! printf '%s' "$out" | grep -q -- "$7"; then fail "$1: output lacks '$7': $out"; return; fi
  ok "$1"
}
st "repo 200, payload 200: done" 0 '' '' required "repo payload "
st "repo 409 snapshot_taken: go on" 0 '409|{"code":"snapshot_taken"}|' '' required "repo payload "
st "repo 409 of another kind: stop" 1 '409|{"code":"other"}|' '' required "repo "
st "repo 413: stop, the body printed" 1 '413|{"code":"snapshot_too_large","error":"use /me/policy"}|' '' required "repo " "/me/policy"
st "repo 400: stop" 1 '400|{"code":"not_gzip"}|' '' required "repo "
st "repo 404: the ticket is gone, the payload not sent" 1 '404|{}|' '' required "repo " "the payload was not sent"
st "repo 410: the ticket is gone" 1 '410|{}|' '' required "repo " "get_findings"
st "repo 429 then 200: retried" 0 '429|{"code":"snapshot_busy"}|7' '' required "repo repo payload "
[ "$(cat "$STUB/sleeps" 2>/dev/null)" = 7 ] && ok "Retry-After honoured" || fail "Retry-After: slept $(cat "$STUB/sleeps" 2>/dev/null)"
st "repo 429 five times: exit 75 after 4 retries" 75 "$(printf '429|{}|99\n%.0s' 1 2 3 4 5)" '' required "repo repo repo repo repo " "run the same command again"
[ "$(tr '\n' ' ' < "$STUB/sleeps")" = "30 30 30 30 " ] && ok "Retry-After clamped to 30, 4 waits" || fail "clamp: slept $(tr '\n' ' ' < "$STUB/sleeps")"
st "Retry-After 0 is clamped to 1" 0 '429|{}|0' '' required "repo repo payload "
[ "$(cat "$STUB/sleeps")" = 1 ] && ok "Retry-After floor 1" || fail "floor: slept $(cat "$STUB/sleeps")"
st "no Retry-After: 30" 0 '502|{}|' '' required "repo repo payload "
[ "$(cat "$STUB/sleeps")" = 30 ] && ok "default wait 30" || fail "default wait: slept $(cat "$STUB/sleeps")"
st "curl failure: retried" 0 '000|x|' '' required "repo repo payload "
st "no answer five times: 75, said cleanly" 75 "$(printf '000|x|\n%.0s' 1 2 3 4 5)" '' required "repo repo repo repo repo " "run the same command again"
st "the last Retry-After is passed on" 75 "$(printf '429|{}|7\n%.0s' 1 2 3 4 5)" '' required "repo repo repo repo repo " "in about 7 seconds"
grep -q -- '--connect-timeout 10 --speed-limit 1024 --speed-time 30' "$STUB/args" && ok "curl has a connect timeout and a stall limit" || fail "curl limits: $(head -n 1 "$STUB/args")"
# The retries stop at the time budget, inside the skill's 600 s Bash call: a
# clock that has run 470 s allows no 30 s wait.
DB="$ROOT/datebin"; mkdir -p "$DB"
printf '#!/bin/sh
n=$(cat "$STUB/clock" 2>/dev/null || echo 1000); echo $((n + 470)) > "$STUB/clock"; echo "$n"
' > "$DB/date"; chmod +x "$DB/date"
fresh; plan repo '429|{}|30'; out=$(cd "$R" && PATH="$DB:$BIN:$PATH" sh "$UP" "$URL" required "$P" 2>&1); rc=$?
[ "$rc" = 75 ] && [ ! -e "$STUB/sleeps" ] && ok "no wait past the time budget" || fail "budget: rc $rc slept $(cat "$STUB/sleeps" 2>/dev/null) $out"
st "payload 409 snapshot_required in diff mode: stop, rerun with required" 1 '' '409|{"code":"snapshot_required"}|' off "payload " "required in place of off"
st "payload 409 after a snapshot was sent: stop, no loop" 1 '' '409|{"code":"snapshot_required"}|' required "repo payload "
st "payload 400: stop" 1 '' '400|{"code":"diff_not_a_diff"}|' required "repo payload " "diff_not_a_diff"
st "payload 413: stop" 1 '' '413|{"code":"too_large"}|' required "repo payload "
st "payload 404: may have arrived" 1 '' '404|{}|' required "repo payload " "get_findings"
st "payload 410: gone" 1 '' '410|{}|' required "repo payload " "get_findings"
st "payload 429 five times: 75" 75 '' "$(printf '429|{}|1\n%.0s' 1 2 3 4 5)" required "repo payload payload payload payload payload "
st "payload 503: 75 at once, no wait" 75 '' '503|{}|120' required "repo payload " "120 seconds"
[ -e "$STUB/sleeps" ] && fail "payload 503 waited in the script"
st "payload 500 then 200: retried" 0 '' '500|{}|1' required "repo payload payload "

# ---- 7. URL and arguments ------------------------------------------------------
for bad in "https://evil.example/u/tok" "http://mcp.ohmybug.ai/u/tok" "https://mcp.ohmybug.ai/u/x; touch $ROOT/pwned" "https://mcp.ohmybug.ai/u/" "https://mcp.ohmybug.ai.evil/u/tok" "https://mcp.ohmybug.ai/u/a/../b"; do
  fresh; run "$R" "$bad" required "$P"
  [ "$rc" = 1 ] && [ "$(calls)" = 0 ] && ok "refused before anything runs: $bad" || fail "URL $bad: rc $rc calls $(calls)"
done
[ -e "$ROOT/pwned" ] && fail "a URL was evaluated"
fresh; run "$R" "$URL" maybe "$P"
[ "$rc" = 1 ] && [ "$(calls)" = 0 ] && ok "a mode other than required|off refuses" || fail "mode: rc $rc"

echo "omb-upload: $([ "$fails" = 0 ] && echo ok || echo "$fails failing")"
[ "$fails" = 0 ]
