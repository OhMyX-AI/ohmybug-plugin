#!/bin/bash
# Run me after touching omb_paths.py: `bash hooks/omb-paths-test.sh`
#
# The partial snapshot's file list, on real git: fixture repositories with a
# base and a head commit, the list's inputs written the way omb-upload.sh
# writes them (the diff's names, its added lines behind git's
# --output-indicator-new), and the list read back from the records it writes.
# The upload rows (what is packed and sent, the mark) are in omb-upload-test.sh.
set -u
G=$(cd "$(dirname "$0")" && pwd)
PATHS="$G/omb_paths.py"
export PYTHONDONTWRITEBYTECODE=1
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
fails=0
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
ok() { echo "ok   $*"; }
g() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# lst <repo>: the list for HEAD~1..HEAD as kept paths, one space apart, in
# rank order, in $got; the stats line in $ST; the exit status in $lrc.
lst() {
  local r=$1 o="$ROOT/o"
  rm -rf "$o"; mkdir -p "$o"
  git -C "$r" diff-tree -r -M --name-only -z HEAD~1 HEAD > "$o/changed.z"
  git -C "$r" diff-tree -r -M -p -U0 --output-indicator-new="$(printf '\001')" HEAD~1 HEAD > "$o/added"
  env -i PATH="$PATH" HOME="$o" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null LC_ALL=C ${LIMITS:+"OMB_TEST_PATHS_LIMITS=$LIMITS"} \
    python3 -I -B "$PATHS" "$r/.git" "$(git -C "$r" rev-parse 'HEAD^{tree}')" "$o/changed.z" "$o/added" "$o/keep.z" "$o/stats"
  lrc=$?
  ST=$(cat "$o/stats" 2>/dev/null)
  got=; [ -f "$o/keep.z" ] && got=$(tr '\0' '\n' < "$o/keep.z" | sed '/^$/d' | cut -f2 | paste -sd' ' -)
}
# A repository with a base commit, then the head commit run() makes.
repo() { R="$ROOT/$1"; mkdir -p "$R"; g -C "$R" init -q; }
head_commit() { g -C "$R" add -A && g -C "$R" commit -qm "$1"; }

# ---- L3. The rule's constants: a written-out copy -------------------------
# The server rule's, in Python form (`$` as `\Z`). Changing any of them in
# the script reddens this row.
python3 -I - "$PATHS" <<'PY' && ok "L3 the caps, patterns and keywords equal the written-out copy" || fail "L3 a constant of the rule changed"
import re, sys
src = open(sys.argv[1]).read()
want = {
    "PARTIAL": '{"changed": 60, "callers": 20, "bytes": 16 * 1024 * 1024, "file": 4 << 20, "names": 40}',
    "OS_MANIFEST": r'''re.compile(r"^(package\.json|.*\.gemspec|Gemfile|pyproject\.toml|setup\.py|setup\.cfg|Cargo\.toml|go\.mod|pom\.xml|build\.gradle(\.kts)?|composer\.json|requirements\.txt|tsconfig\.json)\Z", re.A)''',
    "OS_SKIP": r'''re.compile(r"(^|\/)(node_modules|vendor|third_party|dist|build|\.yarn)\/|(^|\/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|Cargo\.lock|poetry\.lock|go\.sum|composer\.lock|Gemfile\.lock|uv\.lock|Pipfile\.lock|bun\.lockb?)\Z|\.(min\.js|min\.css|map|png|jpe?g|gif|ico|svg|webp|pdf|zip|gz|jar|woff2?|ttf|eot|mp4|mp3|lock|snap)\Z|_pb2\.py\Z|\.pb\.go\Z", re.A)''',
    "OS_DOC1": r'''re.compile(r"\.(md|mdx|rst|txt|adoc)\Z|(^|\/)(licen[cs]e|changelog|notice)\Z", re.A | re.I)''',
    "OS_DOC2": r'''re.compile(r"(^|\/)(LICEN[CS]E|CHANGELOG|NOTICE)([-_.][^/]*)?\Z", re.A)''',
    "NAME": r'''re.compile(r"(?<![A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]{3,})\s*\(|(?:def|function|class|interface|fn|func|fun)\s+([A-Za-z_][A-Za-z0-9_]{3,})")''',
}
bad = [k for k, v in want.items() if not re.search(r"^%s = %s$" % (k, re.escape(v)), src, re.M)]
kw = re.search(r'^OS_KW = set\("""(.*?)""".split\(\)\)$', src, re.S | re.M)
KW = """self this that true false null none None True False return const function class import from export default async await
while for else elif then case break continue public private protected static final void string number boolean object print
length value values items index error errors result results data type name test tests assert expect equal should params props"""
if not kw or kw.group(1).split() != KW.split():
    bad.append("OS_KW")
