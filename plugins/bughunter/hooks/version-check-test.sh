#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/plugin/.codex-plugin" "$TMP/state" "$TMP/bin"
printf '{"version":"0.80.0"}\n' > "$TMP/plugin/.codex-plugin/plugin.json"
printf '{"version":"0.81.0"}\n' > "$TMP/latest.json"
cat > "$TMP/bin/curl" <<'SH'
#!/bin/sh
cat "$OMB_VERSION_LATEST"
SH
chmod +x "$TMP/bin/curl"
run() {
  PATH="$TMP/bin:$PATH" OMB_VERSION_LATEST="$TMP/latest.json" OMB_VERSION_MANIFEST="$TMP/plugin/.codex-plugin/plugin.json" OMB_VERSION_STATE_DIR="$TMP/state" OMB_VERSION_URL=https://example.invalid/plugin.json "$ROOT/hooks/version-check.sh"
}
out=$(run)
echo "$out" | grep -q '0.81.0 is available'
echo "$out" | grep -q 'Review changed hook definitions in /hooks'
echo "$out" | grep -q 'Claude Code' # default client instruction
[ "$(cat "$TMP/state/version-notice-v1-claude")" = 'claude:0.80.0->0.81.0' ]
printf '{"version":"0.82.0"}\n' > "$TMP/latest.json"
out=$(PLUGIN_DATA=1 run)
echo "$out" | grep -q 'codex plugin marketplace upgrade ohmybug'
# Equal and malformed versions stay silent.
printf '{"version":"0.82.0"}\n' > "$TMP/plugin/.codex-plugin/plugin.json"
printf '{"version":"not-semver"}\n' > "$TMP/latest.json"
out=$(run); [ -z "$out" ]
[ "$(cat "$TMP/state/version-notice-v1-codex")" = 'codex:0.80.0->0.82.0' ]
# A json.py or re.py in the session's folder is never imported: the notice still comes.
mkdir -p "$TMP/pl"; for m in json re; do printf 'open("%s", "w").close()\nraise ImportError("planted")\n' "$TMP/ran" > "$TMP/pl/$m.py"; done
printf '{"version":"0.80.0"}\n' > "$TMP/plugin/.codex-plugin/plugin.json"; printf '{"version":"0.81.0"}\n' > "$TMP/latest.json"; rm -rf "$TMP/state"; mkdir -p "$TMP/state"
out=$(cd "$TMP/pl" && run)
echo "$out" | grep -q '0.81.0 is available'
[ ! -e "$TMP/ran" ]
echo 'version-check: ok'
