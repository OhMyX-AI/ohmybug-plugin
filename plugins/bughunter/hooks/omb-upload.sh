#!/bin/sh
# omb-upload.sh <upload_url> <required|off> <scope> [--only <path>]... [context-file ...]
# omb-upload.sh --dry-run    <required|off> <scope> [--only <path>]...
#   scope: --base <branch>  the merge base with origin/<branch> to the working copy
#          --head           HEAD to the working copy
#          --all            nothing to the working copy (all of it is new code)
#          --commits <N>    the last N commits, HEAD~N to HEAD (the whole history
#                           when there are N or fewer)
#
# Sends a payload hunt's bytes to its upload ticket: the repository snapshot
# (with `required`), then {diff, files}. The script writes the diff itself.
# The working copy is read into a tree as a commit would read it (the user's
# git settings decide what is ignored and how files are cleaned): tracked,
# staged, unstaged and new files git does not ignore. The diff of two trees is
# then written by git with no user or repository settings at all, in a
# throwaway bare repository, so its format never depends on them. The client
# never reads the diff for structure: secret-named files are left out by
# git's own exclude pathspecs (the snapshot's list), and a file whose diff is
# not UTF-8 is found by path and left out. --only limits the diff to a path
# below the current folder. --dry-run does everything before the first
# request, prints the manifest and the file names, and sends nothing.
#
# The skill runs this file; it never runs a command a tool answer hands it.
# Only two values come from the server: the upload URL, whose host is pinned
# below, and required|off. Neither is ever evaluated, and the branch name is
# refused unless it has the shape of a ref. It sits in hooks/, beside its
# detector (omb_scan.py): the merge gate counts both as code. A skill-only
# install has neither, so it cannot upload.
#
# Order, all before the first request: build the payload, scan it, pack the
# snapshot, scan that, take its sha256, print one manifest line. A credential
# in the payload refuses (exit 3). A credential in a snapshot file leaves that
# file out: the snapshot is packed again without it, scanned again, and the
# file is named in the manifest. What could not be scanned is not sent.
#
# No clock and no retry: one request per door, and the ticket's lifetime on
# the server is the only clock. The snapshot is packed from a commit with a
# fixed date, so the same working copy gives the same bytes on a rerun. A
# ticket that already holds a snapshot answers 409 snapshot_taken with that
# snapshot's sha256: equal to ours, the payload goes; different, the ticket is
# retired (DELETE <upload_url>) and nothing is hunted, so a new diff never
# pairs with an old snapshot; absent (an older server), the script stops.
# curl runs with -q (no ~/.curlrc); the proxy and CA variables (HTTPS_PROXY,
# NO_PROXY, CURL_CA_BUNDLE, SSL_CERT_FILE) still apply, as a company network
# needs them to reach the host at all.
#
# Boundary: POSIX sh (CI runs it under dash and bash on Linux and bash 3.2 on
# macOS; other shells untested), git >= 2.25, python3 >= 3.7, curl, gzip, on
# macOS or Linux. Anything else is unsupported; where the script can tell
# (python3 older than 3.7, git older than 2.25, no python3, no curl) it refuses
# with one sentence, and nothing unscanned is sent unless the scan is off. The
# secret-name list is best effort. Assumptions, not code: a hard kill (SIGKILL)
# leaves the temporary 0700 folder behind; a full TMPDIR fails a write and
# nothing is sent; a working copy near the server's 1 GiB ceiling may not pack,
# scan and send inside the skill's 600 s call on a slow machine (the client
# then stops the call, which counts as exit 75); a `-diff` or `binary`
# attribute is not applied to the diff (git's own NUL-byte check still is);
# an edit between the diff and the snapshot gives the two of two moments;
# more than 200 files that are not UTF-8 refuse instead of being left out.
#
# env: OMB_SNAPSHOT_HOME_OK=1     the project is the home folder (a container)
#      OHMYBUG_SECRET_SCAN=0      no credential scan (the manifest says so)
# exit: 0 payload accepted (or --dry-run done) | 1 final, the last line says
#       why and what to do | 3 credential in the payload | 4 python3 (3.7+),
#       curl or git (2.25+) missing | 75 no final answer: call get_findings,
#       rerun only while awaiting_upload
set -eu
umask 077

HOST=mcp.ohmybug.ai
# The server's snapshot secret list, name for name (omb-upload-test.sh holds
# the parity check).
OMB_SECRETS='.env* *secret* *credential* id_rsa* id_dsa* id_ecdsa* id_ed25519* *.pem *.key *.p12 *.pfx
  .npmrc .netrc .pgpass .pypirc .git-credentials *.tfstate* *.tfvars* kubeconfig .kube .docker
  *.ppk *.jks *.keystore .ssh .aws .gnupg'
