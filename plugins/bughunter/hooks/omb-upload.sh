#!/bin/sh
# omb-upload.sh <upload_url> <required|off> --base <branch> [context-file ...]
# omb-upload.sh <upload_url> <required|off> <diff.patch> [context-file ...]
#
# Sends a payload hunt's bytes to its upload ticket: the repository snapshot
# (with `required`), then {diff, files}. With --base it writes the diff itself
# (the working tree against the merge base with origin/<branch>); a diff file
# is for the no-branch ladder. The skill runs this file; it never runs a
# command a tool answer hands it. Only two values come from the server: the
# upload URL, whose host is pinned below, and required|off. Neither is ever
# evaluated, and the branch name is refused unless it has the shape of a ref.
# It sits in hooks/, beside its detector (omb_scan.py): the merge gate counts
# both as code. A skill-only install has neither, so it cannot upload.
#
# Order, all before the first request: build the payload, scan it, pack the
# snapshot, scan that, take its sha256, print one manifest line. A credential
# in the payload refuses (exit 3). A credential in a snapshot file leaves that
# file out: the snapshot is packed again without it, scanned again, and the
# file is named in the manifest. Secret-named files are left out of the diff as
# they are out of the snapshot, and named. What could not be scanned is not
# sent.
#
# No clock and no retry: one request per door, and the ticket's lifetime on
# the server is the only clock. The snapshot is packed from a commit with a
# fixed date, so the same working copy gives the same bytes on a rerun. A
# ticket that already holds a snapshot answers 409 snapshot_taken with that
# snapshot's sha256: equal to ours, the payload goes; different, the ticket is
# retired (DELETE <upload_url>) and nothing is hunted, so a new diff never
# pairs with an old snapshot; absent (an older server), the script stops.
#
# Boundary: POSIX sh (CI runs it under dash and bash on Linux and bash 3.2 on
# macOS; other shells untested), git >= 2.25, python3 >=
# 3.7, curl, gzip, on macOS or Linux. Anything else is unsupported; where the
# script can tell (python3 older than 3.7, no python3, no curl) it refuses with
# one sentence, and nothing unscanned is sent unless the scan is off. The
# secret-name list is best effort. Assumptions, not code: a hard kill (SIGKILL)
# leaves the temporary 0700 folder behind; a full TMPDIR fails a write and
# nothing is sent; a working copy near the server's 1 GiB ceiling may not pack,
# scan and send inside the skill's 600 s call on a slow machine (the client
# then stops the call, which counts as exit 75).
#
# env: OMB_SNAPSHOT_HOME_OK=1     the project is the home folder (a container)
#      OHMYBUG_SECRET_SCAN=0      no credential scan (the manifest says so)
# exit: 0 payload accepted | 1 final, the last line says why and what to do |
#       3 credential in the payload | 4 python3 (3.7+) or curl missing |
#       75 no final answer: call get_findings, rerun only while awaiting_upload
set -eu
umask 077

HOST=mcp.ohmybug.ai
# The server's snapshot secret list and the skill's OMB_SECRETS, name for name
# (omb-upload-test.sh holds the parity check).
OMB_SECRETS='.env* *secret* *credential* id_rsa* id_dsa* id_ecdsa* id_ed25519* *.pem *.key *.p12 *.pfx
  .npmrc .netrc .pgpass .pypirc .git-credentials *.tfstate* *.tfvars* kubeconfig .kube .docker
  *.ppk *.jks *.keystore .ssh .aws .gnupg'

die() { printf '%s\n' "$1" >&2; exit "${2:-1}"; }
# -I: no PYTHON* variables and neither this folder nor the user's site on
# sys.path. The script runs inside the user's repository, where a json.py would
# otherwise be imported in place of the standard one.
py() { python3 -I "$@"; }
[ $# -ge 3 ] || die "usage: omb-upload.sh <upload_url> <required|off> (--base <branch> | <diff.patch>) [context-file ...]"
url=$1
# The one dispatch point: argv[2] is read here and nowhere else. snap says
# what goes to <upload_url>/repo: whole = the working copy, empty = nothing
# (diff mode).
case $2 in
  required) snap=whole ;;
  off) snap= ;;
  *) die "omb-upload: the second argument is required or off, got '$2'; nothing was sent" ;;
esac
shift 2
base= patch=
if [ "$1" = --base ]; then
  [ $# -ge 2 ] || die "omb-upload: --base needs a branch name; nothing was sent"
  base=$2; shift 2
  # Only the shape of a ref: no quote, space or other shell byte, no leading dash.
  case $base in ''|-*|*[!A-Za-z0-9._/-]*) die "omb-upload: '$base' is not a branch name this script accepts (letters, digits, '.', '_', '/', '-'; not starting with '-'); nothing was sent" ;; esac
