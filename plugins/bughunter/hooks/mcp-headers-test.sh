#!/bin/bash
# mcp-headers.sh prints the manifest's version and the route opt-in, and the opt-in alone on anything else.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
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
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.claude-plugin"
for bad in '{"version":"0.150.0-beta"}' '{"version":"v1.2.3"}' '{"version":"1.2"}' '{"name":"x"}' 'not json' '{"version":"1.2.3\"}'; do
  printf '%s\n' "$bad" > "$TMP/.claude-plugin/plugin.json"
  out=$(CLAUDE_PLUGIN_ROOT="$TMP" sh "$ROOT/hooks/mcp-headers.sh")
  [ "$out" = '{"X-OhMyBug-Follows":"continued_by"}' ] || { echo "manifest $bad: got $out"; exit 1; }
done
rm "$TMP/.claude-plugin/plugin.json"
[ "$(CLAUDE_PLUGIN_ROOT="$TMP" sh "$ROOT/hooks/mcp-headers.sh")" = '{"X-OhMyBug-Follows":"continued_by"}' ] || { echo "missing manifest"; exit 1; }
# The API key: from the file (Claude Code strips credential-named variables
# from a plugin helper), else the variable; only a key's shape is sent, and a
# value of any other shape is neither sent nor echoed.
K=omb_0123456789abcdef0123456789abcdef0123456789abcdef
mkdir -p "$TMP/st"
hd() { env -u OHMYBUG_API_KEY CLAUDE_PLUGIN_ROOT="$ROOT" OMB_STATE_DIR="$TMP/st" "$@" sh "$ROOT/hooks/mcp-headers.sh" 2>"$TMP/err"; }
[ "$(hd)" = "$got" ] || { echo "no key: output changed"; exit 1; }
printf '%s\n' "$K" > "$TMP/st/api-key"
[ "$(hd)" = "${got%\}},\"Authorization\":\"Bearer $K\"}" ] || { echo "key file: got $(hd | sed "s/$K/<key>/")"; exit 1; }
[ ! -s "$TMP/err" ] || { echo "key file: stderr not empty"; exit 1; }
python3 -c 'import json,sys; json.loads(sys.argv[1])' "$(hd)" || { echo "key file: not JSON"; exit 1; }
rm "$TMP/st/api-key"
[ "$(hd OHMYBUG_API_KEY="$K")" = "${got%\}},\"Authorization\":\"Bearer $K\"}" ] || { echo "env key: no header"; exit 1; }
for bad in 'omb_a"b0123456789abcdef' 'sk-0123456789abcdef0123456789' 'omb_short' 'omb_0123456789abcdef","X":"y'; do
  printf '%s\n' "$bad" > "$TMP/st/api-key"
  out=$(hd)
  [ "$out" = "$got" ] || { echo "bad key [$bad]: sent something"; exit 1; }
  ! grep -qF -- "$bad" "$TMP/err" || { echo "bad key [$bad]: echoed on stderr"; exit 1; }
done
: > "$TMP/st/api-key"
[ "$(hd)" = "$got" ] || { echo "empty key file: sent something"; exit 1; }
echo "mcp-headers-test: ok"
