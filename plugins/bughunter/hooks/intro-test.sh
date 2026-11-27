#!/bin/bash
# Run me after touching intro.sh: `bash hooks/intro-test.sh`
set -u
G=$(cd "$(dirname "$0")" && pwd)
fails=0
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
ok() { echo "ok   $*"; }
S=$(mktemp -d); trap 'rm -rf "$S"' EXIT
hook() { OMB_STATE_DIR="$S/state" HOME="$S" bash "$G/intro.sh" "$@" < /dev/null; }
hooksrc() { printf '{"hook_event_name":"SessionStart","source":"%s"}' "$1" | OMB_STATE_DIR="$S/state" HOME="$S" bash "$G/intro.sh"; }
ctx() { python3 -I -c 'import json, sys; d = json.load(sys.stdin); print(d["systemMessage"]); print(d["hookSpecificOutput"]["hookEventName"], d["hookSpecificOutput"]["additionalContext"])'; }

# I4: Codex (PLUGIN_DATA) is silent and uses up no offer.
[ -z "$(PLUGIN_DATA=/x hook)" ] && [ ! -e "$S/state/intro-v1-offers" ] && ok "I4 Codex: silent, no offer counted" || fail "I4 Codex spoke or counted"

# I2: no marker: context only, and the hook never writes the marker.
out=$(hook | ctx)
case $out in
  *'/bughunter:setup'*'SessionStart Run the First-run setup of the bughunter skill at the start of your first reply'*'Only with the question tool: if this session has none, do nothing and say nothing about it.'*) ok "I2 first session: the notice and the setup context" ;;
  *) fail "I2 first session: $out" ;;
esac
[ ! -e "$S/state/intro-v1" ] && ok "I2 the hook writes no marker" || fail "I2 the hook wrote the marker"

# I3: offered 3 times in all, then silent.
[ -n "$(hook)" ] && [ -n "$(hook)" ] && ok "I3 second and third sessions: offered again" || fail "I3 an offer under the cap was silent"
[ -z "$(hook)" ] && ok "I3 fourth session: silent" || fail "I3 fourth session spoke"
[ "$(cat "$S/state/intro-v1-offers")" = 3 ] && ok "I3 the counter stops at 3" || fail "I3 counter: $(cat "$S/state/intro-v1-offers")"
printf 'junk\n' > "$S/state/intro-v1-offers"
[ -n "$(hook)" ] && ok "I3 an unreadable counter counts as none" || fail "I3 junk counter: silent"

# I8: only a new session. A compacted, cleared or resumed one is mid-task:
# silent, and no offer counted; hooks.json runs it on startup only.
rm -rf "$S/state"
for src in compact clear resume; do
  [ -z "$(hooksrc "$src")" ] && [ ! -e "$S/state/intro-v1-offers" ] && ok "I8 source $src: silent, no offer counted" || fail "I8 source $src spoke or counted"
done
[ -n "$(hooksrc startup)" ] && ok "I8 source startup: offered" || fail "I8 source startup: silent"
python3 -I - "$G/hooks.json" <<'PY' && ok "I8 hooks.json: intro.sh only in a SessionStart group matching startup alone" || fail "I8 hooks.json: intro.sh runs on other sources"
import json, sys
groups = json.load(open(sys.argv[1]))["hooks"]["SessionStart"]
where = [g.get("matcher") for g in groups for h in g["hooks"] if h["command"].endswith("/intro.sh")]
sys.exit(0 if where == ["startup"] else 1)
PY

# C: every command's front matter is strict YAML (a plain scalar may not hold
# ": "): parsed with PyYAML where it is installed, else that rule.
python3 -I - "$G/../commands" <<'PY' && ok "C commands/*.md: front matter is strict YAML" || fail "C a command's front matter is not strict YAML"
import glob, os, re, sys
try:
    import yaml
except ImportError:
    yaml = None
bad = []
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*.md"))):
    t = open(f, encoding="utf-8").read()
    m = re.match(r"---\n(.*?)\n---\n", t, re.S)
    if not m:
        bad.append(f); continue
    if yaml:
        try:
            d = yaml.safe_load(m.group(1))
            if not isinstance(d, dict) or not isinstance(d.get("description"), str):
                bad.append(f)
        except yaml.YAMLError:
            bad.append(f)
    for line in m.group(1).split("\n"):
        k, _, v = line.partition(": ")
        v = v.strip()
        if v and v[0] not in "\"'|>" and ": " in v:
            bad.append(f)
if bad:
    print(bad)