nl='
'

die() { printf '%s\n' "$1" >&2; exit "${2:-1}"; }
# -I: no PYTHON* variables and neither this folder nor the user's site on
# sys.path. The script runs inside the user's repository, where a json.py would
# otherwise be imported in place of the standard one. -B: no bytecode written
# into the plugin folder when omb_scan is imported.
py() { python3 -I -B "$@"; }
USAGE="usage: omb-upload.sh (<upload_url> | --dry-run) <required|off> (--base <branch> | --head | --all | --commits <N>) [--only <path>]... [context-file ...]"
[ $# -ge 3 ] || die "$USAGE"
url=$1 dry=0
[ "$url" = --dry-run ] && dry=1
# The one dispatch point: argv[2] is read here and nowhere else. snap says
# what goes to <upload_url>/repo: whole = the working copy, empty = nothing
# (diff mode).
case $2 in
  required) snap=whole ;;
  off) snap= ;;
  *) die "omb-upload: the second argument is required or off, got '$2'; nothing was sent" ;;
esac
shift 2
base= ncommits=
case $1 in
  --base)
    [ $# -ge 2 ] || die "omb-upload: --base needs a branch name; nothing was sent"
    base=$2 scope=base; shift 2
    # Only the shape of a ref: no quote, space or other shell byte, no leading dash.
    case $base in ''|-*|*[!A-Za-z0-9._/-]*) die "omb-upload: '$base' is not a branch name this script accepts (letters, digits, '.', '_', '/', '-'; not starting with '-'); nothing was sent" ;; esac ;;
  --head) scope=head; shift ;;
  --all) scope=all; shift ;;
  --commits)
    [ $# -ge 2 ] || die "omb-upload: --commits needs a number; nothing was sent"
    ncommits=$2 scope=commits; shift 2
    case $ncommits in ''|0*|*[!0-9]*|????*) die "omb-upload: --commits takes a number from 1 to 999, got '$ncommits'; nothing was sent" ;; esac ;;
  *) die "omb-upload: the third argument is the scope (--base <branch>, --head, --all or --commits <N>), got '$1'; nothing was sent" ;;
