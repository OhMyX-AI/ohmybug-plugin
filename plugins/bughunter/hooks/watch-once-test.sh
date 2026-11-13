#!/bin/bash
# Run me after touching skills/bughunter/watch-once.sh or the skill's watch loop:
# `hooks/watch-once-test.sh`. A fake status door answers each run (curl and date
# shimmed); every assertion is on the two lines the wake obeys and on the files
# the Stop hook reads.
set -u
G=$(cd "$(dirname "$0")" && pwd)
exec python3 -I - "$G/../skills/bughunter/watch-once.sh" "$G/../skills/bughunter/SKILL.md" <<'PY'
import os, subprocess, sys, tempfile
script, skill_path = sys.argv[1], sys.argv[2]
fails = 0
def check(name, got, want):
    global fails
    if got == want: print("ok  ", name)
    else: print(f"FAIL {name}: got {got!r}, want {want!r}"); fails += 1

URL = "http://x/r/rev_a/status"
def run(d, body, code=200, now=1000, start=900, rc=0, url=URL, mode=None):
    # The curl shim answers `body` with `code` on the -w line (or exits rc), and
    # notes the URL it was asked; the date shim pins the clock.
    open(f"{d}/curl", "w").write("#!/bin/sh\nfor a; do u=$a; done; echo \"$u\" >> \"%s/urls\"\n%s" % (d,
        f"exit {rc}\n" if rc else "printf '%s' '" + body + "'\nprintf '\\n" + str(code) + "'\n"))
    open(f"{d}/date", "w").write(f"#!/bin/sh\necho {now}\n")
    os.chmod(f"{d}/curl", 0o755); os.chmod(f"{d}/date", 0o755)
    env = {**os.environ, "PATH": f"{d}:{os.environ['PATH']}", "HOME": d}
    args = ["sh", script, "rev_a", url, str(start)] + ([mode] if mode else [])
    r = subprocess.run(args, capture_output=True, text=True, env=env, timeout=30)
    assert r.returncode == 0, (r.returncode, r.stderr)
    return r.stdout.splitlines()
W = lambda d, n="rev_a": open(f"{d}/.ohmybug/watch/{n}").read() if os.path.exists(f"{d}/.ohmybug/watch/{n}") else None

# An ordinary hunt: running keeps the job and arms the Stop hook's file at the cron cadence.
with tempfile.TemporaryDirectory() as d:
    check("running", run(d, '{"status":"running","next_poll_after_s":240}'), ["bughunt · fast · running", "keep"])
    check("running: watch file", W(d), "running 240\n")
    check("waiter named", open(f"{d}/urls").read(), URL + "?w=once\n")
    check("done quotes the count", run(d, '{"status":"done","findings":3}'), ["bughunt · fast · done · findings=3", "done"])
    check("done clears the watch file", W(d), None)
with tempfile.TemporaryDirectory() as d:
    check("failed", run(d, '{"status":"failed"}', mode="deep"), ["bughunt · deep · failed", "failed"])
with tempfile.TemporaryDirectory() as d:
    check("file request wins over the status word", run(d, '{"status":"running","files_requested":true}'), ["bughunt · fast · needs-files", "files"])
    check("needs-files is an exit word for the Stop hook", W(d).split()[0], "needs-files")
with tempfile.TemporaryDirectory() as d:
    check("query string kept", run(d, '{"status":"running"}', url=URL + "?t=1")[1], "keep")
    check("waiter appended", open(f"{d}/urls").read(), URL + "?t=1&w=once\n")

# The route through watch.do (the service since #3599): judge, keep, move, done, resubmit.
with tempfile.TemporaryDirectory() as d:
    check("judge", run(d, '{"status":"done","route_state":"awaiting_verdicts","final":false,"watch":{"do":"judge"}}'), ["bughunt · fast · verdicts", "judge"])
    check("judged, deciding: keep", run(d, '{"status":"done","route_state":"awaiting_verdicts","final":false,"watch":{"do":"keep"}}'), ["bughunt · fast · running", "keep"])
    move = run(d, '{"status":"done","route_state":"continued","final":false,"continued_by":"rev_b","watch":{"do":"move","review_id":"rev_b","status_url":"https://s/r/rev_b/status","interval_s":240,"fail_window_s":720,"retire_at":"2026-01-01T00:00:00Z"}}', now=1300)
    check("move hands over the child, its door and a fresh start", move, ["bughunt · fast · continued rev_b", "move rev_b https://s/r/rev_b/status 1300"])
    check("move clears this review's files", (W(d), os.path.exists(f"{d}/.ohmybug/watch/rev_a.routed")), (None, False))
