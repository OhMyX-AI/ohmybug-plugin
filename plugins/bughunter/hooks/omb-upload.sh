#!/bin/sh
# omb-upload.sh <upload_url> <required|off> <diff.patch> [context-file ...]
#
# Sends a payload hunt's bytes to its upload ticket: the repository snapshot
# (with `required`), then {diff, files}. The skill runs this file; it never runs
# a command a tool answer hands it. Only two values come from the server: the
# upload URL, whose host is pinned below, and required|off. Neither is ever
# evaluated.
#
# Order, all before the first POST: build the payload, scan it, pack the
# snapshot, scan that, print one manifest line. A credential in the payload
# refuses (exit 3). A credential in a snapshot file leaves that file out: the
# snapshot is packed again without it, scanned again, and the file is named in
# the manifest. What could not be scanned is not sent.
#
# env: OMB_SNAPSHOT_PATHS=<file>  one repo-relative path per line: pack only these
#      OMB_SNAPSHOT_HOME_OK=1     the project is the home folder (a container)
#      OHMYBUG_SECRET_SCAN=0      no credential scan (the manifest says so)
# exit: 0 payload accepted | 1 refused, the last line says why | 3 credential in
#       the payload | 4 no python3 | 75 busy or unreachable: run the same command again
set -eu
umask 077

HOST=mcp.ohmybug.ai
# The server's SNAPSHOT_SECRETS and the skill's OMB_SECRETS, name for name
# (omb-upload-test.sh holds the parity check).
OMB_SECRETS='.env* *secret* *credential* id_rsa* id_dsa* id_ecdsa* id_ed25519* *.pem *.key *.p12 *.pfx
  .npmrc .netrc .pgpass .pypirc .git-credentials *.tfstate* *.tfvars* kubeconfig .kube .docker
  *.ppk *.jks *.keystore .ssh .aws .gnupg'