esac
# --only: a path below the current folder, never a glob or an option (it goes
# to git as a literal pathspec). One per line in $only.
only=
while [ "${1:-}" = --only ]; do
  [ $# -ge 2 ] || die "omb-upload: --only needs a path; nothing was sent"
  o=$2; shift 2
  while case $o in ./*) true ;; *) false ;; esac; do o=${o#./}; done
  case $o in
    ''|/*|..|../*|*/..|*/../*) die "omb-upload: --only takes a path below the current folder (no leading '/', no '..'), got '$o'; nothing was sent" ;;
    *[[:cntrl:]]*) die "omb-upload: --only got a path with a control character; nothing was sent" ;;
  esac
  only="$only$o$nl"
done
[ "$dry" = 1 ] && [ $# -gt 0 ] && die "omb-upload: --dry-run takes no context files; nothing was sent"
if [ "$dry" = 0 ]; then
  case $url in "https://$HOST/u/"*) tok=${url#"https://$HOST/u/"} ;; *) die "omb-upload: not an upload URL of $HOST; nothing was sent" ;; esac
  case $tok in ''|*[!A-Za-z0-9_-]*) die "omb-upload: not an upload URL of $HOST; nothing was sent" ;; esac
fi
command -v python3 >/dev/null 2>&1 || die "omb-upload: python3 not found, so nothing could be scanned and nothing was sent" 4
py -c 'import sys; sys.exit(sys.version_info < (3, 7))' || die "omb-upload: python3 3.7 or newer is needed; nothing was sent" 4
[ "$dry" = 1 ] || command -v curl >/dev/null 2>&1 || die "omb-upload: curl not found, so nothing could be sent" 4
# The floor: the tree and pathspec machinery below needs git 2.25.
gv=$(git version 2>/dev/null | sed -n 's/^git version \([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p') || gv=
if [ -z "$gv" ]; then
  die "omb-upload: git was not found or did not say its version; git 2.25 or newer is needed: install or update git; nothing was sent" 4
fi
gmaj=${gv% *} gmin=${gv#* }
[ "$gmaj" -gt 2 ] || { [ "$gmaj" = 2 ] && [ "$gmin" -ge 25 ]; } \
  || die "omb-upload: git $(git version | sed 's/^git version //') found, 2.25 or newer is needed: update git; nothing was sent" 4
DIR=$(cd "$(dirname "$0")" && pwd)
CORE=$DIR/omb_scan.py
[ -f "$CORE" ] || die "omb-upload: the credential detector (omb_scan.py) is not installed beside this script, so nothing could be scanned and nothing was sent. Push the branch and hunt the pushed commit (rung 1), or install the full plugin."

d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
# A stopped call is "nothing final known", as the skill reads a call stopped at 600 s.
trap 'exit 75' HUP INT TERM

# A folder without git: packed as the server packs one. Only on "not a git
# repository" (read in the C locale, so a translated git says it the same way)
# AND no .git entry here or above: a repository git refuses to read (an
# ownership check, a .git file whose folder is gone) stops here rather than
# being packed without its .gitignore.
if ! err=$(LC_ALL=C git rev-parse --git-dir 2>&1 >/dev/null); then
  case $err in *"not a git repository"*) ;; *) die "omb-upload: git cannot read this repository ($err); nothing was sent" ;; esac
  p=$(pwd -P)
  while :; do
    [ -e "$p/.git" ] || [ -L "$p/.git" ] && die "omb-upload: $p/.git is there but git cannot read it ($err); nothing was sent. Repair the repository (a worktree or submodule whose git folder moved), then run the same command again."
    [ "$p" = / ] && break
    p=$(dirname "$p")
  done
  [ "$scope" = all ] || die "omb-upload: this folder is not a git repository, so only --all applies (all of it is new code); nothing was sent"
  nogit=1
  export GIT_DIR="$d/w"
  git init -q --bare "$GIT_DIR"
  # GIT_WORK_TREE after the init: `git init` refuses to run while it is set.
  mkdir -p "$GIT_DIR/info"; printf '/.*/\nnode_modules/\n__pycache__/\n/venv/\n/target/\n/dist/\n/build/\n' >> "$GIT_DIR/info/exclude"; export GIT_WORK_TREE="$PWD"
else
  nogit=0
fi

# The home-folder check, shared by the working-copy tree and the pack: a
# folder that is the home folder or holds it is never read as a project.
home_check() {
  [ "${OMB_SNAPSHOT_HOME_OK:-}" = 1 ] && return 0
  h=; [ -n "${HOME:-}" ] && h=$(cd "$HOME" 2>/dev/null && pwd -P) || :; [ -n "$h" ] || { echo "refusing to pack: HOME is not set to a folder this shell can enter, so the home-folder check cannot run; if this folder is the project, run the same command again as one call with OMB_SNAPSHOT_HOME_OK=1 in front of it (OMB_SNAPSHOT_HOME_OK=1 bash .../omb-upload.sh ...)" >&2; exit 1; }
  p=$(pwd -P); case "$h/" in "${p%/}/"*) echo "refusing to pack $p: it is your home folder or a folder above it; run this from the project folder, or, if this folder is the project itself (a container checkout), run the same command again as one call with OMB_SNAPSHOT_HOME_OK=1 in front of it (OMB_SNAPSHOT_HOME_OK=1 bash .../omb-upload.sh ...)" >&2; exit 1;; esac
}

# `git add -A` that also reaches files outside a sparse checkout's cone: with
# --sparse where git has it (2.34+; before it, plain add -A has no such
# refusal). A skip-worktree entry is left as it is either way, never staged as
# a deletion. $@: options before `add`.
add_all() {
  if git add -h 2>&1 | grep -q -E -e '--(\[no-\])?sparse'; then git "$@" add -A --sparse; else git "$@" add -A; fi
}

# The working copy as a tree (step A): an index copy, a private object
# folder, `git add -A`, `git write-tree`, with the user's own git settings on
# purpose: ignore rules, line endings and clean filters decide what a commit
# would hold (LFS files stay pointers). Only a tree id comes out. The user's
# index and objects are never written. A skip-worktree entry stays as it is,
# so a sparse checkout is not a mass deletion; an unmerged path becomes the
# working file, markers and all.
worktree_tree() (
  set -e; umask 077; unset CDPATH; r=$(git rev-parse --show-toplevel); cd "$r"
  home_check
  o=$(cd "$(git rev-parse --git-path objects)" && pwd); k=$d/j; mkdir -p "$k/o/info"
  printf '%s\n' "$o" > "$k/o/info/alternates"
  cp -p "$(git rev-parse --git-path index)" "$k/i" 2>/dev/null || :
  export GIT_INDEX_FILE="$k/i" GIT_OBJECT_DIRECTORY="$k/o"
  add_all -c splitIndex.maxPercentChange=100
  git -c splitIndex.maxPercentChange=100 write-tree > "$d/D"
)