sys.exit(1 if bad else 0)
PY

# I5: done writes the marker and prints an ISO UTC time; I1: then silent.
rm -rf "$S/state"
t=$(hook done)
[ -e "$S/state/intro-v1" ] && printf '%s' "$t" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' && ok "I5 done: marker written, time $t" || fail "I5 done: [$t]"
[ -z "$(hook)" ] && [ ! -e "$S/state/intro-v1-offers" ] && ok "I1 marker present: silent, nothing counted" || fail "I1 marker present: spoke"

# S: the skill's setup contract, as the plugin's text must keep it.
SEC=$(awk '/^## First-run setup$/,/^## The flow$/' "$G/../skills/bughunter/SKILL.md" | tr '\n' ' ' | tr -s ' ')
for want in \
  '"Keep them in my account only (recommended)": "Off every public page, at ohmybug.ai/me/stories. Your agent still asks before each story' \
  'Sends `stories: "private"`' \
  'Sends `stories: "ask"`, `author: "handle"`' \
  'Sends `stories: "ask"`, `author: "anonymous"`' \
  'Sends `stories: "never"`' \
  'Then make ONE `set_policy` call: the answered fields plus `intro: {"version": 1, "at": "<that time>"}`' \
  'Not asked when the saved `stories` is `auto`' \
  '`free_review_rule` word for word' \
  'Prices come only from `get_balance` `modes`' \
  'Sends `hunt_mode: "lite"`' \
  'Sends `hunt_mode: "snap"`' \
  'Sends `hunt_mode: "fast"`' \
  'Sends `hunt_mode: "auto"`' \
  '`docs_findings` (an older server): send nothing for it.' \
  'Ask the four questions in ONE question-tool call' \
  'finds ~<found_pct>% of known bugs (our benchmark)' \
  'with a `get_balance` `route`' \
  'This question has no Skip' \
  '"Keep <its name>", which sends nothing for this field' \
  'without one (a headless run), do nothing and say nothing about it' \
  "If its \`policy.intro.version\` is 1 or more and this is not \`/bughunter:setup\`, run" \
  'The marker stays written.'; do
  case $SEC in *"$want"*) ;; *) fail "S skill setup text lost: $want" ;; esac
done
# Test findings are always delivered low by the service; the setup no longer asks or sends test_gaps.
case $SEC in *test_gaps*) fail "S setup no longer asks test_gaps" ;; *) ok "S setup no longer asks test_gaps" ;; esac
# The question count, everywhere the user is told it.
cat "$G/../skills/bughunter/SKILL.md" "$G/../commands/setup.md" "$G/intro.sh" "$G/codex-router.js" "$G/../../../README.md" | tr '\n' ' ' | tr -s ' ' | grep -qiE '(three|five) (quick )?questions' && fail "S no file states a stale question count" || ok "S no file states a stale question count"
for f in "$G/intro.sh" "$G/../commands/setup.md" "$G/codex-router.js" "$G/../../../README.md"; do
  tr '\n' ' ' < "$f" | tr -s ' ' | grep -qiE 'four (quick )?questions' && ok "S $(basename "$f") says four questions" || fail "S $(basename "$f") says four questions"
done
# The docs options with their own values, blocking first and recommended.
printf '%s' "$SEC" | tr '\n' ' ' | grep -q 'Block the merge (recommended)[^-]*Sends `docs_findings: "block"`.*Show them, but don.t block.*Sends `docs_findings: "not_block"`' && ok "S docs options: block first and recommended, each sends its own value" || fail "S docs option values"
# The Notes paragraph of the result (bounded to it): last, counted, not blocking or charged, judged, raised = regular.
NOTES=$(awk '/^\*\*Notes\.\*\*/,/^$/' "$G/../skills/bughunter/SKILL.md" | tr '\n' ' ' | tr -s ' ')
for want in \
  'A finding marked `kind: "note"` is a `low` that names no input or state that goes wrong on the code as it is' \
  'Show those last, in their own section under "Notes", and say how many there are.' \
  'A note does not block the merge and is not charged.' \
  'Judge it like any `low` (step 4)' \
  'a verdict that raises one to `medium` or worse makes it a regular finding'; do
  case "$NOTES" in *"$want"*) ok "R notes: $want" ;; *) fail "R notes paragraph lacks: $want" ;; esac
