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
if [ -n "$v" ]; then printf '{"X-OhMyBug-Plugin":"%s","X-OhMyBug-Follows":"continued_by"}\n' "$v"; else printf '{"X-OhMyBug-Follows":"continued_by"}\n'; fi