else
  patch=$1; shift
fi
case $url in "https://$HOST/u/"*) tok=${url#"https://$HOST/u/"} ;; *) die "omb-upload: not an upload URL of $HOST; nothing was sent" ;; esac
case $tok in ''|*[!A-Za-z0-9_-]*) die "omb-upload: not an upload URL of $HOST; nothing was sent" ;; esac
[ -n "$base" ] || { [ -f "$patch" ] && [ -r "$patch" ]; } || die "omb-upload: cannot read the diff file $patch; nothing was sent"
command -v python3 >/dev/null 2>&1 || die "omb-upload: python3 not found, so nothing could be scanned and nothing was sent" 4
py -c 'import sys; sys.exit(sys.version_info < (3, 7))' || die "omb-upload: python3 3.7 or newer is needed; nothing was sent" 4
command -v curl >/dev/null 2>&1 || die "omb-upload: curl not found, so nothing could be sent" 4
CORE=$(cd "$(dirname "$0")" && pwd)/omb_scan.py

d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
# A stopped call is "nothing final known", as the skill reads a call stopped at 600 s.
trap 'exit 75' HUP INT TERM

if [ -n "$base" ]; then
  patch="$d/diff.patch"
  mb=$(git merge-base HEAD "origin/$base" 2>/dev/null) || die "omb-upload: no merge base with origin/$base here (is the branch fetched?); nothing was sent"
  git -c diff.relative=false -c color.ui=false diff --no-color --no-textconv --no-ext-diff "$mb" > "$patch" || die "omb-upload: git diff failed (above); nothing was sent"
fi

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
  nogit=1
  export GIT_DIR="$d/w"
  git init -q --bare "$GIT_DIR"
  # GIT_WORK_TREE after the init: `git init` refuses to run while it is set.
  mkdir -p "$GIT_DIR/info"; printf '/.*/\nnode_modules/\n__pycache__/\n/venv/\n/target/\n/dist/\n/build/\n' >> "$GIT_DIR/info/exclude"; export GIT_WORK_TREE="$PWD"
else
  nogit=0
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
  if [ "${OMB_SNAPSHOT_HOME_OK:-}" != 1 ]; then
    h=; [ -n "${HOME:-}" ] && h=$(cd "$HOME" 2>/dev/null && pwd -P) || :; [ -n "$h" ] || { echo "refusing to pack: HOME is not set to a folder this shell can enter, so the home-folder check cannot run; if this folder is the project, run the same command again as one call with OMB_SNAPSHOT_HOME_OK=1 in front of it (OMB_SNAPSHOT_HOME_OK=1 bash .../omb-upload.sh ...)" >&2; exit 1; }
    p=$(pwd -P); case "$h/" in "${p%/}/"*) echo "refusing to pack $p: it is your home folder or a folder above it; run this from the project folder, or, if this folder is the project itself (a container checkout), run the same command again as one call with OMB_SNAPSHOT_HOME_OK=1 in front of it (OMB_SNAPSHOT_HOME_OK=1 bash .../omb-upload.sh ...)" >&2; exit 1;; esac
  fi
  o=$(cd "$(git rev-parse --git-path objects)" && pwd); rm -rf "$k"; mkdir "$k"
  cp "$(git rev-parse --git-path index)" "$k/i" 2>/dev/null || :; f=$(git rev-parse --show-object-format 2>/dev/null) || :; case $f in sha1|sha256) g=--object-format=$f;; *) g=;; esac; mkdir -p "$k/o/info"; printf '%s\n' "$o" > "$k/o/info/alternates"; export GIT_INDEX_FILE="$k/i" GIT_OBJECT_DIRECTORY="$k/o"; s='-c splitIndex.maxPercentChange=100'
  git ls-files -z -t > "$k/l"; xargs -0 sh -c 'for e; do case $e in "S "*) printf "%s\0" "${e#S }";; esac; done' sh < "$k/l" > "$k/s"
  git $s update-index -z --force-remove --stdin < "$k/s"
  if git add -h 2>&1 | grep -q -E -e '--(\[no-\])?sparse'; then git $s add -A --sparse; else git $s add -A; fi
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