# The commits the diff runs between, read in the real repository.
empty=$(git hash-object -t tree /dev/null)
from= to=
case $scope in
  base) from=$(git merge-base HEAD "origin/$base" 2>/dev/null) || die "omb-upload: no merge base with origin/$base here (is the branch fetched?); nothing was sent" ;;
  head) from=$(git rev-parse -q --verify 'HEAD^{commit}') || die "omb-upload: there is no commit yet, so --head has nothing to start from: use --all; nothing was sent" ;;
  all) from=$empty ;;
  commits)
    to=$(git rev-parse -q --verify 'HEAD^{commit}') || die "omb-upload: there is no commit yet, so --commits has nothing to send: use --all; nothing was sent"
    from=$(git rev-parse -q --verify "HEAD~$ncommits^{commit}") || from=$empty ;;
esac
if [ -z "$to" ]; then
  set +e; worktree_tree; rc=$?; set -e
  [ "$rc" = 0 ] || die "omb-upload: the working copy could not be read into a tree (above); nothing was sent"
  to=$(cat "$d/D")
fi
prefix=$(git rev-parse --show-prefix)
objects=$(cd "$(git rev-parse --git-path objects)" && pwd)
top=$(git rev-parse --show-toplevel)

# The diff's repository (step B): bare, no work tree, its own empty config and
# no attributes, borrowing the objects of the repository and of step A.
# Every git call on it runs under env -i with an empty HOME: no user, system
# or repository setting, and none of the GIT_* variables, reaches the format.
fmt=$(git rev-parse --show-object-format 2>/dev/null) || fmt=
mkdir "$d/h"
env -i PATH="$PATH" HOME="$d/h" XDG_CONFIG_HOME="$d/h" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null LC_ALL=C \
  git init -q --bare ${fmt:+--object-format=$fmt} "$d/g" 2>/dev/null \
  || env -i PATH="$PATH" HOME="$d/h" XDG_CONFIG_HOME="$d/h" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null LC_ALL=C git init -q --bare "$d/g"
printf '%s\n' "$objects" > "$d/g/objects/info/alternates"
if [ -d "$d/j/o" ]; then printf '%s\n' "$d/j/o" >> "$d/g/objects/info/alternates"; fi

