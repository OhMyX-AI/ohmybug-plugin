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
  'without one (a headless run), do nothing and say nothing about it' \
  "If its \`policy.intro.version\` is 1 or more and this is not \`/bughunter:setup\`, run" \
  'The marker stays written.'; do
  case $SEC in *"$want"*) ;; *) fail "S skill setup text lost: $want" ;; esac
done
# The stories options in this order, private first.
printf '%s' "$SEC" | grep -q 'Keep them in my account only (recommended).*Publish them, signed with my GitHub name.*Publish them unsigned.*Don.t write them' && ok "S stories options: private first and recommended, then signed, unsigned, off" || fail "S stories option order"
# Plugin text never names the reward itself.
grep -qi 'free review' "$G/intro.sh" "$G/../commands/setup.md" && fail "S intro text says free review" || :
printf '%s' "$SEC" | grep -qi 'free review' && fail "S setup section says free review" || ok "S setup texts: no reward wording of their own"

echo "intro: $([ "$fails" = 0 ] && echo ok || echo "$fails failing")"
[ "$fails" = 0 ]