with tempfile.TemporaryDirectory() as d:
    check("route done by the status", run(d, '{"status":"done","findings":0,"route_state":"final","final":true,"watch":{"do":"done"}}'), ["bughunt · fast · done · findings=0", "done"])
    check("route done on a failed step", run(d, '{"status":"failed","route_state":"final","final":true,"watch":{"do":"done"}}')[1], "failed")
    check("resubmit", run(d, '{"status":"done","route_state":"continued","continuation_failed":true,"watch":{"do":"resubmit"}}'), ["bughunt · fast · continuation-failed", "resubmit"])

# An older service: route_state alone, remembered across wakes.
with tempfile.TemporaryDirectory() as d:
    check("legacy: pending is not done", run(d, '{"status":"done","route_state":"pending"}')[1], "keep")
    check("legacy: routed review without route_state is still held", run(d, '{"status":"done"}')[1], "keep")
    check("legacy: verdicts", run(d, '{"status":"done","route_state":"awaiting_verdicts"}')[1], "judge")
    check("legacy: move derives the child door", run(d, '{"status":"done","route_state":"continued","continued_by":"rev_c"}', now=1400)[1], "move rev_c http://x/r/rev_c/status 1400")
with tempfile.TemporaryDirectory() as d:
    check("legacy: continued with no id waits", run(d, '{"status":"done","route_state":"continued"}')[1], "keep")
    check("legacy: final is done", run(d, '{"status":"done","findings":1,"route_state":"final"}')[1], "done")

# Failed reads: read and keep; 15 minutes without an answer retires as dead; the age cap retires as age.
with tempfile.TemporaryDirectory() as d:
    check("curl failure", run(d, "", rc=7), ["bughunt · fast · poll-failed", "read"])
    check("poll-failed keeps the Stop hook armed", W(d).split()[0], "poll-failed")
    check("route table down (503)", run(d, '{"error":"route_unavailable","watch":{"do":"unavailable"}}', code=503)[1], "read")
    check("a 200 that is not the review", run(d, "<html>proxy</html>")[1], "read")
    check("watch.do unavailable on a 200", run(d, '{"status":"running","watch":{"do":"unavailable"}}')[1], "read")
    check("still inside the window", run(d, "", rc=7, now=900 + 899)[1], "read")
    check("15 min with no answer", run(d, "", rc=7, now=900 + 900), ["bughunt · fast · watch-retired", "retire dead"])
with tempfile.TemporaryDirectory() as d:
    run(d, '{"status":"running"}', now=5000, start=900)
    check("a good read resets the window", run(d, "", rc=7, now=5000 + 899, start=900)[1], "read")
with tempfile.TemporaryDirectory() as d:
    check("age cap", run(d, '{"status":"running"}', now=900 + 10800), ["bughunt · fast · watch-retired", "retire age"])
    check("age cap reads nothing", os.path.exists(f"{d}/urls"), False)
    check("a mangled start retires", run(d, '{"status":"running"}', start="<start>", now=20000)[1], "retire age")

# An unwritable $HOME (a sandbox): the state moves to $TMPDIR and the watch still works.
with tempfile.TemporaryDirectory() as d, tempfile.TemporaryDirectory() as t:
    os.makedirs(f"{d}/.ohmybug"); os.chmod(f"{d}/.ohmybug", 0o500)
    try:
        open(f"{d}/curl", "w").write("#!/bin/sh\nexit 7\n"); os.chmod(f"{d}/curl", 0o755)
        env = {**os.environ, "PATH": f"{d}:{os.environ['PATH']}", "HOME": d, "TMPDIR": t}
        r = subprocess.run(["sh", script, "rev_a", URL, str(int(__import__('time').time()))], capture_output=True, text=True, env=env, timeout=30)
        check("sandbox: read", r.stdout.splitlines(), ["bughunt · fast · poll-failed", "read"])
        check("sandbox: state in TMPDIR", os.path.exists(f"{t}/ohmybug-watch/rev_a.once"), True)
    finally:
        os.chmod(f"{d}/.ohmybug", 0o700)

# One reading of a routed body across surfaces: the Monitor loop in SKILL.md and
# this script classify the route with the same lines, so they cannot drift.
skill = open(skill_path, encoding="utf-8").read()
mine = open(script, encoding="utf-8").read()
for shared in ('case "$rs" in \'\'|final) ;; *) : > "$watch.routed" ;; esac',
               '[ "$rs" = final ] && rm -f "$watch.routed"',
               '[ -z "$rs" ] && [ -e "$watch.routed" ] && rs=held',
               '"awaiting_client_files"[[:space:]]*:[[:space:]]*true|"files_requested"[[:space:]]*:[[:space:]]*true'):
    check("shared with the Monitor loop: " + shared[:40], (shared in skill, shared in mine), (True, True))
print("fails:", fails)
sys.exit(1 if fails else 0)
PY
