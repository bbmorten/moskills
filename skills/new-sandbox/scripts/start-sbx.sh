#!/usr/bin/env bash
# Start (creating + configuring if needed) a Docker Sandbox (sbx) running Claude Code
# against the GPU Pool AI Gateway, for the workspace this script sits in.
#
# Based on gpupool-sandbox-setup.sh (sbx-trial). Key facts:
#  - Inside the sandbox only ~/.claude/{skills,projects,sessions,todos,shell-snapshots,
#    statsig} are on persistent volumes. ~/.claude/settings.json lives on the container's
#    writable layer: it survives `sbx stop`/`sbx run` but is LOST after `sbx rm`.
#    This script therefore (re-)applies the gateway config on EVERY start — idempotent.
#  - The workspace .mcp.json is bind-mounted from the host and always persists.
#  - Every ${VAR} referenced by the workspace .mcp.json that is set in the launching
#    shell (MCP tokens, SEARXNG_URL, ...) is forwarded into the container settings env.
#  - With a non-claude MODEL the built-in WebSearch tool is denied (the gateway 400s
#    Anthropic server tools on such models); web search then goes through the searxng
#    MCP server (see start-searxng.sh / SEARXNG_URL).
#
# Usage:
#   ./start-sbx.sh [sandbox-name] [--model MODEL] [--workspace DIR] [--no-attach]
# Env overrides: GATEWAY, MODEL, MAX_OUTPUT, GPUPOOL_API_KEY (required)
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
SANDBOX=""; WORKSPACE="$script_dir"; ATTACH=1
GATEWAY="${GATEWAY:-http://192.168.48.31:30800}"
MODEL="${MODEL:-BT/gpt-oss-120b}"
# Claude Code's default output cap is 32000 and it aborts any response exceeding it.
# This value is also the max_tokens sent on EVERY request, so it must stay within what
# the serving provider accepts (65536 and 131072 verified OK, 2026-08-08).
MAX_OUTPUT="${MAX_OUTPUT:-65536}"

while [ $# -gt 0 ]; do
  case "$1" in
    --model) MODEL="$2"; shift 2;;
    --workspace|-w) WORKSPACE="$(cd "$2" && pwd)"; shift 2;;
    --gateway) GATEWAY="$2"; shift 2;;
    --no-attach) ATTACH=0; shift;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) SANDBOX="$1"; shift;;
  esac
done
SANDBOX="${SANDBOX:-claude-$(basename "$WORKSPACE")}"
: "${GPUPOOL_API_KEY:?export GPUPOOL_API_KEY=gpk_... before running}"

# 1. Create the sandbox if it doesn't exist yet (workspace bind-mounted from host).
if ! sbx ls 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$SANDBOX"; then
  echo ">> creating sandbox $SANDBOX for workspace $WORKSPACE"
  sbx create --name "$SANDBOX" claude "$WORKSPACE"
else
  echo ">> sandbox $SANDBOX already exists"
fi

# 2. (Re-)apply the GPU Pool gateway config to ~/.claude/settings.json inside the sandbox.
# Forward every ${VAR} the workspace .mcp.json references that is set in this shell
# (MCP auth tokens, SEARXNG_URL, ...) so the servers can authenticate in the container.
fwd_args=(); fwd_names=""
if [ -f "$WORKSPACE/.mcp.json" ]; then
  for v in $(grep -o '\${[A-Z_][A-Z0-9_]*}' "$WORKSPACE/.mcp.json" | tr -d '${}' | sort -u); do
    if [ -n "${!v:-}" ]; then fwd_args+=(-e "FWD_$v=${!v}"); fwd_names="$fwd_names $v"; fi
  done
fi
echo ">> configuring gateway=$GATEWAY model=$MODEL max_output=$MAX_OUTPUT"
[ -n "$fwd_names" ] && echo ">> forwarding into sandbox settings:$fwd_names"
case "$MODEL" in
  *claude*|*Claude*) : ;;
  *) echo ">> non-claude model: denying built-in WebSearch (gateway 400s server tools on it); searxng MCP is the web-search path";;
esac
sbx exec \
  -e CFG_GATEWAY="$GATEWAY" \
  -e CFG_KEY="$GPUPOOL_API_KEY" \
  -e CFG_MODEL="$MODEL" \
  -e CFG_MAX_OUTPUT="$MAX_OUTPUT" \
  ${fwd_args[@]+"${fwd_args[@]}"} \
  "$SANDBOX" node -e '
const fs = require("fs");
const path = process.env.HOME + "/.claude/settings.json";
const s = fs.existsSync(path) ? JSON.parse(fs.readFileSync(path, "utf8")) : {};
s.env = Object.assign({}, s.env, {
  ANTHROPIC_BASE_URL: process.env.CFG_GATEWAY,
  ANTHROPIC_AUTH_TOKEN: process.env.CFG_KEY,
  ANTHROPIC_MODEL: process.env.CFG_MODEL,
  GPUPOOL_API_KEY: process.env.CFG_KEY,
  CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY: "1",
  CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS: "1",
  CLAUDE_CODE_MAX_OUTPUT_TOKENS: process.env.CFG_MAX_OUTPUT,
});
for (const k of Object.keys(process.env)) {
  if (k.startsWith("FWD_")) s.env[k.slice(4)] = process.env[k];
}
// Built-in WebSearch is an Anthropic server tool: the gateway forwards it only for
// claude models and 400s otherwise — deny it there so agents use searxng MCP instead.
const claude = /claude/i.test(process.env.CFG_MODEL || "");
s.permissions = s.permissions || {};
const deny = new Set(s.permissions.deny || []);
if (claude) deny.delete("WebSearch"); else deny.add("WebSearch");
s.permissions.deny = Array.from(deny);
if (!s.permissions.deny.length) delete s.permissions.deny;
s.enableAllProjectMcpServers = true;
fs.writeFileSync(path, JSON.stringify(s, null, 2) + "\n");
console.log("wrote " + path);
'

# 3. Attach (interactive Claude session in the sandbox).
if [ $ATTACH -eq 1 ]; then
  exec sbx run claude --name "$SANDBOX"
else
  echo "Done. Attach with: sbx run claude --name $SANDBOX"
fi