if bad:
    print(bad)
sys.exit(1 if bad else 0)
PY

# ---- L2. Parity with the server rule ---------------------------------------
# Three fixtures, and the lists the server rule's reference implementation
# produced for them once, written out here: ranking (names in 1 to 9 files,
# keywords, short names, skipped and doc paths, more than 20 callers), caps
# (over 4 MiB, a NUL byte, past 16 MiB), folders (62 changed files, nested
# manifests, a changed manifest, a deletion, a rename).
python3 -I - "$ROOT/fx" <<'PY'
import os, subprocess, sys

root = sys.argv[1]
G = ["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "init.defaultBranch=main"]


def w(r, p, s):
    f = os.path.join(r, p)
    os.makedirs(os.path.dirname(f), exist_ok=True)
    with open(f, "wb") as o:
        o.write(s if isinstance(s, bytes) else s.encode())


def commit(r, m):
    subprocess.run(G + ["-C", r, "add", "-A"], check=True)
    subprocess.run(G + ["-C", r, "commit", "-qm", m], check=True)


def repo(name):
    r = os.path.join(root, name)
    os.makedirs(r)
    subprocess.run(G + ["init", "-q", r], check=True)
    return r


# A: ranking. Names in 1 to 9 files, keywords, short names, skipped and doc
# paths, more than 20 callers, manifests that also use a name.
r = repo("a")
w(r, "package.json", '{"name": "a", "main": "alpha_one"}\n')
w(r, "src/app/pyproject.toml", "[x]\nalpha_one = 1\n")
w(r, "src/setup.cfg", "[x]\n")
w(r, "other/Cargo.toml", "[x]\n")
w(r, "src/app/main.py", "def main():\n    pass\n")
for i, (name, n) in enumerate([("alpha_one", 2), ("beta_two", 3), ("gamma_three", 1), ("DeltaFour", 8),
                               ("common_nine", 9), ("epsilon_five", 4), ("zeta_six", 5), ("eta_seven", 6),
                               ("theta_eight", 7), ("iota_ten", 3), ("kappa_x", 2), ("lambda_y", 3)]):
    for j in range(n):
        w(r, "lib/%s/f%d.py" % (name, j), "from x import %s\n%s(1)\n" % (name, name))
w(r, "node_modules/dep/alpha_one.js", "alpha_one()\n")
w(r, "vendor/x/beta.go", "beta_two()\n")
w(r, "dist/app.min.js", "gamma_three()\n")
w(r, "docs/guide.md", "gamma_three()\n")
w(r, "CHANGELOG", "gamma_three()\n")
w(r, "LICENSE-MIT", "gamma_three()\n")
w(r, "lib/shared.py", "alpha_one(); beta_two(); epsilon_five()\n")
w(r, "lib/upper.py", "ALPHA_ONE()\n")
w(r, "lib/partword.py", "xalpha_one(); alpha_one_x()\n")
commit(r, "base")
w(r, "src/app/main.py", "def main():\n    pass\n" + "".join("    %s(1)\n" % n for n in [
    "alpha_one", "beta_two", "common_nine", "epsilon_five", "zeta_six", "eta_seven", "theta_eight",
    "iota_ten", "kappa_x", "lambda_y", "print", "return", "ab", "values", "self.result"])
    + "def gamma_three():\n    pass\nclass DeltaFour:\n    pass\n")
w(r, "src/app/new_mod.py", "def brand_new():\n    alpha_one (2)\n")
commit(r, "head")

# B: caps. A changed file over 4 MiB, a caller with a NUL byte, callers that
# pass 16 MiB together, and a small one after them that still fits.
r = repo("b")
w(r, "big.py", "x = 1\n")
w(r, "mod.py", "pass\n")
w(r, "c1_nul.py", b"\0binary_name_here()\n")
for i in range(5):
    w(r, "c%d_big.py" % (i + 2), "big_caller_name()\n" + "#" * (3900 * 1024) + "\n")
w(r, "c7_small.py", "big_caller_name()\nbinary_name_here()\n")
w(r, "c8_exact.py", "edge_name_four()\n")
commit(r, "base")
w(r, "big.py", "x = 2\n" + "#" * (4 * 1024 * 1024) + "\n")
w(r, "mod.py", "pass\nbig_caller_name()\nbinary_name_here()\nedge_name_four()\n")
commit(r, "head")

# C: folders. 62 changed files (the first 60 count), nested manifests, a
# changed manifest, a deletion and a rename, a manifest beside but not above.
r = repo("c")
w(r, "Gemfile", "x\n")
w(r, "a/package.json", "{}\n")
w(r, "a/b/go.mod", "x\n")
w(r, "a/b/c/foo.gemspec", "x\n")
w(r, "a/b/c/requirements.txt", "x\n")
w(r, "a/b/c/setup.py", "x\n")
w(r, "a/b/c/x.py", "x\n")
w(r, "a/y.go", "x\n")
w(r, "d/pom.xml", "x\n")
w(r, "d/old_name.py", "\n".join("line %d" % i for i in range(20)) + "\n")
w(r, "gone.py", "x\n")
for i in range(62):
    w(r, "z/f%02d.py" % i, "x\n")
w(r, "z/build.gradle.kts", "x\n")
w(r, "q/user.py", "deep_helper_name()\n")
commit(r, "base")
w(r, "a/b/c/x.py", "x\ndeep_helper_name()\n")
w(r, "a/b/c/setup.py", "y\n")
w(r, "a/y.go", "y\n")
os.remove(os.path.join(r, "gone.py"))
os.rename(os.path.join(r, "d/old_name.py"), os.path.join(r, "d/new_name.py"))
for i in range(62):
    w(r, "z/f%02d.py" % i, "y\n")
commit(r, "head")
PY
A='src/app/main.py src/app/new_mod.py src/app/pyproject.toml src/setup.cfg package.json lib/gamma_three/f0.py lib/shared.py lib/kappa_x/f0.py lib/kappa_x/f1.py lib/iota_ten/f0.py lib/iota_ten/f1.py lib/iota_ten/f2.py lib/lambda_y/f0.py lib/lambda_y/f1.py lib/lambda_y/f2.py lib/beta_two/f0.py lib/beta_two/f1.py lib/beta_two/f2.py lib/alpha_one/f0.py lib/alpha_one/f1.py lib/epsilon_five/f0.py lib/epsilon_five/f1.py lib/epsilon_five/f2.py lib/epsilon_five/f3.py lib/zeta_six/f0.py'
B='mod.py c7_small.py c8_exact.py c2_big.py c3_big.py c4_big.py c5_big.py'
C='a/b/c/setup.py a/b/c/x.py a/y.go d/new_name.py z/f00.py z/f01.py z/f02.py z/f03.py z/f04.py z/f05.py z/f06.py z/f07.py z/f08.py z/f09.py z/f10.py z/f11.py z/f12.py z/f13.py z/f14.py z/f15.py z/f16.py z/f17.py z/f18.py z/f19.py z/f20.py z/f21.py z/f22.py z/f23.py z/f24.py z/f25.py z/f26.py z/f27.py z/f28.py z/f29.py z/f30.py z/f31.py z/f32.py z/f33.py z/f34.py z/f35.py z/f36.py z/f37.py z/f38.py z/f39.py z/f40.py z/f41.py z/f42.py z/f43.py z/f44.py z/f45.py z/f46.py z/f47.py z/f48.py z/f49.py z/f50.py z/f51.py z/f52.py z/f53.py z/f54.py z/f55.py a/package.json Gemfile a/b/c/foo.gemspec a/b/c/requirements.txt a/b/go.mod d/pom.xml z/build.gradle.kts q/user.py'
for x in A B C; do
  r=$(echo "$x" | tr ABC abc); lst "$ROOT/fx/$r"; eval "want=\$$x"
  [ "$lrc" = 0 ] && [ "$got" = "$want" ] && ok "L2 fixture $r: the server rule's list, in its order" || fail "L2 fixture $r: rc $lrc got [$got]"
done

# ---- L1. Added lines by git's indicator, never by a leading '+' -------------
# An added line whose own text starts with "++" is read; a line that is only
# context, though it looks like a diff header, is not.
repo l1; printf 'x = 1\n+++ fake_name_here()\n' > "$R/m.py"; printf 'call_me_now()\n' > "$R/u1.py"; printf 'fake_name_here()\n' > "$R/u2.py"; head_commit base
printf 'x = 1\n+++ fake_name_here()\n++ call_me_now()\n' > "$R/m.py"; head_commit head
lst "$R"
[ "$got" = "m.py u1.py" ] && ok "L1 an added line '++ call_me_now()' gives a name; a context '+++' line does not" || fail "L1 indicator: [$got]"

# ---- L4. Caps at their edges -------------------------------------------------
# Head: mod.py, y1.bin (a NUL byte at 7999: binary, skipped) and y2.bin (one
# at 8000, past the read: kept). Then x1..x7, one name in seven files, by
# path: exactly 4 MiB is kept, one byte more is not; the total reaches
# 16 MiB less 62 bytes; x6 (63 bytes) would pass it and is skipped, and x7
# (62 bytes, exactly to 16 MiB) after it is kept: skip, never stop.
repo l4; printf 'pass\n' > "$R/mod.py"
python3 -I - "$R" <<'PY'
import sys
r = sys.argv[1]
M = 4 * 1024 * 1024
line = b"edge_name_here()\n"
def w(p, n):
    open(r + "/" + p, "wb").write(line + b"#" * (n - len(line)))
mod = len(b"pass\nedge_name_here()\n")
w("x1.py", M)
w("x2.py", M + 1)
w("x3.py", M)
w("x4.py", M)
w("x5.py", 4 * M - (mod + 8001 + 3 * M) - 62)
w("x6.py", 63)
w("x7.py", 62)
PY
head_commit base; printf 'pass\nedge_name_here()\n' > "$R/mod.py"
python3 -I -c 'import sys
open(sys.argv[1] + "/y1.bin", "wb").write(b"#" * 7999 + b"\0")
open(sys.argv[1] + "/y2.bin", "wb").write(b"#" * 8000 + b"\0")' "$R"
head_commit head
lst "$R"
[ "$got" = "mod.py y2.bin x1.py x3.py x4.py x5.py x7.py" ] && ok "L4 caps: a NUL by byte 8000 is binary; 4 MiB kept, one byte over skipped; 16 MiB exactly kept after a skip" || fail "L4 caps: [$got]"

# ---- L5. A name in more than 8 files says nothing -------------------------
repo l5; printf 'pass\n' > "$R/m.py"
for i in 1 2 3 4 5 6 7 8; do printf 'in_eight_files()\n' > "$R/e$i.py"; done
for i in 1 2 3 4 5 6 7 8 9; do printf 'in_nine_files()\n' > "$R/n$i.py"; done
head_commit base; printf 'pass\nin_eight_files()\nin_nine_files()\n' > "$R/m.py"; head_commit head
lst "$R"
[ "$got" = "m.py e1.py e2.py e3.py e4.py e5.py e6.py e7.py e8.py" ] && ok "L5 a name in 8 files adds them; in 9, none" || fail "L5 eight/nine: [$got]"

# ---- L6. Modes: only regular files are callers or manifests ---------------
repo l6; mkdir -p "$R/s"; printf 'pass\n' > "$R/m.py"; printf 'x\n' > "$R/t.txt"
ln -s 'sym_target_name(' "$R/link_call"; ln -s t.txt "$R/package.json"; ln -s t.txt "$R/moved"
g -C "$R" -c protocol.file.allow=always submodule add -q "$ROOT/l5" sub >/dev/null 2>&1 || fail "L6 fixture: no submodule"
head_commit base
printf 'pass\nsym_target_name()\n' > "$R/m.py"; rm "$R/moved"; ln -s m.py "$R/moved"; head_commit head
lst "$R"
mode=$(tr '\0' '\n' < "$ROOT/o/keep.z" | grep 'moved$' | cut -d' ' -f1)
[ "$got" = "m.py moved" ] && [ "$mode" = 120000 ] && ok "L6 a symlink that matches is no caller, a symlinked package.json no manifest; a changed symlink stays, as a link" || fail "L6 modes: [$got] mode [$mode]"

# ---- L7. A tree past the line gets no caller search, and says why ---------
mkdir -p "$ROOT/gw"; printf '#!/bin/sh\necho "$*" >> "%s/gitcalls"\nexec %s "$@"\n' "$ROOT" "$(command -v git)" > "$ROOT/gw/git"; chmod +x "$ROOT/gw/git"
R="$ROOT/l5"
for lim in "17 1000000000:files" "1000 10:bytes" "18 1000000000:-"; do
  : > "$ROOT/gitcalls"
  PATH="$ROOT/gw:$PATH" LIMITS=${lim%:*} lst "$R"; ngrep=$(grep -c '^--git-dir=[^ ]* grep ' "$ROOT/gitcalls")
  case ${lim#*:} in
    -) [ "$ngrep" = 1 ] && [ "${ST##* }" = - ] && [ "$got" != m.py ] && ok "L7 a tree of 18 files under an 18-file line: searched" || fail "L7 at the line: grep $ngrep [$ST] [$got]" ;;
    *) [ "$ngrep" = 0 ] && [ "${ST##* }" = "${lim#*:}" ] && [ "$got" = m.py ] && ok "L7 past the ${lim#*:} line: no grep, head and manifests only, the stats say ${lim#*:}" || fail "L7 ${lim#*:}: grep $ngrep [$ST] [$got]" ;;
  esac
done

# ---- L8. One grep pass for every name -----------------------------------------
: > "$ROOT/gitcalls"
PATH="$ROOT/gw:$PATH" lst "$ROOT/fx/a"
[ "$(grep -c '^--git-dir=[^ ]* grep ' "$ROOT/gitcalls")" = 1 ] && ok "L8 the caller search is one git grep, whatever the number of names" || fail "L8 grep calls: $(grep -c ' grep ' "$ROOT/gitcalls")"

# ---- L9. A failure is a failure, never a short list ------------------------
R="$ROOT/l5"; printf '#!/bin/sh\ncase "$*" in *" grep "*) exit 2 ;; esac\nexec %s "$@"\n' "$(command -v git)" > "$ROOT/gw/git"
PATH="$ROOT/gw:$PATH" lst "$R"
[ "$lrc" != 0 ] && ok "L9 a git grep that fails (not 'no match') fails the list" || fail "L9 grep failure: rc $lrc [$ST]"

echo "omb-paths: $([ "$fails" = 0 ] && echo ok || echo "$fails failing")"
[ "$fails" = 0 ]
