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
# Authorization: an API key from ~/.ohmybug/api-key, when the user put one there (below).
root=${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
v=$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([0-9]\{1,4\}\.[0-9]\{1,4\}\.[0-9]\{1,4\}\)".*/\1/p' \
  "$root/.claude-plugin/plugin.json" 2>/dev/null | head -n 1)
# An API key signs the plugin in without a browser (headless, CI). Claude Code
# strips credential-named variables (KEY, TOKEN, AUTH...) from a plugin helper,
# so the key is read from a file, never from the environment (where an exported
# key would silently switch an OAuth user to that key's account). The whole file
# is the value: CR, a BOM, blank lines and the spaces at each end are dropped,
# and what is left must be one word of the key's shape (a second line or an
# inner space is not a key). Anything else is no key (the OAuth sign-in), gets a
# one-line note that never echoes it, and cannot break the JSON or the header.
key_ok() {
  case "$1" in omb_*) ;; *) return 1 ;; esac
  case "$1" in *[!A-Za-z0-9_-]*) return 1 ;; esac
  [ "${#1}" -ge 20 ] && [ "${#1}" -le 204 ]
}
f=${OMB_STATE_DIR:-$HOME/.ohmybug}/api-key
k=
if [ -f "$f" ] && [ ! -r "$f" ]; then
  echo "OhMyBug: $f cannot be read, so the plugin signs in without it" >&2
elif [ -f "$f" ]; then
  k=$(head -c 4096 "$f" 2>/dev/null)
  k=${k#"$(printf '\357\273\277')"}
  k=$(printf '%s\n' "$k" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$')
  key_ok "$k" || { k=; echo "OhMyBug: $f does not hold one omb_ key (one line, no spaces, 20-204 characters), so it is not used" >&2; }
fi
a=; [ -z "$k" ] || a=$(printf ',"Authorization":"Bearer %s"' "$k")
if [ -n "$v" ]; then printf '{"X-OhMyBug-Plugin":"%s","X-OhMyBug-Follows":"continued_by"%s}\n' "$v" "$a"; else printf '{"X-OhMyBug-Follows":"continued_by"%s}\n' "$a"; fi