# The listed set for context files (diff mode only), secret names excluded by
# git, and the untracked files git does not ignore (named in the manifest:
# a branch diff of old left them out).
set -f
excl=
for q in $OMB_SECRETS; do excl="$excl:(exclude,top,icase,glob)**/$q$nl:(exclude,top,icase,glob)**/$q/**$nl"; done
set +f
: > "$d/listed"; : > "$d/untracked"
oifs=$IFS; IFS=$nl; set -f
if [ -z "$snap" ] && [ $# -gt 0 ]; then
  ( cd "$top" && git ls-files -z -co --exclude-standard -- ':/' $excl ) > "$d/listed"
fi
if [ "$scope" != commits ] && [ "$nogit" = 0 ]; then
  ( cd "$top" && git ls-files -z -o --exclude-standard -- ':/' ) > "$d/untracked"
fi
set +f; IFS=$oifs
if [ -n "$snap" ] && [ $# -gt 0 ]; then
  echo "omb-upload: context files are not sent with a repository snapshot, it holds them: $*" >&2
  set --
fi

# The payload. The client reads the diff only to decode it (JSON carries
# text); its files, names and counts come from git by path.
export OMB_SECRETS excl only
py - "$d" "$DIR" "$from" "$to" "$prefix" "$top" "$PATH" "$@" <<'PY' || exit 1
import json, os, re, subprocess, sys
d, here, frm, to, prefix, top, path, args = sys.argv[1:8] + [sys.argv[8:]]
sys.path.insert(0, here)
from omb_scan import read_listed

ENV = {"PATH": path, "HOME": d + "/h", "XDG_CONFIG_HOME": d + "/h", "GIT_CONFIG_NOSYSTEM": "1",
       "GIT_CONFIG_GLOBAL": "/dev/null", "LC_ALL": "C"}
FLAGS = ["-c", "core.quotePath=true", "diff-tree", "-r", "-M", "--no-color", "--no-ext-diff", "--no-textconv",
         "--src-prefix=a/", "--dst-prefix=b/", "--submodule=short"]
EXCL = [x for x in os.environ["excl"].split("\n") if x]
# "." is the current folder: its prefix, or the whole repository at the top.
ONLY = [":(top,literal)" + (prefix + x if x != "." else prefix) for x in os.environ["only"].split("\n")
        if x and (x != "." or prefix)]

def git(extra, specs):
    p = subprocess.run(["git", "--git-dir=" + d + "/g"] + FLAGS + extra + [frm, to, "--"] + specs,
                       env=ENV, stdout=subprocess.PIPE)
    if p.returncode:
        sys.stderr.write("omb-upload: git could not write the diff; nothing was sent.\n")
        sys.exit(1)
    return p.stdout

def say(msg):
    sys.stderr.write("omb-upload: " + msg + "; nothing was sent.\n")
    sys.exit(1)

def clean1(x):
    if isinstance(x, bytes):
        x = x.decode("utf-8", "replace")
    x = x.encode("utf-8", "surrogateescape").decode("utf-8", "replace")
    return re.sub(r"[\x00-\x1f\x7f]", "?", x)

def names(extra, specs):
    return [n for n in git(extra + ["--name-only", "-z"], specs).split(b"\0") if n]

lit = lambda p: ":(top,literal)" + p.decode("utf-8", "surrogateescape")
every = names(["--no-renames"], ONLY)
kept = names(["--no-renames"], ONLY + EXCL)
dropped = [n for n in every if n not in set(kept)]
specs = ONLY + EXCL
raw = git(["-p"], specs)
notutf8 = []
try:
    diff = raw.decode("utf-8")
except UnicodeDecodeError:
    for n in kept:
        try:
            git(["-p"], [lit(n)]).decode("utf-8")
        except UnicodeDecodeError:
            notutf8.append(n)
            if len(notutf8) > 200:
                say("more than 200 changed files are not UTF-8 text, too many to leave out one by one. Narrow the diff with --only")
    specs = specs + [":(exclude,top,literal)" + n.decode("utf-8", "surrogateescape") for n in notutf8]
    try:
        diff = git(["-p"], specs).decode("utf-8")
    except UnicodeDecodeError:
        say("the diff is not UTF-8 text even with the files that are not left out")
if not diff.strip():
    say("the diff is empty, or nothing is left of it once secret-named and non-UTF-8 files are out, so there is nothing to hunt")
final = names([], specs)
untracked = set(x for x in open(d + "/untracked", "rb").read().split(b"\0") if x)
new = [n for n in final if n in untracked]

files, sent, skipped = [], [], []
if args:
    listed = set(open(d + "/listed", "rb").read().split(b"\0"))
    rtop = os.path.realpath(top)
    for a in args:
        # Lexically below the top level, then opened part by part from it with
        # no symlink followed, and read from the fd that was checked.
        full = os.path.normpath(a if os.path.isabs(a) else os.path.join(top, prefix, a))
        rel = None
        inside = lambda r: r != ".." and not r.startswith("../") and not os.path.isabs(r)
        for t in (top, rtop):
            if inside(os.path.relpath(full, t)):
                rel = os.path.relpath(full, t)
                break
        else:
            # Reached through a link ABOVE the repository: its folder's real path.
            # A link inside the repository is still refused by read_listed.
            r = os.path.relpath(os.path.join(os.path.realpath(os.path.dirname(full)), os.path.basename(full)), rtop)
            if inside(r):
                rel = r
        content = None
        if rel is not None:
            got, data = read_listed(rtop, listed, rel)
            if got is not None and data is not None:
                try:
                    content = data.decode("utf-8")
                    rel.encode("utf-8")
                except UnicodeError:
                    content = None
        if content is None:
            skipped.append(a)
        else:
            files.append({"path": rel, "content": content})
            sent.append(rel)
clean = lambda xs: [clean1(x) for x in xs]
json.dump({"diff": diff, "files": files}, open(d + "/payload.json", "w", encoding="utf-8"), ensure_ascii=False)
with open(d + "/names", "w", encoding="utf-8") as f:
    for n in final:
        f.write(clean1(n) + (" (new, untracked)" if n in untracked else "") + "\n")
newnames = clean(new)
newline = ""
if newnames:
    newline = "%d untracked file%s git does not ignore: %s" % (len(newnames), "" if len(newnames) == 1 else "s",
              ", ".join(newnames[:5]) + (" and %d more" % (len(newnames) - 5) if len(newnames) > 5 else ""))
with open(d + "/meta", "w", encoding="utf-8") as f:
    f.write("\n".join([str(len(final)), ", ".join(clean(sent)), ", ".join(clean(skipped)), ", ".join(clean(dropped)),
                       str(len(diff.encode("utf-8"))), ", ".join(clean(notutf8)), newline]) + "\n")
PY
{ IFS= read -r nfiles; IFS= read -r ctx_sent; IFS= read -r ctx_skipped; IFS= read -r diff_dropped; IFS= read -r diff_bytes; IFS= read -r diff_notutf8; IFS= read -r diff_new; } < "$d/meta" || :

scan_off=0
[ "${OHMYBUG_SECRET_SCAN:-1}" = 0 ] && scan_off=1
if [ "$scan_off" = 0 ]; then
  set +e
  py "$CORE" --payload "$d/payload.json"; rc=$?
  set -e
  case $rc in
    0) ;;
    3) die "omb-upload: the diff or a context file carries what looks like a credential (above), so nothing was sent. Remove it or replace each value with [REDACTED], then run the same command again; the ticket stays valid." 3 ;;
    *) die "omb-upload: could not scan the payload for credentials, so nothing was sent" ;;
  esac
