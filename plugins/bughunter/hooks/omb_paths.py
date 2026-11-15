"""The partial snapshot's file list: which files of the packed tree go.

omb-upload.sh runs it inside its pack step, on the pack's own bare repository,
when the ticket asked for a partial copy:

    python3 omb_paths.py <git-dir> <tree> <changed.z> <added> <keep.z> <stats>

The rule is the server's own pick for a partial repository, constant for
constant: the changed files (at most 60), the build manifests in their folders
and every folder above, then the unchanged files that use the names the added
lines call or define (at most 40 names, 4 or more characters, longest first; a
name found in more than 8 files says nothing), at most 20 of them by weight.
Then the caps, in that rank order: a file over 4 MiB is skipped, a file with a
NUL byte in its first 8000 bytes or a git-lfs pointer is skipped, and a file that would take the
total past 16 MiB is skipped while the next ones still may fit.

Inputs are git facts only: <changed.z> the diff's file names, NUL-separated;
<added> the diff's added lines, each starting with byte 0x01 (git's
--output-indicator-new), so no diff header is ever read as a line; the tree's
records from `git ls-tree -r -l -z`. Every git call runs as the caller set it
up (no user or repository setting reaches it). The names are searched in ONE
`git grep` pass over the tree, read back per name and file.

Output: <keep.z> the kept files as `<mode> <type> <id>\t<path>` records,
NUL-separated, ready for `git update-index -z --index-info`; <stats> one line:
kept, changed kept, changed in the tree, manifests kept, callers kept, files
in the tree, and why no caller search ran ("-" when it ran, "files" or
"bytes" when the tree is past that line). Nothing here reads a clock or a
random source, and every set is walked in a fixed order, so the same tree
gives the same list, and the snapshot the same bytes, on a rerun.

Exit 0 with or without records; anything else means no list (the caller packs
the whole tree).
"""
import os
import re
import subprocess
import sys

PARTIAL = {"changed": 60, "callers": 20, "bytes": 16 * 1024 * 1024, "file": 4 << 20, "names": 40}
# No caller search on a tree past either line: one grep pass reads every blob,
# about 4 s per GB on a fast laptop and several times that on two cores. A
# count of the tree, never a timer, so a rerun packs the same bytes.
MAX_FILES, MAX_BYTES = 200000, 512 * 1024 * 1024
if os.environ.get("OMB_TEST_PATHS_LIMITS"):  # the test suite only
    MAX_FILES, MAX_BYTES = (int(x) for x in os.environ["OMB_TEST_PATHS_LIMITS"].split())

# The server rule's patterns, character for character (omb-paths-test.sh holds
# the copy they must equal). JavaScript's `$` is Python's `\Z`; re.A keeps
# Python's case folding to ASCII, as JavaScript's `i` does here.
OS_MANIFEST = re.compile(r"^(package\.json|.*\.gemspec|Gemfile|pyproject\.toml|setup\.py|setup\.cfg|Cargo\.toml|go\.mod|pom\.xml|build\.gradle(\.kts)?|composer\.json|requirements\.txt|tsconfig\.json)\Z", re.A)
OS_KW = set("""self this that true false null none None True False return const function class import from export default async await
while for else elif then case break continue public private protected static final void string number boolean object print
length value values items index error errors result results data type name test tests assert expect equal should params props""".split())
OS_SKIP = re.compile(r"(^|\/)(node_modules|vendor|third_party|dist|build|\.yarn)\/|(^|\/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|Cargo\.lock|poetry\.lock|go\.sum|composer\.lock|Gemfile\.lock|uv\.lock|Pipfile\.lock|bun\.lockb?)\Z|\.(min\.js|min\.css|map|png|jpe?g|gif|ico|svg|webp|pdf|zip|gz|jar|woff2?|ttf|eot|mp4|mp3|lock|snap)\Z|_pb2\.py\Z|\.pb\.go\Z", re.A)
OS_DOC1 = re.compile(r"\.(md|mdx|rst|txt|adoc)\Z|(^|\/)(licen[cs]e|changelog|notice)\Z", re.A | re.I)
OS_DOC2 = re.compile(r"(^|\/)(LICEN[CS]E|CHANGELOG|NOTICE)([-_.][^/]*)?\Z", re.A)
NAME = re.compile(r"(?<![A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]{3,})\s*\(|(?:def|function|class|interface|fn|func|fun)\s+([A-Za-z_][A-Za-z0-9_]{3,})")


def os_doc(p):
    return bool(OS_DOC1.search(p) or OS_DOC2.search(p))


def dirname(p):
    return p.rsplit("/", 1)[0] if "/" in p else ""


def added_names(added):
    """Names on the added lines: calls and definitions, longest first, at most 40."""
    found = set()
    for ln in added.split(b"\n"):
        if not ln.startswith(b"\x01"):
            continue
        for m in NAME.finditer(ln.decode("utf-8", "surrogateescape")):
            name = m.group(1) or m.group(2)
            if name not in OS_KW:
                found.add(name)
    return sorted(found, key=lambda n: (-len(n), n))[:PARTIAL["names"]]


def git(gitdir, *args, ok=(0,)):
    p = subprocess.run(["git", "--git-dir=" + gitdir] + list(args), stdout=subprocess.PIPE)
    if p.returncode not in ok:
        raise SystemExit(2)
    return p.returncode, p.stdout


