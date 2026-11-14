"""The credential detector: the one copy of the shapes.

hooks/secret-scan.sh imports it. It lives in the skill folder so that every
install that has the skill has the detector.

Only high-signal shapes: a token with a vendor prefix, a private-key block, a
file whose name says it holds keys. A false refusal costs a rerun and teaches
agents to strip context to get past it, so no entropy guessing. Every value in
a message is masked: printing the secret to say we did not send it would leak it.
"""
import re

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
    """{diff, files}: what an inline submit or a provide_files carries."""
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
        if KEY_FILE.search(path) or ENV_FILE.search(path):
            hits.append("%s is a file that holds keys" % path)
        if content:
            scan(hits, path, content)


def shown(hits):
    hits = list(dict.fromkeys(hits))
    return hits[:12] + (["... and %d more" % (len(hits) - 12)] if len(hits) > 12 else [])

