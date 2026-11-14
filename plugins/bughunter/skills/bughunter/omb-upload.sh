#!/bin/sh
# omb-upload.sh <upload_url> <required|off> <diff.patch> [context-file ...]
#
# Sends a payload hunt's bytes to its upload ticket: the repository snapshot
# (with `required`), then {diff, files}. The skill runs this file; it never runs
# a command a tool answer hands it. Only two values come from the server: the
# upload URL, whose host is pinned below, and required|off. Neither is ever
# evaluated. It sits in the skill folder, beside its detector (omb_scan.py), so
# every install that has the skill has both.
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
# Boundary: POSIX sh (dash, bash 3.2+, busybox ash), git >= 2.25, python3 >=
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
# The server's SNAPSHOT_SECRETS and the skill's OMB_SECRETS, name for name
# (omb-upload-test.sh holds the parity check).
OMB_SECRETS='.env* *secret* *credential* id_rsa* id_dsa* id_ecdsa* id_ed25519* *.pem *.key *.p12 *.pfx
  .npmrc .netrc .pgpass .pypirc .git-credentials *.tfstate* *.tfvars* kubeconfig .kube .docker
  *.ppk *.jks *.keystore .ssh .aws .gnupg'

die() { printf '%s\n' "$1" >&2; exit "${2:-1}"; }
# -I: no PYTHON* variables and neither this folder nor the user's site on
# sys.path. The script runs inside the user's repository, where a json.py would
# otherwise be imported in place of the standard one.
py() { python3 -I "$@"; }
[ $# -ge 3 ] || die "usage: omb-upload.sh <upload_url> <required|off> <diff.patch> [context-file ...]"
url=$1 patch=$3
# The one dispatch point: argv[2] is read here and nowhere else. snap says
# what goes to <upload_url>/repo: whole = the working copy, empty = nothing
# (diff mode). A partial arm goes here: it builds its path list and sets
# snap=partial, or snap=whole on an empty list or a list failure.
case $2 in
  required) snap=whole ;;
  off) snap= ;;
  *) die "omb-upload: the second argument is required or off, got '$2'; nothing was sent" ;;
esac
shift 3
case $url in "https://$HOST/u/"*) tok=${url#"https://$HOST/u/"} ;; *) die "omb-upload: not an upload URL of $HOST; nothing was sent" ;; esac
case $tok in ''|*[!A-Za-z0-9_-]*) die "omb-upload: not an upload URL of $HOST; nothing was sent" ;; esac
[ -f "$patch" ] && [ -r "$patch" ] || die "omb-upload: cannot read the diff file $patch; nothing was sent"
command -v python3 >/dev/null 2>&1 || die "omb-upload: python3 not found, so nothing could be scanned and nothing was sent" 4
py -c 'import sys; sys.exit(sys.version_info < (3, 7))' || die "omb-upload: python3 3.7 or newer is needed; nothing was sent" 4
command -v curl >/dev/null 2>&1 || die "omb-upload: curl not found, so nothing could be sent" 4
# The detector: hooks/omb_scan.py of the same plugin install.
CORE=$(cd "$(dirname "$0")" && pwd)/../../hooks/omb_scan.py

d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
trap 'exit 1' HUP INT TERM

# A folder without git: the server's noGitWrapper. Only on "not a git
# repository" (read in the C locale, so a translated git says it the same way);
# a repository git refuses to read (an ownership check) stops here rather than
# being packed without its .gitignore.
if ! err=$(LC_ALL=C git rev-parse --git-dir 2>&1 >/dev/null); then
  case $err in *"not a git repository"*) ;; *) die "omb-upload: git cannot read this repository ($err); nothing was sent" ;; esac
  nogit=1
  export GIT_DIR="$d/w"
  git init -q --bare "$GIT_DIR"
  # GIT_WORK_TREE after the init: `git init` refuses to run while it is set.
  mkdir -p "$GIT_DIR/info"; printf '/.*/\nnode_modules/\n__pycache__/\n/venv/\n/target/\n/dist/\n/build/\n' >> "$GIT_DIR/info/exclude"; export GIT_WORK_TREE="$PWD"
else
  nogit=0
fi

