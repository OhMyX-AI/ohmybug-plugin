#!/bin/sh
# The ohmybug MCP server's headersHelper: prints the plugin's own version as
# X-OhMyBug-Plugin, so the service can count clients that need an update.
# A helper, not a static header: Claude Code keys the saved sign-in on the
# server's static headers, so a version there would ask for a new sign-in on
# every release. Any failure leaves the version out and the connection goes on.
# X-OhMyBug-Follows: this plugin follows a routed hunt's continued_by (the skill's
# loop, the gate hook and the mod read route_state), so the service may run a
# cheaper step 1 first. It is the plugin's hooks that can follow, not the version
# string, so it is sent even when the version cannot be read.
root=${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
v=$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([0-9]\{1,4\}\.[0-9]\{1,4\}\.[0-9]\{1,4\}\)".*/\1/p' \
  "$root/.claude-plugin/plugin.json" 2>/dev/null | head -n 1)
# An API key signs the plugin in without a browser (headless, CI). Claude Code
# strips credential-named variables (KEY, TOKEN, AUTH...) from a plugin helper,
# so the key is read from a file first; the variable is a fallback for a client
# that passes it. Only a whole value of the key's shape is sent (one word, no
# newline): anything else is no key (the OAuth sign-in), is never echoed, and
# cannot break the JSON or the header.
key_ok() {
  case "$1" in omb_*) ;; *) return 1 ;; esac
  case "$1" in *[!A-Za-z0-9_-]*) return 1 ;; esac
  [ "${#1}" -ge 20 ] && [ "${#1}" -le 204 ]
}
f=${OMB_STATE_DIR:-$HOME/.ohmybug}/api-key
k=
if [ -f "$f" ]; then
  k=$(head -n 1 "$f" 2>/dev/null | tr -d ' \r\t')
  key_ok "$k" || { k=; echo "OhMyBug: $f does not hold an omb_ key, so it is not used" >&2; }
fi
[ -n "$k" ] || { k=${OHMYBUG_API_KEY:-}; key_ok "$k" || k=; }
a=; [ -z "$k" ] || a=$(printf ',"Authorization":"Bearer %s"' "$k")
if [ -n "$v" ]; then printf '{"X-OhMyBug-Plugin":"%s","X-OhMyBug-Follows":"continued_by"%s}\n' "$v" "$a"; else printf '{"X-OhMyBug-Follows":"continued_by"%s}\n' "$a"; fi
