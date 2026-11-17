"""The credential detector: the one copy of the shapes.

secret-scan.sh, beside it, imports it; omb-upload.sh, also beside it, runs it
on the two files it posts. It lives in hooks/, not in the skill folder: the
merge gate treats skills/ as prose, and an edit to the detector must count as
a code change.

Only high-signal shapes: a token with a vendor prefix, a private-key block, a
file whose name says it holds keys. A false refusal costs a rerun and teaches
agents to strip context to get past it, so no entropy guessing. Every value in
a message is masked: printing the secret to say we did not send it would leak it.

    python3 omb_scan.py --payload <payload.json>
    python3 omb_scan.py --snapshot <s.tgz> <hits-out>

Exit 0 clean, 3 hits (masked list on stderr; for a snapshot the members that
hit are written to <hits-out>, NUL-separated), anything else could not scan.
A snapshot scan prints the number of files it read (every member but folders).
"""
import json
import os
import re
import sys

SHAPES = [
    ("AWS access key", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
    ("private key", re.compile(r"-----BEGIN (?:[A-Z]+ )*PRIVATE KEY(?: BLOCK)?-----")),
    ("GitHub token", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,})\b")),
    ("Slack token", re.compile(r"\bxox[abposr]-[A-Za-z0-9-]{10,}")),
    ("Stripe live key", re.compile(r"\b(?:sk|rk)_live_[A-Za-z0-9]{20,}")),
    ("Google API key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}(?![0-9A-Za-z_-])")),
    ("Anthropic key", re.compile(r"\bsk-ant-[A-Za-z0-9_-]{20,}")),
    ("OpenAI key", re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{32,}")),
]
# Documentation placeholders, not credentials.
PLACEHOLDER = re.compile(r"EXAMPLE|XXXX|xxxx|0000000000|REDACTED", re.I)
KEY_FILE = re.compile(r"(^|/)(id_(rsa|dsa|ecdsa|ed25519)|[^/]+\.(pem|p12|pfx|key))$")
# A whole .env attached as context is a file of secrets; a diff that touches one
# may only change PORT=3000, and its values are scanned line by line anyway.
ENV_FILE = re.compile(r"(^|/)\.env(\.(?!example$|sample$|template$|dist$)[^/]+)?$")


def mask(v):
    return v[:4] + "..." + v[-2:] if len(v) > 10 else v[:2] + "..."


def scan_line(hits, where, line):
    for kind, rx in SHAPES:
        for m in rx.finditer(line):
            if not PLACEHOLDER.search(m.group(0)):
                hits.append("%s %s (%s)" % (where, kind, mask(m.group(0))))


def scan(hits, where, text):
    for no, line in enumerate(text.splitlines(), 1):
        scan_line(hits, "%s:%d" % (where, no), line)