fi

# The packing step: the server's own packing recipe, statement for statement, in a
# folder of this script's ($1) instead of its own mktemp. Additions: $2, a
# NUL-separated list of paths to leave out (the credential hits of a first
# pack), removed from the temporary index before write-tree; the tree id
# kept in "$k/t"; and the archive is of a commit of that tree with a fixed
# author, committer and date, not of the tree, so its bytes (mtimes, the pax
# header) do not depend on the time it was packed. ${HOME:-} because this
# script runs set -u. Called only as a
# plain statement (see run_pack): on the left of || or in an if, set -e inside
# it would be off, and a failed step would pack a stale tree as a success.
pack() (
  k=$1 drop=$2
  set -e; umask 077; unset CDPATH; r=$(git rev-parse --show-toplevel); cd "$r"
  home_check
  o=$(cd "$(git rev-parse --git-path objects)" && pwd); rm -rf "$k"; mkdir "$k"
  cp -p "$(git rev-parse --git-path index)" "$k/i" 2>/dev/null || :; f=$(git rev-parse --show-object-format 2>/dev/null) || :; case $f in sha1|sha256) g=--object-format=$f;; *) g=;; esac; mkdir -p "$k/o/info"; printf '%s\n' "$o" > "$k/o/info/alternates"; export GIT_INDEX_FILE="$k/i" GIT_OBJECT_DIRECTORY="$k/o"; s='-c splitIndex.maxPercentChange=100'
  git ls-files -z -t > "$k/l"; xargs -0 sh -c 'for e; do case $e in "S "*) printf "%s\0" "${e#S }";; esac; done' sh < "$k/l" > "$k/s"
  git $s update-index -z --force-remove --stdin < "$k/s"
  add_all $s
  git $s update-index -z --force-remove --stdin < "$drop"
  t=$(git $s write-tree); printf '%s\n' "$t" > "$k/t"
  c=$(GIT_AUTHOR_NAME=omb GIT_AUTHOR_EMAIL=omb GIT_AUTHOR_DATE='946684800 +0000' GIT_COMMITTER_NAME=omb GIT_COMMITTER_EMAIL=omb GIT_COMMITTER_DATE='946684800 +0000' git commit-tree --no-gpg-sign -m omb "$t")
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
  { git init -q --bare $g "$k/g" 2>/dev/null || git init -q --bare "$k/g"; }; mkdir -p "$k/g/info"; printf '%s\n%s\n' "$o" "$k/o" > "$k/g/objects/info/alternates"
  echo '* -filter -text -ident -working-tree-encoding -export-ignore -export-subst' > "$k/g/info/attributes"
  set -- .
  # set -f: a name like *secret* must reach git as a pattern, never be expanded here.
  set -f
  for q in $OMB_SECRETS; do set -- "$@" ":(exclude,icase,glob)**/$q" ":(exclude,icase,glob)**/$q/**"; done
  set +f
  git --git-dir="$k/g" archive --format=tar.gz -o "$k/s.tgz" "$c" -- "$@"
)
run_pack() {
  set +e
  pack "$d/k" "$d/drop"; rc=$?
  set -e
  [ "$rc" = 0 ] || die "omb-upload: the repository could not be packed (above); nothing was sent"
}

