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
echo "mcp-headers-test: ok"