# The packing step: the server's snapshotPack, statement for statement, in a
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
    h=; [ -n "${HOME:-}" ] && h=$(cd "$HOME" 2>/dev/null && pwd -P) || :; [ -n "$h" ] || { echo "refusing to pack: HOME is not set to a folder this shell can enter, so the home-folder check cannot run; if this folder is the project, run export OMB_SNAPSHOT_HOME_OK=1 in this shell, then the command again" >&2; exit 1; }
    p=$(pwd -P); case "$h/" in "${p%/}/"*) echo "refusing to pack $p: it is your home folder or a folder above it; run this from the project folder, or, if this folder is the project itself (a container checkout), run export OMB_SNAPSHOT_HOME_OK=1 in this shell, then the command again" >&2; exit 1;; esac
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
[ -n "$snap" ] && [ $# -gt 0 ] && echo "omb-upload: context files are not sent with a repository snapshot, it holds them: $*" >&2
# Bytes in, bytes out: the diff and each context file are read as bytes, so CRLF
# and a lone CR survive. JSON carries text, so a diff that is not valid UTF-8
# refuses, naming its file; a context file that is not is left out and named.
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
    p = p.rstrip("\t")
    if len(p) > 1 and p[0] == '"' and p[-1] == '"':
        p = codecs.escape_decode(p[1:-1].encode("utf-8"))[0].decode("utf-8", "replace")
    return p[2:] if p[:2] in ("a/", "b/") else p

def names(sec):
    # Header lines only, before the first hunk: inside one, "--- x" is a removed
    # "-- x" line and "+++ x" an added "++ x", never a file name.
    head = sec.split("\n@@", 1)[0].split("\n")
    first = head[0]
    out = []
    m = re.match(r"diff --git (.*)$", first)
    if m:
        h = m.group(1)
        if h.startswith('"'):
            out += [unq(x) for x in re.findall(r'"(?:[^"\\]|\\.)*"|\S+', h)]
        else:
            i = h.rfind(" b/")
            out += [unq(h[:i]), unq(h[i + 1:])] if i > 0 else [unq(h)]
    for line in head[1:]:
        for pre in ("--- ", "+++ "):
            if line.startswith(pre):
                out.append(unq(line[len(pre):]))
    return [n for n in out if n and n != "/dev/null"]

raw = open(patch, "rb").read()
secs = re.split(rb"(?m)^(?=diff --git )", raw)
kept, dropped, nfiles = [], [], 0
for sec in secs:
    try:
        text = sec.decode("utf-8")
    except UnicodeDecodeError:
        who = names(sec.decode("utf-8", "replace")) or ["the diff"]
        sys.stderr.write("omb-upload: the diff of %s is not valid UTF-8 text, so it cannot be sent; nothing was sent. "
                         "Leave that file out of the diff, or convert it, and run the same command again.\n" % who[-1])
        sys.exit(1)
    n = names(text) if text.startswith("diff --git ") else []
    if any(secret(x) for x in n):
        dropped.append(n[-1])
        continue
    nfiles += bool(n)
    kept.append(text)
diff = "".join(kept)
if not diff.strip():
    sys.stderr.write("omb-upload: the diff is empty, or nothing is left of it once secret-named files are out, so there is nothing to hunt; nothing was sent\n")
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
            p = os.path.join(top, rel)
            # A path outside the repository ("../x") is never in git's listing.
            if not secret(rel) and os.fsencode(rel) in listed and stat.S_ISREG(os.lstat(p).st_mode):
                files.append({"path": rel, "content": open(p, "rb").read().decode("utf-8")})
                sent.append(rel)
                continue
        except (OSError, UnicodeDecodeError):
            pass
        skipped.append(a)
# A quoted git name can decode to control bytes: one line per field below, and one line to the user.
clean = lambda xs: [re.sub(r"[\x00-\x1f\x7f]", "?", x) for x in xs]
sent, skipped, dropped = clean(sent), clean(skipped), clean(dropped)
json.dump({"diff": diff, "files": files}, open(d + "/payload.json", "w", encoding="utf-8"), ensure_ascii=False)
with open(d + "/meta", "w", encoding="utf-8") as f:
    f.write("\n".join([str(nfiles), ", ".join(sent), ", ".join(skipped), ", ".join(dropped), str(len(diff.encode("utf-8")))]) + "\n")
PY
{ IFS= read -r nfiles; IFS= read -r ctx_sent; IFS= read -r ctx_skipped; IFS= read -r diff_dropped; IFS= read -r diff_bytes; } < "$d/meta" || :

scan_off=0
[ "${OHMYBUG_SECRET_SCAN:-1}" = 0 ] && scan_off=1
if [ "$scan_off" = 0 ]; then
  [ -f "$CORE" ] || die "omb-upload: the credential detector (hooks/omb_scan.py) is not installed beside this skill, so nothing could be scanned and nothing was sent"
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
    dropped=$(tr '\001-\037\177' '?' < "$d/drop" | tr '\0' '\n' | sed '/^$/d' | paste -sd, - | sed 's/,/, /g')
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
    printf ' + repository snapshot %s, %s packed. Left out: git-ignored files, submodules, %s' "$(files "$packed")" "$size" "$(files "$((total - packed))" secret-named)"
  fi
  printf ' (.env*, *.pem, *.key and %s more patterns), LFS content (pointers only)' "$((npat - 3))"
  if [ "$nogit" = 1 ]; then printf '; folder without git: top-level dot-folders, node_modules, __pycache__ and build output also left out'; fi
}

# One request per door, no retry and no time limit but the connect one: the
# server's own limits end a slow transfer (408 at 300 s). A status curl
# printed is the answer even when the transfer then failed (an early 409, a
# 413 or a 408 close the connection mid-upload), except a 2xx: that body was
# cut, so it is no answer (000). The body and header files are new per request.
req() { # method url [file content-type] -> $code, body in $d/body, headers in $d/hdr
  : > "$d/body"; : > "$d/hdr"
  if [ $# -gt 2 ]; then
    code=$(curl -sS --connect-timeout 10 -o "$d/body" -D "$d/hdr" -w '%{http_code}' -X "$1" -H "content-type: $4" --data-binary @"$3" "$2") || case $code in [13-5][0-9][0-9]) ;; *) code=000 ;; esac
  else
    code=$(curl -sS --connect-timeout 10 -o "$d/body" -D "$d/hdr" -w '%{http_code}' -X "$1" "$2") || case $code in [13-5][0-9][0-9]) ;; *) code=000 ;; esac
  fi
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
slow() { die "omb-upload: the $1 did not reach the server in 5 minutes on this connection; the same command would take as long. Tell the user: a partial upload, diff mode at https://$HOST/me/policy, or push and hunt the pushed commit."; }

# The retire door, only on a digest mismatch: one DELETE, and the payload is never sent.
retire() {
  req DELETE "$url"
  case $code in
    200) nx=$(field next); if [ -n "$nx" ]; then printf '%s\n' "$nx"; else body; fi
         die "omb-upload: the ticket held a snapshot of another state of this working copy, so it was retired and nothing was hunted. Submit again as above and run this command with the new upload_url." ;;
    404|410) body; die "omb-upload: $GONE" ;;
    *) rerun ;;
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
  sha=$(py -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$d/k/s.tgz")
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