done
# Step 4: a note is graded by its consequence, never raised just because a failing input exists.
tr '\n' ' ' < "$G/../skills/bughunter/SKILL.md" | tr -s ' ' | grep -qF 'A note is graded like any other finding: when your trace finds an input or state that goes wrong today, it is no longer a note, and it gets the severity its consequence earns, which may still be `low`.' && ok "R notes: step 4 grades a note by its consequence" || fail "R notes step 4 rule"
SK_FLAT=$(tr '\n' ' ' < "$G/../skills/bughunter/SKILL.md" | tr -s ' ')
pin_skill() { printf '%s' "$SK_FLAT" | grep -qF -- "$1" && ok "$2" || fail "$2"; }
pin_skill $'`severity` goes only with a `REAL` verdict. Never send it with `NOT_REAL` or `UNCLEAR`, whatever the finding carries: the service stores a severity sent with any verdict, and an `UNCLEAR` at `medium` or worse can be charged. On a `REAL`, pass `severity` (either direction) whenever the trace changes the consequence, and say why in `reason` – the finder\'s original is kept alongside. One finding takes it on every `REAL`: the one delivered `low` with `reported_severity` and no `kind` (below).' "R verdict severity: only with REAL (step 4 opening)"
pin_skill $'A finding delivered `low` with `reported_severity` and no `kind` is the other way round: judge it like any other finding. When it is `REAL`, set the severity its consequence earns, starting from the one it was first reported with: a finding first reported `high` that is really a `medium` is raised to `medium`; one that is really a `low` stays `low`. Pass that `severity` in every `REAL` verdict on it, even when it equals the first-reported one or is `low`: a `REAL` sent without it leaves the finding `low`, not charged and not blocking. A `NOT_REAL` or `UNCLEAR` on it carries no `severity` (the rule above) and leaves it `low`.' "R verdict severity: solo finding on every REAL"
pin_skill $'`UNCLEAR` – cannot be established either way; say what is missing. It is final: the service takes no later verdict on that finding, and the hunt stays unmergeable whatever the finding\'s severity, a `low` or a note included. Where this skill says a finding does not block the merge, that holds for `REAL` and `NOT_REAL`. Trace further or ask the user before you send one. When you do send one, say before the user approves the table that it keeps the hunt unmergeable until a new hunt of the head and, on a hunt whose `get_findings` showed `silent_bill`, that a `medium` or worse one is charged at the hunt\'s deadline (honesty rules below).' "R verdict severity: UNCLEAR is final at any severity, said before approval"
pin_skill $'plus `severity` only on a `REAL` verdict, as step 4 says, and `known` when step 4 marked it.' "R verdict severity: step 5 payload"
pin_skill $'**Findings delivered as low.** A finding that carries `reported_severity` but neither `kind` nor `second_read` was delivered as `low`; the field is the severity it was first reported with. It does not block the merge and is not charged unless your verdict raises its severity. Show it with the other findings, its reported severity beside it; say once that these do not block and are not charged unless your verdict raises them. Step 4 says how to judge it and which severity its verdict carries. A finding that carries `second_read` was read a second time against the code; the tool\'s own description says how to show it, and one that also carries `reported_severity` and no `kind` is judged by the same step 4 rule.' "R verdict severity: step 3 section"
pin_skill $'**Lows by class.** When `get_findings` carries `low_groups`, start the lows with one count line, e.g. `Lows: other 5, style 7, dead code 4`. Show the `other` lows first and in full, each as usual. Show every other class (style, perf, dead code, defensive, cleanup) as one line: the class, how many, and their finding ids, e.g. `style 7: f-1a2b, f-3c4d, …`. Each low still gets a verdict (step 4); open one in full when the user asks.' "R lows by class: step 3 section"
pin_skill $'`NOT_REAL` costs nothing. `UNCLEAR` costs nothing at confirm, but on a hunt whose `get_findings` showed `silent_bill` an `UNCLEAR` `medium` or worse is charged at the deadline like a finding nobody judged. Both count against OhMyBug\'s quality stats.' "R verdict severity: UNCLEAR and the silent bill"
pin_skill $'Reviews and false positives cost nothing; an unclear finding costs nothing at confirm (step 4 says when it is charged later).' "R verdict severity: intro on unclear cost"
pin_readme() { tr '\n' ' ' < "$G/../../../README.md" | tr -s ' ' | grep -qF -- "$1" && ok "$2" || fail "$2"; }
pin_readme $'- Billing: one flat price per review with confirmed real bugs — one or ten, same price: $4 fast (a lite or snap hunt: the price `get_balance` `modes` lists), $12 deep, $24 deep on a wide change (11+ folder chunks). Minor findings, review runs and false positives — $0, and so is a real medium you already deferred or accepted in your own ticket, once your agent marks it known (a hunt billed on CI, or one already billed at its deadline, stays charged). An unclear medium or worse is free at confirm but, like one nobody judged, is charged at the hunt\'s deadline. - ' "R verdict severity: README billing bullet whole"
for gone in 'unclear — $0' 'unclear findings cost nothing'; do tr '\n' ' ' < "$G/../../../README.md" | tr -s ' ' | grep -qiF -- "$gone" && fail "R verdict severity: README old text gone: $gone" || ok "R verdict severity: README old text gone: $gone"; done
pin_skill $'For a test gap the service\'s rule wins over that rule: a finding marked `kind: "test"` and delivered `low` with `reported_severity` stays `low`, even when the missing test guards a sensitive path, unless your trace shows the production code itself failing today.' "R verdict severity: test gap stays low"
pin_skill $'The same holds for a docs finding delivered `low` under `docs_findings: "not_block"`: it stays `low` unless your trace shows the code itself wrong, or the text is one your product shows or sends its users (a screen, a message, an email, a generated file).' "R verdict severity: docs finding stays low"
pin_skill $'Only `medium` and `low`, both as delivered and as you grade it: the service refuses `known` on a finding delivered `high` or `critical`, even one you correct down in the same verdict, and on one you correct up to `high`.' "R verdict severity: known only medium and low"
for gone in 'always takes `severity`' 'Always pass that `severity` in its verdict' '(always, step 4)' 'unclear findings cost nothing' '`NOT_REAL` and `UNCLEAR` cost nothing' 'plus `severity` when you corrected it'; do printf '%s' "$SK_FLAT" | grep -qF -- "$gone" && fail "R verdict severity: old text gone: $gone" || ok "R verdict severity: old text gone: $gone"; done
# The stories options in this order, private first.
printf '%s' "$SEC" | grep -q 'Keep them in my account only (recommended).*Publish them, signed with my GitHub name.*Publish them unsigned.*Don.t write them' && ok "S stories options: private first and recommended, then signed, unsigned, off" || fail "S stories option order"
# The X follow-up: only after the signed option, only while get_balance has x_crosspost, the reward from the server.
printf '%s' "$SEC" | grep -qF 'Asked only when the user picked "Publish them, signed with my GitHub name", `get_balance` has `x_crosspost`, and the saved `x_crosspost` is not already `on`' && ok "S X follow-up: gated on signed, x_crosspost present, not already on" || fail "S X follow-up gate"
printf '%s' "$SEC" | grep -qF 'Then `x_crosspost.rule` word for word; never a reward rule of your own.' && ok "S X follow-up: reward from x_crosspost.rule" || fail "S X follow-up reward source"
printf '%s' "$SEC" | grep -qF '"Yes": "Your signed stories also go out on your X account, after you confirm it once with a link." Sends `x_crosspost: "on"`.' && ok "S X follow-up: yes sends x_crosspost on" || fail "S X follow-up yes"
printf '%s' "$SEC" | grep -qF 'When the answer carries `x_connect_url`, add: "Then connect your X account: <x_connect_url>."' && ok "S X follow-up: connect link said" || fail "S X follow-up connect link"
# Plugin text never names the reward itself.
grep -qi 'free review' "$G/intro.sh" "$G/../commands/setup.md" && fail "S intro text says free review" || :
printf '%s' "$SEC" | grep -qi 'free review' && fail "S setup section says free review" || ok "S setup texts: no reward wording of their own"

# I9: a state folder or counter that cannot be written: silent, exit 0, no
# shell error (it would offer, or fail, every session). A leading zero counts.
rm -rf "$S/state"; mkdir -p "$S/ro"; chmod 555 "$S/ro"
o=$(OMB_STATE_DIR="$S/ro/state" HOME="$S" bash "$G/intro.sh" < /dev/null 2>&1); r=$?
chmod 755 "$S/ro"
[ "$r" = 0 ] && [ -z "$o" ] && ok "I9 unwritable state folder: silent, exit 0" || fail "I9 unwritable state: rc $r [$o]"
mkdir -p "$S/state"; printf '08\n' > "$S/state/intro-v1-offers"
[ -n "$(hook 2>/dev/null)" ] && [ "$(cat "$S/state/intro-v1-offers")" = 9 ] && fail "I9 08 read as under the cap" || ok "I9 counter 08 reads as 8: past the cap, silent"

echo "intro: $([ "$fails" = 0 ] && echo ok || echo "$fails failing")"
[ "$fails" = 0 ]
