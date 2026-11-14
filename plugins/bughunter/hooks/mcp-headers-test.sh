#!/bin/bash
# mcp-headers.sh prints the manifest's version and the route opt-in, and the opt-in alone on anything else.
# With a key in the key file it adds Authorization; nothing else adds it.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# A machine with a key must not change what the rows below see, nor print it.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; unset OHMYBUG_API_KEY OMB_STATE_DIR
want=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ROOT/.claude-plugin/plugin.json")
got=$(CLAUDE_PLUGIN_ROOT="$ROOT" sh "$ROOT/hooks/mcp-headers.sh")
[ "$got" = "{\"X-OhMyBug-Plugin\":\"$want\",\"X-OhMyBug-Follows\":\"continued_by\"}" ] || { echo "real manifest: got $got, want $want"; exit 1; }
# With no CLAUDE_PLUGIN_ROOT it finds the plugin from its own path.
[ "$(env -u CLAUDE_PLUGIN_ROOT sh "$ROOT/hooks/mcp-headers.sh")" = "$got" ] || { echo "no root: differs"; exit 1; }
# .mcp.json runs this helper and has no static headers (they key the saved sign-in).
python3 - "$ROOT/.mcp.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))['mcpServers']['ohmybug']
assert s.get('headersHelper') == 'sh "${CLAUDE_PLUGIN_ROOT}/hooks/mcp-headers.sh"', s
assert 'headers' not in s, s
PY
mkdir -p "$TMP/.claude-plugin"
for bad in '{"version":"0.150.0-beta"}' '{"version":"v1.2.3"}' '{"version":"1.2"}' '{"name":"x"}' 'not json' '{"version":"1.2.3\"}'; do
  printf '%s\n' "$bad" > "$TMP/.claude-plugin/plugin.json"
  out=$(CLAUDE_PLUGIN_ROOT="$TMP" sh "$ROOT/hooks/mcp-headers.sh")
  [ "$out" = '{"X-OhMyBug-Follows":"continued_by"}' ] || { echo "manifest $bad: got $out"; exit 1; }
done
rm "$TMP/.claude-plugin/plugin.json"
[ "$(CLAUDE_PLUGIN_ROOT="$TMP" sh "$ROOT/hooks/mcp-headers.sh")" = '{"X-OhMyBug-Follows":"continued_by"}' ] || { echo "missing manifest"; exit 1; }
# The API key: from the file only (Claude Code strips credential-named
# variables from a plugin helper, and an exported key must not switch an OAuth
# user's account); only a key's shape is sent, and any other value is neither
# sent nor echoed.
K=omb_0123456789abcdef0123456789abcdef0123456789abcdef
mkdir -p "$TMP/st"
hd() { env -u OHMYBUG_API_KEY CLAUDE_PLUGIN_ROOT="$ROOT" OMB_STATE_DIR="$TMP/st" "$@" sh "$ROOT/hooks/mcp-headers.sh" 2>"$TMP/err"; }
[ "$(hd)" = "$got" ] || { echo "no key: output changed"; exit 1; }
printf '%s\n' "$K" > "$TMP/st/api-key"
[ "$(hd)" = "${got%\}},\"Authorization\":\"Bearer $K\"}" ] || { echo "key file: got $(hd | sed "s/$K/<key>/")"; exit 1; }
[ ! -s "$TMP/err" ] || { echo "key file: stderr not empty"; exit 1; }
python3 -c 'import json,sys; json.loads(sys.argv[1])' "$(hd)" || { echo "key file: not JSON"; exit 1; }
rm "$TMP/st/api-key"
[ "$(hd OHMYBUG_API_KEY="$K")" = "$got" ] || { echo "env key: the variable was sent"; exit 1; }
[ ! -s "$TMP/err" ] || { echo "no key: stderr not empty"; exit 1; }
for bad in 'omb_a"b0123456789abcdef' 'sk-0123456789abcdef0123456789' 'omb_short' 'omb_0123456789abcdef","X":"y'; do
  printf '%s\n' "$bad" > "$TMP/st/api-key"
  out=$(hd)
  [ "$out" = "$got" ] || { echo "bad key [$bad]: sent something"; exit 1; }
  ! grep -qF -- "$bad" "$TMP/err" || { echo "bad key [$bad]: echoed on stderr"; exit 1; }
done
: > "$TMP/st/api-key"
[ "$(hd)" = "$got" ] || { echo "empty key file: sent something"; exit 1; }
K2=omb_fedcba9876543210fedcba9876543210fedcba9876543210
withk() { printf '%s' "${got%\}},\"Authorization\":\"Bearer $1\"}"; }
# A bad file is not replaced by the variable, gets a note, and is never echoed.
printf 'not a key\n' > "$TMP/st/api-key"
[ "$(hd OHMYBUG_API_KEY="$K2")" = "$got" ] || { echo "bad file: the variable was sent"; exit 1; }
grep -q 'does not hold one omb_ key' "$TMP/err" && ! grep -q 'not a key' "$TMP/err" || { echo "bad file: no note, or its content echoed"; exit 1; }
# An unreadable file says so, rather than that it holds no key.
printf '%s\n' "$K" > "$TMP/st/api-key"; chmod 000 "$TMP/st/api-key"
if [ ! -r "$TMP/st/api-key" ]; then
  [ "$(hd)" = "$got" ] && grep -q 'cannot be read' "$TMP/err" || { echo "unreadable file: no note"; exit 1; }
fi
chmod 600 "$TMP/st/api-key"
# Padding and CRLF are stripped from the file's line.
printf ' %s \r\n' "$K" > "$TMP/st/api-key"
[ "$(hd)" = "$(withk "$K")" ] || { echo "crlf key file: not read"; exit 1; }
rm "$TMP/st/api-key"
# The whole file is the value: a BOM and a leading blank line are dropped; a
# second line or an inner space is not a key; the length bounds hold.
printf '\357\273\277\n%s\n\n' "$K" > "$TMP/st/api-key"
[ "$(hd)" = "$(withk "$K")" ] || { echo "bom and blank line: not read"; exit 1; }
for bad in "$K
$K2" "omb_0123456789 abcdef0123456789" "omb_$(printf '%0201d' 0)" "omb_012345678901234"; do
  printf '%s\n' "$bad" > "$TMP/st/api-key"
  [ "$(hd)" = "$got" ] || { echo "file [${bad%%
*}...]: sent something"; exit 1; }
  grep -q 'does not hold one omb_ key' "$TMP/err" || { echo "file [${bad%%
*}...]: no note"; exit 1; }
done
for good in "omb_0123456789abcdef" "omb_$(printf '%0200d' 0 | cut -c1-200)"; do
  printf '%s\n' "$good" > "$TMP/st/api-key"
  [ "$(hd)" = "$(withk "$good")" ] || { echo "file length bound: ${#good} rejected"; exit 1; }
done
rm "$TMP/st/api-key"
# The default path: no OMB_STATE_DIR, the key under HOME.
mkdir -p "$TMP/h2/.ohmybug" && printf '%s\n' "$K" > "$TMP/h2/.ohmybug/api-key"
[ "$(env -u OHMYBUG_API_KEY -u OMB_STATE_DIR HOME="$TMP/h2" CLAUDE_PLUGIN_ROOT="$ROOT" sh "$ROOT/hooks/mcp-headers.sh")" = "$(withk "$K")" ] || { echo "default path: no header"; exit 1; }
echo "mcp-headers-test: ok"