die() { printf '%s\n' "$1" >&2; exit "${2:-1}"; }
[ $# -ge 3 ] || die "usage: omb-upload.sh <upload_url> <required|off> <diff.patch> [context-file ...]"
url=$1 mode=$2 patch=$3
shift 3
case $mode in required|off) ;; *) die "omb-upload: the second argument is required or off, got '$mode'; nothing was sent" ;; esac
case $url in "https://$HOST/u/"*) tok=${url#"https://$HOST/u/"} ;; *) die "omb-upload: not an upload URL of $HOST; nothing was sent" ;; esac
case $tok in ''|*[!A-Za-z0-9_-]*) die "omb-upload: not an upload URL of $HOST; nothing was sent" ;; esac
case $patch in /*) ;; *) patch=$PWD/$patch ;; esac
[ -f "$patch" ] && [ -r "$patch" ] || die "omb-upload: cannot read the diff file $patch; nothing was sent"
paths=${OMB_SNAPSHOT_PATHS:-}
if [ -n "$paths" ]; then
  case $paths in /*) ;; *) paths=$PWD/$paths ;; esac
  # An empty list would be no pathspec at all: the whole repository.
  grep -q . "$paths" 2>/dev/null || die "omb-upload: OMB_SNAPSHOT_PATHS names no readable, non-empty path list; nothing was sent"
fi
command -v python3 >/dev/null 2>&1 || die "omb-upload: python3 not found, so nothing could be scanned and nothing was sent" 4
SCAN=$(cd "$(dirname "$0")" && pwd)/secret-scan.sh
[ -f "$SCAN" ] || die "omb-upload: secret-scan.sh is missing beside this script; nothing was sent"

d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
trap 'exit 1' HUP INT TERM

# A folder without git: the server's noGitWrapper. Only on "not a git
# repository"; a repository git refuses to read (an ownership check) stops here
# rather than being packed without its .gitignore.
if ! err=$(git rev-parse --git-dir 2>&1 >/dev/null); then
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
# pack), removed from the temporary index before write-tree; and the tree id
# kept in "$k/t" for the manifest. ${HOME:-} because this script runs set -u.
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
  if [ -s "$drop" ]; then git $s update-index -z --force-remove --stdin < "$drop"; fi
  t=$(git $s write-tree); printf '%s\n' "$t" > "$k/t"; unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
  { git init -q --bare $g "$k/g" 2>/dev/null || git init -q --bare "$k/g"; }; mkdir -p "$k/g/info"; printf '%s\n%s\n' "$o" "$k/o" > "$k/g/objects/info/alternates"
  echo '* -filter -text -ident -working-tree-encoding -export-ignore -export-subst' > "$k/g/info/attributes"
  set --
  if [ -n "$paths" ]; then
    # shortcut: paths go through argv, about 10k paths; filter the temp index instead when partial becomes the default
    while IFS= read -r q || [ -n "$q" ]; do [ -n "$q" ] && set -- "$@" ":(top,literal)$q"; done < "$paths"
  else
    set -- .
  fi
  # set -f: a name like *secret* must reach git as a pattern, never be expanded here.
  set -f
  for q in $OMB_SECRETS; do set -- "$@" ":(exclude,icase,glob)**/$q" ":(exclude,icase,glob)**/$q/**"; done
  set +f
  git --git-dir="$k/g" archive --format=tar.gz -o "$k/s.tgz" "$t" -- "$@"
)

# The payload: the diff, and context files only in diff mode (a snapshot holds them).
[ -s "$patch" ] || die "omb-upload: the diff is empty, so there is nothing to hunt; nothing was sent"
: > "$d/listed"
if [ "$mode" = off ] && [ $# -gt 0 ]; then
  ( cd "$(git rev-parse --show-toplevel)" && git ls-files -z -co --exclude-standard ) > "$d/listed"
fi
[ "$mode" = required ] && [ $# -gt 0 ] && echo "omb-upload: context files are not sent with a repository snapshot, it holds them: $*" >&2
top=
[ "$mode" = off ] && [ $# -gt 0 ] && top=$(git rev-parse --show-toplevel)
python3 - "$d" "$patch" "$mode" "$top" "$@" <<'PY'
import json, os, sys
d, patch, mode, top, args = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5:]
files, sent, skipped = [], [], []
if mode == "off" and args:
    listed = set(open(d + "/listed", "rb").read().split(b"\0"))
    top = os.path.realpath(top)
    for a in args:
        full = os.path.abspath(a)
        rel = os.path.relpath(full, top)
        # Listed by git, a regular file, and no symlink in any part of the path.
        if (os.path.realpath(full) != full or rel.startswith("..") or not os.path.isfile(full)
                or os.fsencode(rel) not in listed):
            skipped.append(a)
            continue
        with open(full, encoding="utf-8", errors="replace") as f:
            files.append({"path": rel, "content": f.read()})
        sent.append(rel)
diff = open(patch, encoding="utf-8", errors="replace").read()
json.dump({"diff": diff, "files": files}, open(d + "/payload.json", "w", encoding="utf-8"))
with open(d + "/context", "w") as f:
    f.write("\n".join([", ".join(sent), ", ".join(skipped)]))
PY
{ IFS= read -r ctx_sent; IFS= read -r ctx_skipped; } < "$d/context" || :

scan_off=0
[ "${OHMYBUG_SECRET_SCAN:-1}" = 0 ] && scan_off=1
set +e
bash "$SCAN" --payload "$d/payload.json"; rc=$?
set -e
case $rc in
  0) ;;
  3) die "omb-upload: the diff or a context file carries what looks like a credential (above), so nothing was sent. Remove it or replace each value with [REDACTED], then run the same command again; the ticket stays valid." 3 ;;
  4) die "omb-upload: python3 not found, so nothing could be scanned and nothing was sent" 4 ;;
  *) die "omb-upload: could not scan the payload for credentials, so nothing was sent" ;;
esac

# Pack and scan the snapshot. A hit leaves its files out: pack again without
# them, and that second pack is what gets scanned and sent.
dropped=
snapshot() {
  : > "$d/drop"
  pack "$d/k" "$d/drop" || die "omb-upload: the repository could not be packed (above); nothing was sent"
  set +e
  bash "$SCAN" --snapshot "$d/k/s.tgz" "$d/hits" 2>/dev/null; rc=$?
  set -e
  if [ "$rc" = 3 ] && [ -s "$d/hits" ]; then
    cp "$d/hits" "$d/drop"
    pack "$d/k" "$d/drop" || die "omb-upload: the repository could not be packed (above); nothing was sent"
    dropped=$(tr '\0' '\n' < "$d/drop" | sed '/^$/d' | paste -sd, - | sed 's/,/, /g')
    set +e
    bash "$SCAN" --snapshot "$d/k/s.tgz" "$d/hits" 2>/dev/null; rc=$?
    set -e
  fi
  case $rc in
    0) ;;
    4) die "omb-upload: python3 not found, so nothing could be scanned and nothing was sent" 4 ;;
    *) die "omb-upload: could not scan the repository snapshot for credentials, so nothing was sent" ;;
  esac
}

kb() { awk -v b="$1" 'BEGIN { if (b < 1048576) printf "%.0f KB", (b + 1023) / 1024; else printf "%.1f MB", b / 1048576 }'; }
manifest() { # $1: what the snapshot part says
  size=$(wc -c < "$patch" | tr -d ' ')
  nfiles=$(grep -c '^diff --git ' "$patch" || :)
  line="OhMyBug upload → $HOST: diff $(kb "$size") ($nfiles files)"
  line="$line$1"
  [ -n "$ctx_sent" ] && line="$line, context files: $ctx_sent"
  [ -n "$ctx_skipped" ] && line="$line. Not sent (not listed by git, not a regular file, or through a symlink): $ctx_skipped"
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
  packed=$(tar -tzf "$d/k/s.tgz" | grep -vc '/$' || :)
  size=$(kb "$(wc -c < "$d/k/s.tgz" | tr -d ' ')")
  if [ -n "$paths" ]; then
    printf ' + repository snapshot %s of %s files (path list), %s packed. Left out: git-ignored files, submodules, secret-named files' "$packed" "$total" "$size"
  else
    printf ' + repository snapshot %s files, %s packed. Left out: git-ignored files, submodules, %s secret-named files' "$packed" "$size" "$((total - packed))"
  fi
  printf ' (.env*, *.pem, *.key and 24 more patterns), LFS content (pointers only)'
  if [ "$nogit" = 1 ]; then printf '; folder without git: top-level dot-folders, node_modules, __pycache__ and build output also left out'; fi
}

# One POST with the retry rule: 429, a 5xx other than the payload's 503, or no
# answer at all is retried up to 4 times, waiting Retry-After clamped to 1-30 s.
post() { # door-name url file content-type -> $code, body in $d/body
  n=0
  while :; do
    code=$(curl -sS -o "$d/body" -D "$d/hdr" -w '%{http_code}' -X POST -H "content-type: $4" --data-binary @"$3" "$2") || code=000
    case $code in
      503) [ "$1" = payload ] && return 0 ;;
      429|5??|000) ;;
      *) return 0 ;;
    esac
    n=$((n + 1))
    [ "$n" -gt 4 ] && return 0
    ra=$(sed -n 's/^[Rr][Ee][Tt][Rr][Yy]-[Aa][Ff][Tt][Ee][Rr]:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$d/hdr" 2>/dev/null | tail -n 1)
    [ -n "$ra" ] || ra=30
    [ "$ra" -lt 1 ] && ra=1
    [ "$ra" -gt 30 ] && ra=30
    sleep "$ra"
  done
}
answer_code() { python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("code") or "")
except Exception: print("")' "$d/body"; }
body() { tr '\n' ' ' < "$d/body" 2>/dev/null; echo; }
gone() { body; die "omb-upload: the ticket is used or expired. The payload may have arrived: call get_findings for this review; if it is running, watch it, else submit again."; }
busy() { body; die "omb-upload: the server is busy or unreachable; the ticket stays valid: run the same command again${1:+ in about $1 seconds}." 75; }

send_snapshot() {
  post repo "$url/repo" "$d/k/s.tgz" application/gzip
  case $code in
    200) ;;
    409) [ "$(answer_code)" = snapshot_taken ] || { body; die "omb-upload: the snapshot was refused (above); the payload was not sent."; } ;;
    404|410) gone ;;
    429|5??|000) busy ;;
    413) body; die "omb-upload: the repository is too large to send (above). Diff mode is the user's own switch, on the link above; or commit, push and hunt the pushed commit with no upload." ;;
    *) body; die "omb-upload: the snapshot was refused (above); the payload was not sent." ;;
  esac
}

if [ "$mode" = required ]; then
  snapshot
  manifest "$(snapline)"
  send_snapshot
else
  manifest ", no repository snapshot (diff mode)"
fi
post payload "$url" "$d/payload.json" application/json
if [ "$code" = 409 ] && [ "$(answer_code)" = snapshot_required ] && [ "$mode" = off ]; then
  # Diff mode was turned off after the ticket was minted: the snapshot goes
  # first now, scanned like any other, and the payload once more.
  mode=required
  snapshot
  manifest "$(snapline)"
  send_snapshot
  post payload "$url" "$d/payload.json" application/json
fi
case $code in
  200) body; exit 0 ;;
  404|410) gone ;;
  503) ra=$(sed -n 's/^[Rr][Ee][Tt][Rr][Yy]-[Aa][Ff][Tt][Ee][Rr]:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$d/hdr" 2>/dev/null | tail -n 1); busy "${ra:-120}" ;;
  429|5??|000) busy ;;
  *) body; die "omb-upload: the payload was refused (above)." ;;
esac