# Pack and scan the snapshot. A hit leaves its files out: pack again without
# them, and that second pack is what gets scanned and sent.
dropped=
snapshot() {
  : > "$d/drop"
  run_pack
  [ "$scan_off" = 1 ] && return 0
  set +e
  py "$CORE" --snapshot "$d/k/s.tgz" "$d/hits" > "$d/count"; rc=$?
  set -e
  if [ "$rc" = 3 ] && [ -s "$d/hits" ]; then
    cp "$d/hits" "$d/drop"
    run_pack
    dropped=$(tr '\001-\037\177' '?' < "$d/drop" | tr '\0' '\n' | sed '/^$/d' | awk 'NR > 1 { printf ", " } { printf "%s", $0 }')
    set +e
    py "$CORE" --snapshot "$d/k/s.tgz" "$d/hits" > "$d/count"; rc=$?
    set -e
  fi
  case $rc in
    0) ;;
    *) die "omb-upload: could not scan the repository snapshot clean for credentials, so nothing was sent" ;;
  esac
}

kb() { awk -v b="$1" 'BEGIN { if (b < 1048576) printf "%.0f KB", (b + 1023) / 1024; else printf "%.1f MB", b / 1048576 }'; }
files() { [ "$1" = 1 ] && printf '1 %sfile' "${2:+$2 }" || printf '%s %sfiles' "$1" "${2:+$2 }"; }
npat=$(set -f; set -- $OMB_SECRETS; echo $#)
manifest() { # $1: what the snapshot part says
  line="OhMyBug upload → $HOST: diff $(kb "$diff_bytes") ($(files "$nfiles"))$1"
  [ -n "$ctx_sent" ] && line="$line, context files: $ctx_sent"
  [ -n "$diff_dropped" ] && line="$line. Left out of the diff as secret-named: $diff_dropped"
  [ -n "$diff_notutf8" ] && line="$line. Left out of the diff as not UTF-8 text: $diff_notutf8"
  [ -n "$diff_new" ] && line="$line. The diff includes $diff_new"
  [ -n "$ctx_skipped" ] && line="$line. Not sent (secret-named, not listed by git, not a regular file, through a symlink, or not UTF-8): $ctx_skipped"
  if [ "$scan_off" = 1 ]; then
    line="$line. Credential scan: off (OHMYBUG_SECRET_SCAN=0)."
  elif [ -n "$dropped" ]; then
    line="$line. Credential scan: the diff is clean; left out of the snapshot for a credential match: $dropped."
  else
    line="$line. Credential scan: clean."
  fi
  printf '%s\n' "$line"
}
snapline() {
  t=$(cat "$d/k/t")
  total=$(git --git-dir="$d/k/g" ls-tree -r "$t" | grep -c ' blob ' || :)
  size=$(kb "$(wc -c < "$d/k/s.tgz" | tr -d ' ')")
  # The file count is the scanner's (it read every member); with the scan off there is none.
  if [ "$scan_off" = 1 ]; then
    printf ' + repository snapshot of %s, %s packed. Left out: git-ignored files, submodules, secret-named files' "$(files "$total")" "$size"
  else
    packed=$(cat "$d/count")
    printf ' + repository snapshot of %s, %s packed. Left out: git-ignored files, submodules, %s' "$(files "$packed")" "$size" "$(files "$((total - packed))" secret-named)"
  fi
  printf ' (.env*, *.pem, *.key and %s more patterns), LFS content (pointers only)' "$((npat - 3))"
  if [ "$nogit" = 1 ]; then printf '; folder without git: top-level dot-folders, node_modules, __pycache__ and build output also left out'; fi
}

# One request per door, no retry and no overall time limit: the server's own
# limits end a slow transfer (408 at 300 s); a connection that moves no byte
# for 120 s (a stalled answer) ends as no answer. A status curl
# printed is the answer even when the transfer then failed (an early 409, a
# 413 or a 408 close the connection mid-upload), except a 2xx: that body was
# cut, so it is no answer (000). A 1xx as the last status is no answer either. The body and header files are new per request.
req() { # method url [file content-type] -> $code, body in $d/body, headers in $d/hdr
  : > "$d/body"; : > "$d/hdr"
  if [ $# -gt 2 ]; then
    code=$(curl -q -sS --connect-timeout 10 --speed-limit 1 --speed-time 120 -o "$d/body" -D "$d/hdr" -w '%{http_code}' -X "$1" -H "content-type: $4" --data-binary @"$3" "$2") || case $code in [3-5][0-9][0-9]) ;; *) code=000 ;; esac
  else
    code=$(curl -q -sS --connect-timeout 10 --speed-limit 1 --speed-time 120 -o "$d/body" -D "$d/hdr" -w '%{http_code}' -X "$1" "$2") || case $code in [3-5][0-9][0-9]) ;; *) code=000 ;; esac
  fi
  case $code in 1??) code=000 ;; esac
}
# A string field of the JSON answer, one line, control bytes as spaces; empty
# when absent. Only compared or printed, never evaluated.
field() { py -c 'import json, re, sys
try: v = json.load(open(sys.argv[1], encoding="utf-8")).get(sys.argv[2])
except Exception: v = None
print(re.sub(r"[\x00-\x1f\x7f]", " ", v) if isinstance(v, str) else "")' "$d/body" "$1"; }
body() { [ -s "$d/body" ] && { tr '\n' ' ' < "$d/body"; echo; }; :; }
# Seconds only, at most 9 digits; anything else (a date, a longer number) is not read.
retry_after() { sed -n 's/^[Rr][Ee][Tt][Rr][Yy]-[Aa][Ff][Tt][Ee][Rr]:[[:space:]]*\([0-9]\{1,9\}\)[[:space:]]*$/\1/p' "$d/hdr" 2>/dev/null | tail -n 1; }
rerun() { body; die "omb-upload: no final answer from the server. Call get_findings for this review: with awaiting_upload true, run the same command again${1:+ in about $1 seconds}; otherwise do what it says." 75; }
GONE="the ticket is used or expired; the payload was not sent. Call get_findings for this review: if it is running, watch it; else submit again."
slow() { die "omb-upload: the $1 did not reach the server in 5 minutes on this connection; the same command would take as long. Tell the user: diff mode at https://$HOST/me/policy, or push and hunt the pushed commit."; }

# The retire door, only on a digest mismatch: one DELETE, and the payload is never sent.
retire() {
  req DELETE "$url"
  case $code in
    200) nx=$(field next); if [ -n "$nx" ]; then printf '%s\n' "$nx"; else body; fi
         die "omb-upload: the ticket held a snapshot of another state of this working copy, so it was retired and nothing was hunted. Submit again as above and run this command with the new upload_url." ;;
    404|410) body; die "omb-upload: $GONE" ;;
    429|503) rerun "$(retry_after)" ;;
    000|5??) rerun ;;
    *) body; die "omb-upload: the request to retire the ticket was refused (HTTP $code, above), and the payload was not sent. The ticket holds a snapshot of another state of this working copy: call get_findings for this review and tell the user." ;;
  esac
}

