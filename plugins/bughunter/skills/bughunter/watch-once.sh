#!/bin/sh
# watch-once.sh <review_id> <status_url> <start> [mode]
#
# ONE read of a hunt's status, for a wake that is a fresh turn holding nothing
# but its prompt: Claude Code's CronCreate fallback and Codex's heartbeat. The
# prompt runs this and obeys its last line; every decision a wake used to make
# from prose (the route, the age cap, the failure window, the line to print) is
# made here, in code a test runs.
#
# <start> is the epoch second the watch began (the submit; for a continuation,
# the number a `move` word hands over). It is the age clock: a fresh turn has no
# memory, so the prompt carries it unchanged into every replacement job.
#
# Prints two lines: the status line to show, then ONE word for the wake:
#   keep                        nothing to do; keep the job
#   files                       get_findings, serve the files (§3a), keep the job
#   judge                       get_findings, verify and confirm every finding still unjudged (§4), keep the job
#   move <id> <status_url> <s>  the hunt goes on as <id>: get_findings on this review once, then replace
#                               the job with one on <id>, <status_url>, start <s>, mode fast
#   done | failed               get_findings, report it, delete the job
#   resubmit                    the continuation failed: delete the job, get_findings, offer a new hunt
#   read                        this read got no answer: get_findings once, print what it answered, keep the job
#   retire age | retire dead    delete the job first, then get_findings once; on `dead` with the review
#                               still running or waiting for files, create a fresh job with the same <start>
rid=${1:?review_id}; url=${2:?status_url}; start=${3:?start}; mode=${4:-fast}
case $start in ''|*[!0-9]*) start=0 ;; esac # a mangled start fails closed: the watch retires now, it never runs forever
dir="$HOME/.ohmybug/watch"
mkdir -p "$dir" 2>/dev/null && [ -w "$dir" ] || { dir="${TMPDIR:-/tmp}/ohmybug-watch"; mkdir -p "$dir"; } # a sandbox without $HOME writes
watch="$dir/$rid"
say() { printf 'bughunt · %s · %s\n%s\n' "$mode" "$1" "$2"; }
now=$(date +%s)
if [ $((now - start)) -ge 10800 ]; then # 180 min: the longest hunt's 150 plus queue time
  rm -f "$watch" "$watch.once" "$watch.routed"; say watch-retired 'retire age'; exit 0
fi
ok=$start poll=60; [ -s "$watch.once" ] && read -r ok poll < "$watch.once"
case $ok in ''|*[!0-9]*) ok=$start ;; esac
case $poll in ''|*[!0-9]*|0) poll=60 ;; esac
q=$url; case $q in *\?*) q="$q&w=once" ;; *) q="$q?w=once" ;; esac # names this waiter on the server's read journal
s=$(curl -sS --max-time 15 -w '\n%{http_code}' "$q" 2>/dev/null); rc=$?
code=$(printf '%s' "$s" | tail -n 1); s=$(printf '%s' "$s" | sed '$d')
field() { printf '%s' "$s" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1; }
num() { printf '%s' "$s" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" | head -n 1; }
st=$(field status); wd=$(field do)
if [ "$rc" -ne 0 ] || [ "$code" != 200 ] || [ -z "$st" ] || [ "$wd" = unavailable ]; then
  # No answer, an error (the route table's 503 too), or a 200 that is not the review.
  if [ $((now - ok)) -ge 900 ]; then # 15 min with no answer: the Monitor loop's window
    rm -f "$watch" "$watch.once"; say watch-retired 'retire dead'; exit 0
  fi
  printf '%s %s\n' "$ok" "$poll" > "$watch.once"; printf 'poll-failed %s\n' "$poll" > "$watch"
  say poll-failed read; exit 0
fi
n=$(num next_poll_after_s); [ -n "$n" ] && [ "$n" -gt 0 ] && poll=$n # the cron cadence: the Stop hook's freshness window
printf '%s %s\n' "$now" "$poll" > "$watch.once"
files=; printf '%s' "$s" | grep -qE '"awaiting_client_files"[[:space:]]*:[[:space:]]*true|"files_requested"[[:space:]]*:[[:space:]]*true' && files=1
rs=$(field route_state)
case "$rs" in ''|final) ;; *) : > "$watch.routed" ;; esac # remembered across wakes: this review is routed
[ "$rs" = final ] && rm -f "$watch.routed"
[ -z "$rs" ] && [ -e "$watch.routed" ] && rs=held # an answer that names no route, about a routed review: not the end
# What to do: the service's watch.do when it sends one (#3599), else the route state an older service sends.
if [ -n "$files" ]; then w=files # a file request wins: it is held open for minutes only
elif [ -n "$wd" ]; then w=$wd
else case "$rs" in
  ''|final) w=done ;;
  awaiting_verdicts) w=judge ;;
  continued) w=move ;;
  *) w=keep ;;
esac; fi
next=; [ "$w" = move ] && next=$(field continued_by | sed 's/[^A-Za-z0-9_.-]//g')
[ "$w" = move ] && [ -z "$next" ] && w=keep # no id to move to: the next wake asks again
if [ "$w" = done ]; then case "$st" in done|failed) w=$st ;; *) w=keep ;; esac; fi # done on the route, the status says which
case $w in
  keep) printf 'running %s\n' "$poll" > "$watch"; say running keep ;;
  files) printf 'needs-files %s\n' "$poll" > "$watch"; say needs-files files ;;
  judge) printf 'verdicts %s\n' "$poll" > "$watch"; say verdicts judge ;;
  move)
    nurl=$(field status_url); [ -n "$nurl" ] || nurl=$(printf '%s' "$url" | sed "s|/r/$rid/|/r/$next/|")
    rm -f "$watch" "$watch.once" "$watch.routed"; say "continued $next" "move $next $nurl $now" ;;
  done) rm -f "$watch" "$watch.once" "$watch.routed"; say "done · findings=$(num findings)" done ;;
  failed) rm -f "$watch" "$watch.once" "$watch.routed"; say failed failed ;;
  resubmit) rm -f "$watch" "$watch.once" "$watch.routed"; say continuation-failed resubmit ;;
  *) printf 'running %s\n' "$poll" > "$watch"; say running keep ;; # a step this script does not know: not the end
esac