def main(gitdir, tree, changed_z, added_f, keep_z, stats_f):
    # The tree's records, kept as git wrote them: path bytes are never decoded
    # to build what goes back to git.
    recs = {}  # path (str, surrogateescape) -> (mode, type, id, size, raw path)
    order = []
    for r in git(gitdir, "ls-tree", "-r", "-l", "-z", tree)[1].split(b"\0"):
        if not r:
            continue
        meta, raw = r.split(b"\t", 1)
        mode, typ, oid, size = meta.split()
        p = raw.decode("utf-8", "surrogateescape")
        recs[p] = (mode, typ, oid, size, raw)
        order.append(p)
    regular = [p for p in order if recs[p][0] in (b"100644", b"100755")]
    present = set(regular)
    changed = [n.decode("utf-8", "surrogateescape") for n in open(changed_z, "rb").read().split(b"\0") if n]
    skip = set(changed)

    # 1. The changed files in the tree (a changed symlink too; never a submodule).
    head = [p for p in changed if p in recs and recs[p][1] == b"blob"][:PARTIAL["changed"]]

    # 2. Build manifests in the folders of head and every folder above, unchanged.
    by_dir = {}
    for p in regular:
        if OS_MANIFEST.search(p.rsplit("/", 1)[-1]) and p not in skip:
            by_dir.setdefault(dirname(p), []).append(p)
    manifests, seen = [], set()
    for d in sorted(set(dirname(p) for p in head)):
        while True:
            if d not in seen:
                seen.add(d)
                manifests += [p for p in by_dir.get(d, []) if p not in manifests]
            if not d:
                break
            d = dirname(d)

    # 3-5. Callers: one grep pass for every name, read back per name and file.
    cut = "-"
    if len(regular) > MAX_FILES:
        cut = "files"
    elif sum(int(recs[p][3]) for p in regular) > MAX_BYTES:
        cut = "bytes"
    callers = []
    names = added_names(open(added_f, "rb").read()) if cut == "-" else []
    if names:
        with open(keep_z + ".names", "wb") as f:
            f.write(b"".join(n.encode() + b"\n" for n in names))
        # -F -w: each name as a fixed word; -o prints every match, so one pass
        # says which name each file holds. Records: <tree>:<path> NUL <name> LF.
        rc, out = git(gitdir, "grep", "-F", "-o", "-w", "-I", "-z", "-f", keep_z + ".names", tree, ok=(0, 1))
        pre = tree.encode() + b":"
        files_of = {}
        i = 0
        while i < len(out):
            j = out.index(b"\0", i)
            k = out.index(b"\n", j)
            path, name = out[i:j], out[j + 1:k].decode()
            i = k + 1
            if not path.startswith(pre):
                raise SystemExit(2)
            p = path[len(pre):].decode("utf-8", "surrogateescape")
            files_of.setdefault(name, []).append(p)
        hits = {}
        for name in names:
            files = [p for p in dict.fromkeys(files_of.get(name, []))
                     if p in present and p not in skip and not OS_SKIP.search(p) and not os_doc(p)]
            if not files or len(files) > 8:
                continue
            for p in files:
                hits[p] = hits.get(p, 0) + 1 / len(files)
        ranked = sorted(hits.items(), key=lambda kv: (-kv[1], kv[0].encode("utf-8", "surrogateescape")))
        callers = [p for p, _ in ranked if p not in manifests][:PARTIAL["callers"]]

    # 6. The caps, in rank order. Sizes from ls-tree (filters are off in the
    #    pack, so that is the archived size); the NUL check reads at most the
    #    first 8000 bytes of each candidate through one cat-file.
    ranked = [p for p in head + manifests + callers if int(recs[p][3]) <= PARTIAL["file"]]
    binary = set()
    if ranked:
        with open(keep_z + ".ids", "wb") as f:
            f.write(b"".join(recs[p][2] + b"\n" for p in ranked))
        with open(keep_z + ".ids", "rb") as f:
            q = subprocess.Popen(["git", "--git-dir=" + gitdir, "cat-file", "--batch"], stdin=f, stdout=subprocess.PIPE)
        for p in ranked:
            h = q.stdout.readline().split()
            if len(h) != 3 or h[0] != recs[p][2]:
                q.kill(); q.wait()
                raise SystemExit(2)
            n = int(h[2])
            data = q.stdout.read(n + 1)
            if len(data) != n + 1:
                q.kill(); q.wait()
                raise SystemExit(2)
            # A NUL byte in the first 8000 bytes, or a git-lfs pointer (the
            # content is not here): the server rule leaves both out.
            if b"\0" in data[:min(n, 8000)] or data.startswith(b"version https://git-lfs.github.com/spec/"):
                binary.add(p)
        if q.wait():
            raise SystemExit(2)
    kept, total = [], 0
    for p in ranked:
        n = int(recs[p][3])
        if p in binary or total + n > PARTIAL["bytes"]:
            continue
        total += n
        kept.append(p)
    keep = set(kept)
    with open(keep_z, "wb") as f:
        for p in kept:
            mode, typ, oid, _, raw = recs[p]
            f.write(mode + b" " + typ + b" " + oid + b"\t" + raw + b"\0")
    with open(stats_f, "w") as f:
        f.write("%d %d %d %d %d %d %s\n" % (
            len(kept), sum(p in keep for p in head), sum(p in recs and recs[p][1] == b"blob" for p in changed),
            sum(p in keep for p in manifests), sum(p in keep for p in callers), len(order), cut))


if __name__ == "__main__":
    main(*sys.argv[1:7])