send_snapshot() {
  req POST "$url/repo" "$d/k/s.tgz" application/gzip
  case $code in
    200) ;;
    409) [ "$(field code)" = snapshot_taken ] || { body; die "omb-upload: the snapshot was refused (HTTP 409, above); the payload was not sent."; }
         have=$(field sha256)
         [ -n "$have" ] || { body; die "omb-upload: the ticket already holds a snapshot and the server did not say which; the payload was not sent. Call get_findings for this review."; }
         [ "$have" = "$sha" ] || retire
         echo "omb-upload: the server already holds this snapshot, byte for byte; sending the payload." ;;
    404|410) body; die "omb-upload: $GONE" ;;
    413) body; die "omb-upload: the snapshot was refused (HTTP 413, above); the payload was not sent. The same command would get the same answer." ;;
    408) slow snapshot ;;
    429|503) rerun "$(retry_after)" ;;
    000|5??) rerun ;;
    *) body; die "omb-upload: the snapshot was refused (HTTP $code, above); the payload was not sent." ;;
  esac
}

if [ -n "$snap" ]; then
  snapshot
  # The digest of the exact file posted, as the server hashes what it stores.
  sha=$(py -c 'import hashlib, sys
h = hashlib.sha256()
with open(sys.argv[1], "rb") as f:
    for b in iter(lambda: f.read(1 << 20), b""):
        h.update(b)
print(h.hexdigest())' "$d/k/s.tgz")
  manifest "$(snapline)"
else
  manifest ", no repository snapshot (diff mode)"
fi
if [ "$dry" = 1 ]; then
  cat "$d/names"
  exit 0
fi
[ -n "$snap" ] && send_snapshot
req POST "$url" "$d/payload.json" application/json
case $code in
  200) body; exit 0 ;;
  409) if [ -z "$snap" ] && [ "$(field code)" = snapshot_required ]; then
         body; die "omb-upload: diff mode was turned off after this ticket was handed out. Call get_findings for this review and run the command again with the snapshot value it gives, without context files."
       fi
       body; die "omb-upload: the payload was refused (HTTP 409, above)." ;;
  404|410) body; die "omb-upload: the ticket is used or expired. Call get_findings for this review: if it is running, watch it; else submit again." ;;
  413) body; die "omb-upload: the payload was refused (HTTP 413, above). The same command would get the same answer." ;;
  408) slow payload ;;
  429|503) rerun "$(retry_after)" ;;
  000|5??) rerun ;;
  *) body; die "omb-upload: the payload was refused (HTTP $code, above)." ;;
esac