HUNK = re.compile(r"^@@ -\d+(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


def scan_diff(hits, diff):
    # Name the file and its line, not the line of the diff text. Headers are
    # read only between hunks: inside one, "--- x" is a removed "-- x" line.
    # The new side of a deleted file is /dev/null: name it by its old path.
    path, gone, new, old_left, new_left = "diff", "diff", 0, 0, 0
    for raw in diff.splitlines():
        if old_left <= 0 and new_left <= 0:
            if raw.startswith("--- "):
                gone = raw[6:].strip() if raw.startswith("--- a/") else raw[4:].strip()
                continue
            if raw.startswith("+++ "):
                path = raw[6:].strip() if raw.startswith("+++ b/") else raw[4:].strip()
                if path == "/dev/null":
                    path = gone
                continue
            if raw.startswith("diff ") or raw.startswith("index "):
                continue
            h = HUNK.match(raw)
            if h:
                old_left = int(h.group(1) or 1)
                new, new_left = int(h.group(2)), int(h.group(3) or 1)
                continue
        elif raw.startswith("\\"):
            continue
        if raw.startswith("-"):
            old_left -= 1
        elif raw.startswith("+"):
            new_left -= 1
        else:
            old_left -= 1
            new_left -= 1
        if raw.startswith("-"):
            where = "%s (a removed line)" % path
        else:
            where = "%s:%d" % (path, new)
            new += 1
        scan_line(hits, where, raw)
    # The old side too: a diff that deletes a key file carries the key.
    for name in dict.fromkeys(m.group(1).strip() for m in re.finditer(r"^(?:\+\+\+ b|--- a)/(.+)$", diff, re.M)):
        if KEY_FILE.search(name):
            hits.append("diff changes %s, a file that holds keys" % name)


def scan_payload(hits, ti):
    """{diff, files}: what an inline submit, a provide_files or an upload carries."""
    diff = ti.get("diff")
    if diff is not None and not isinstance(diff, str):
        raise TypeError("diff")
    if diff:
        scan_diff(hits, diff)
    files = ti.get("files")
    if files is not None and not isinstance(files, list):
        raise TypeError("files")
    for f in files or []:
        content = f.get("content")
        if content is not None and not isinstance(content, str):
            raise TypeError("content")
        path = str(f.get("path") or "?")
        ph = []
        scan(ph, "", path)
        label = "<flagged path>" if ph else path  # a credential in the path text never reaches a label
        if KEY_FILE.search(path) or ENV_FILE.search(path):
            hits.append("%s is a file that holds keys" % label)
        if content:
            scan(hits, label, content)


CHUNK = 1 << 20
OVERLAP = 4096  # longer than any shape, so a token cut by a chunk edge is still read whole


def scan_stream(hits, where, f):
    """A member read in chunks, line by line, with a bounded line buffer."""
    no, buf = 1, b""
    while True:
        data = f.read(CHUNK)
        if not data:
            break
        buf += data
        lines = buf.split(b"\n")
        buf = lines.pop()
        for line in lines:
            scan_line(hits, "%s:%d" % (where, no), line.decode("utf-8", "replace"))
            no += 1
        if len(buf) > CHUNK:
            # One very long line: read it so far, keep a tail for the next chunk.
            scan_line(hits, "%s:%d" % (where, no), buf.decode("utf-8", "replace"))
            buf = buf[-OVERLAP:]
    if buf:
        scan_line(hits, "%s:%d" % (where, no), buf.decode("utf-8", "replace"))


def scan_snapshot(hits, path):
    """Every regular member of the tar.gz, one at a time; returns the members that
    hit and the number of files. Key-file names need no check here: the packer's
    excludes keep every one of them out of the archive."""
    import tarfile
    hit_members, count = [], 0
    with tarfile.open(path, "r|gz", encoding="utf-8", errors="surrogateescape") as tf:
        for m in tf:
            count += not m.isdir()
            if not m.isreg():
                continue
            before = len(hits)
            scan_stream(hits, m.name, tf.extractfile(m))
            if len(hits) > before:
                hit_members.append(m.name)
    return hit_members, count


def read_listed(top, listed, p):
    """A requested file below the git top level `top`, as (rel, bytes).

    Opened one part at a time from the fd of the top level, never through a
    symlink, and read from the fd that was checked: nothing can swap the file
    between the check and the read. Returns (None, None) for a path that is
    not a regular file inside the top level (missing, a symlink in any part,
    an empty, "." or ".." part), (rel, None) for one git does not list, and
    (rel, bytes) for a listed one. Every fd is closed here."""
    import stat
    RD = os.O_RDONLY | getattr(os, "O_BINARY", 0)
    NOFOLLOW, NONBLOCK, DIRECTORY = (getattr(os, f, 0) for f in ("O_NOFOLLOW", "O_NONBLOCK", "O_DIRECTORY"))
    try:
        # The name opened is the name sent: a part that is empty, "." or ".." is
        # refused, never tidied away, or "x/." would open x under another name.
        parts = os.fsencode(p).replace(os.fsencode(os.sep), b"/").split(b"/")
        while len(parts) > 1 and parts[0] == b".":
            parts = parts[1:]
        if any(c in (b"", b".", b"..") for c in parts):
            return None, None
        rel = b"/".join(parts)
        if os.open not in os.supports_dir_fd:
            # shortcut: no dir_fd (Windows python), so the whole path is checked for any link or
            # junction and then opened, a window for someone rewriting the checkout mid-call;
            # upgrade if it gains dir_fd.
            full = os.path.join(os.fsencode(top), *parts)
            if os.path.realpath(full) != os.path.normpath(full):
                return None, None
            before = os.stat(full)
            fd = os.open(full, RD | NONBLOCK)
            after = os.fstat(fd)
            if (after.st_ino, after.st_dev) != (before.st_ino, before.st_dev):
                os.close(fd)
                return None, None
        else:
            dfd = os.open(top, RD)
            try:
                for c in parts[:-1]:
                    sub = os.open(c, RD | NOFOLLOW | DIRECTORY, dir_fd=dfd)
                    os.close(dfd)
                    dfd = sub
                fd = os.open(parts[-1], RD | NOFOLLOW | NONBLOCK, dir_fd=dfd)
            finally:
                os.close(dfd)
    except (OSError, ValueError):
        return None, None
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return None, None
        if rel not in listed:
            return rel, None
        with open(fd, "rb", closefd=False) as f:
            return rel, f.read()
    except OSError:
        return None, None
    finally:
        os.close(fd)


def shown(hits):
    hits = list(dict.fromkeys(hits))
    return hits[:12] + (["... and %d more" % (len(hits) - 12)] if len(hits) > 12 else [])


def main(argv):
    if os.environ.get("OHMYBUG_TEST_SCAN_RAISE"):
        raise RuntimeError("forced by the test")
    hits = []
    if argv[:1] == ["--payload"] and len(argv) == 2:
        with open(argv[1], "rb") as f:
            scan_payload(hits, json.loads(f.read().decode("utf-8")))
    elif argv[:1] == ["--snapshot"] and len(argv) == 3:
        members, count = scan_snapshot(hits, argv[1])
        print(count)
        if members:
            with open(argv[2], "wb") as f:
                f.write(b"".join(n.encode("utf-8", "surrogateescape") + b"\0" for n in members))
    else:
        raise SystemExit(2)
    if hits:
        sys.stderr.buffer.write(("".join("  - %s\n" % h for h in shown(hits))).encode("utf-8", "replace"))
        return 3
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except SystemExit:
        raise
    except BaseException:
        sys.exit(2)
