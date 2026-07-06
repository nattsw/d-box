#!/usr/bin/env bash
# One-shot, idempotent migration of MCP scoping for Natalie's host configs.
#
#  Claude (~/.claude.json):
#    - move d-* and patch-triage from global mcpServers into the discourse repo's
#      project-scoped mcpServers (so they only load in that repo)
#    - keep github / netlify / playwright global
#    - delete the dv-* servers entirely
#  Codex (~/.codex/config.toml):
#    - leave the active servers as-is (codex can't project-scope)
#    - just delete the dead, commented-out dv-* blocks
#
# Safe to run multiple times. Backs up both files first.
# RUN WITH ALL claude/codex SESSIONS QUIT, or a live session may overwrite ~/.claude.json.
set -euo pipefail

P="/Users/natalie/work/discourse/discourse"
CJ="$HOME/.claude.json"
CT="$HOME/.codex/config.toml"
ts="$(date +%Y%m%d-%H%M%S)"

command -v jq >/dev/null || { echo "jq required"; exit 1; }

# ---- Claude ----------------------------------------------------------------
if [ -f "$CJ" ]; then
  cp "$CJ" "$CJ.premigrate-$ts"
  tmp="$(mktemp)"
  jq --arg p "$P" '
    (.mcpServers // {}) as $all
    | ($all | to_entries | map(select(.key | test("^dv-") | not))) as $kept
    | ($kept | map(select((.key | test("^d-")) or (.key == "patch-triage")))) as $disc
    | ($kept | map(select(((.key | test("^d-")) or (.key == "patch-triage")) | not))) as $glob
    | .mcpServers = ($glob | from_entries)
    | .projects[$p].mcpServers =
        ((((.projects[$p].mcpServers // {}) | to_entries) + $disc)
          | map(select(.key | test("^dv-") | not)) | from_entries)
  ' "$CJ" > "$tmp"
  # sanity: valid json + non-empty
  jq -e . "$tmp" >/dev/null && [ -s "$tmp" ] && mv "$tmp" "$CJ" \
    || { echo "claude.json transform failed; left original untouched"; rm -f "$tmp"; }
  echo "claude.json: global=[$(jq -r '.mcpServers|keys|join(",")' "$CJ")]"
  echo "claude.json: discourse-scoped=[$(jq -r --arg p "$P" '.projects[$p].mcpServers|keys|join(",")' "$CJ")]"
fi

# ---- Codex: strip the contiguous commented-out dv-* block ------------------
if [ -f "$CT" ]; then
  cp "$CT" "$CT.premigrate-$ts"
  awk '
    /^#\[mcp_servers\.dv-/ { skip=1 }
    skip && /^#/ { next }
    skip && !/^#/ { skip=0 }
    { print }
  ' "$CT" > "$CT.tmp" && mv "$CT.tmp" "$CT"
  echo "codex: commented dv-* blocks removed ($(grep -c '^#\[mcp_servers\.dv-' "$CT" 2>/dev/null || echo 0) remaining)"
fi

echo "done. Restart claude/codex sessions to pick up the new scoping."