# The payload: the diff, and context files only in diff mode (a snapshot holds them).
: > "$d/listed"
top=
if [ -z "$snap" ] && [ $# -gt 0 ]; then
  top=$(git rev-parse --show-toplevel)
  ( cd "$top" && git ls-files -z -co --exclude-standard ) > "$d/listed"
fi
if [ -n "$snap" ] && [ $# -gt 0 ]; then
  echo "omb-upload: context files are not sent with a repository snapshot, it holds them: $*" >&2
  set --
fi
# Bytes in, bytes out: the diff and each context file are read as bytes, so CRLF
# and a lone CR survive. JSON carries text, so a file's section of the diff
# that is not valid UTF-8 is left out and named, as a context file is.
# The secret-name filter fails closed: a section of the diff that names no
# file, or a diff in terminal colours, refuses the whole upload.
# Exported, not a VAR=x prefix: dash before 0.5.11 does not pass a prefix
# assignment on a function call (py) to the process it runs.
export OMB_SECRETS
py - "$d" "$patch" "$top" "$@" <<'PY' || exit 1
import codecs, fnmatch, json, os, re, stat, sys
d, patch, top, args = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
SECRETS = os.environ["OMB_SECRETS"].split()

def secret(path):
    # git's `:(exclude,icase,glob)**/p` and `**/p/**`: any one segment matches the name.
    return any(fnmatch.fnmatchcase(seg.lower(), p.lower()) for seg in path.split("/") for p in SECRETS)

def unq(p):
    p = p.rstrip("\r\n")
    m = re.match(r'"((?:[^"\\]|\\.)*)"', p)
    if m:
        p = codecs.escape_decode(m.group(1).encode("utf-8"))[0].decode("utf-8", "replace")
    else:
        # A plain diff puts a date after a tab; git quotes a name that holds one.
        p = p.split("\t", 1)[0]
    return p[2:] if p[:2] in ("a/", "b/") else p

def names(lines):
    # Header lines only, before the first hunk: inside one, "--- x" is a removed
    # "-- x" line and "+++ x" an added "++ x", never a file name.
    out = []
    for i, line in enumerate(lines):
        if line.startswith("@@"):
            break
        if i == 0 and line.startswith("diff --git "):
            h = line[len("diff --git "):].rstrip("\r\n")
            if h.startswith('"'):
                out += [unq(x) for x in re.findall(r'"(?:[^"\\]|\\.)*"|\S+', h)]
            else:
                j = h.rfind(" b/")
                out += [unq(h[:j]), unq(h[j + 1:])] if j > 0 else [unq(h)]
        elif i == 0 and line.startswith("diff "):
            out += [unq(x) for x in line.split()[-2:]]  # diff -ruN a/x b/x
        for pre in ("--- ", "+++ "):
            if line.startswith(pre):
                out.append(unq(line[len(pre):]))
    return [n for n in out if n and n != "/dev/null"]

def clean1(x):
    x = x.encode("utf-8", "surrogateescape").decode("utf-8", "replace")
    return re.sub(r"[\x00-\x1f\x7f]", "?", x)

def say(msg):
    sys.stderr.write("omb-upload: " + msg + "; nothing was sent.\n")
    sys.exit(1)

raw = open(patch, "rb").read()
if re.search(rb"(?m)^\x1b\[", raw):
    say("the diff is in terminal colours (a git colour setting), so its file names cannot be read and a secret-named file could not be left out. Write it with git diff --no-color")
# Sections by file. A hunk's own lines are counted off its @@ header, so a
# removed "-- x" line is never read as the "--- x" header of a next file.
HUNK = re.compile(rb"^@@ -\d+(?:,(\d+))? \+\d+(?:,(\d+))? @@")
lines = re.findall(rb"[^\n]*\n|[^\n]+$", raw)  # on LF only: a lone CR is content
secs, cur, old, new = [], [], 0, 0
for i, l in enumerate(lines):
    if old > 0 or new > 0:
        # A line the counts do not allow ends the hunk and is read as a header:
        # a wrong count never swallows the next file's "diff" line.
        c, took = l[:1], True
        if c == b"-" and old > 0:
            old -= 1
        elif c == b"+" and new > 0:
            new -= 1
        elif c in (b" ", b"\n", b"\r") and old > 0 and new > 0:
            old -= 1; new -= 1
        elif c != b"\\":
            old = new = 0; took = False
        if took:
            cur.append(l)
            continue
    m = HUNK.match(l)
    if m:
        old = int(m.group(1)) if m.group(1) is not None else 1
        new = int(m.group(2)) if m.group(2) is not None else 1
        cur.append(l)
        continue
    nxt = lines[i + 1] if i + 1 < len(lines) else b""
    start = l.startswith(b"diff ") or (l.startswith(b"--- ") and nxt.startswith(b"+++ ")
                                       and any(x.startswith((b"--- ", b"@@")) for x in cur))
    if start and cur:
        secs.append(cur); cur = []
    elif not start and l.strip() and any(x.startswith(b"@@") for x in cur):
        # Past a file's hunks only the next file's header may come: a line
        # that is neither belongs to no file the filter can name.
        say("a line of the diff belongs to no file (%s), so a secret-named file in it could not be left out. Send a diff from git diff or diff -u" % clean1(l.decode("utf-8", "replace").rstrip("\r\n"))[:60])
    cur.append(l)
if cur:
    secs.append(cur)
kept, dropped, notutf8, nfiles = [], [], [], 0
for sec in secs:
    b = b"".join(sec)
    if not b.strip():
        kept.append(b.decode("utf-8", "replace"))
        continue
    n = names([x.decode("utf-8", "replace") for x in sec])
    if not n:
        say("part of the diff names no file (%s), so a secret-named file in it could not be left out. Send a diff from git diff or diff -u" % clean1(sec[0].decode("utf-8", "replace").rstrip("\r\n"))[:60])
    if any(secret(x) for x in n):
        dropped.append(n[-1])
        continue
    try:
        text = b.decode("utf-8")
    except UnicodeDecodeError:
        notutf8.append(n[-1])
        continue
    nfiles += 1
    kept.append(text)
diff = "".join(kept)
if not diff.strip():
    sys.stderr.write("omb-upload: the diff is empty, or nothing is left of it once secret-named and non-UTF-8 files are out, so there is nothing to hunt; nothing was sent\n")
    sys.exit(1)

files, sent, skipped = [], [], []
if args:  # "$d/listed" is filled in diff mode only, so with a snapshot nothing is listed
    listed = set(open(d + "/listed", "rb").read().split(b"\0"))
    top = os.path.realpath(top)
    for a in args:
        # The folder by its real path, the file by its own name: lstat below refuses
        # a symlink, and a path through a linked folder is the listed file it names.
        full = os.path.abspath(a)
        rel = os.path.relpath(os.path.join(os.path.realpath(os.path.dirname(full)), os.path.basename(full)), top)
        try:
            rel.encode("utf-8")  # a name that is not UTF-8 cannot go into JSON
            p = os.path.join(top, rel)
            # A path outside the repository ("../x") is never in git's listing.
            if not secret(rel) and os.fsencode(rel) in listed and stat.S_ISREG(os.lstat(p).st_mode):
                files.append({"path": rel, "content": open(p, "rb").read().decode("utf-8")})
                sent.append(rel)
                continue
        except (OSError, UnicodeError):
            pass
        skipped.append(a)
# A quoted git name can decode to control bytes: one line per field below, and one line to the user.
clean = lambda xs: [clean1(x) for x in xs]
sent, skipped, dropped, notutf8 = clean(sent), clean(skipped), clean(dropped), clean(notutf8)
json.dump({"diff": diff, "files": files}, open(d + "/payload.json", "w", encoding="utf-8"), ensure_ascii=False)
with open(d + "/meta", "w", encoding="utf-8") as f:
    f.write("\n".join([str(nfiles), ", ".join(sent), ", ".join(skipped), ", ".join(dropped), str(len(diff.encode("utf-8"))), ", ".join(notutf8)]) + "\n")
PY
{ IFS= read -r nfiles; IFS= read -r ctx_sent; IFS= read -r ctx_skipped; IFS= read -r diff_dropped; IFS= read -r diff_bytes; IFS= read -r diff_notutf8; } < "$d/meta" || :

scan_off=0
[ "${OHMYBUG_SECRET_SCAN:-1}" = 0 ] && scan_off=1
if [ "$scan_off" = 0 ]; then
  [ -f "$CORE" ] || die "omb-upload: the credential detector (omb_scan.py) is not installed beside this script, so nothing could be scanned and nothing was sent. Push the branch and hunt the pushed commit (rung 1), or install the full plugin."
  set +e
  py "$CORE" --payload "$d/payload.json"; rc=$?
  set -e
  case $rc in
    0) ;;
    3) die "omb-upload: the diff or a context file carries what looks like a credential (above), so nothing was sent. Remove it or replace each value with [REDACTED], then run the same command again; the ticket stays valid." 3 ;;
    *) die "omb-upload: could not scan the payload for credentials, so nothing was sent" ;;
  esac
fi

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
    code=$(curl -sS --connect-timeout 10 --speed-limit 1 --speed-time 120 -o "$d/body" -D "$d/hdr" -w '%{http_code}' -X "$1" -H "content-type: $4" --data-binary @"$3" "$2") || case $code in [3-5][0-9][0-9]) ;; *) code=000 ;; esac
  else
    code=$(curl -sS --connect-timeout 10 --speed-limit 1 --speed-time 120 -o "$d/body" -D "$d/hdr" -w '%{http_code}' -X "$1" "$2") || case $code in [3-5][0-9][0-9]) ;; *) code=000 ;; esac
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
  send_snapshot
else
  manifest ", no repository snapshot (diff mode)"
fi
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
