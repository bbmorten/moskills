#!/usr/bin/env bash
# Run a local SearXNG container for sandbox web search — the same mechanism the
# aimo WebUI uses (its cluster instance is ClusterIP-only + NetworkPolicy-locked,
# so sandboxes need their own). Serves the JSON API the searxng MCP server calls.
#
# Two settings are LOAD-BEARING and fail silently if lost (verified in
# ai-resource-sched deploy/aimo-webui/searxng.yaml, 2026-08-13):
#   1. search.formats must include json — upstream default is html only, and every
#      JSON query then returns 403 ("No search results found", reads as net-down).
#   2. server.limiter must be false — the bot limiter rejects exactly the shape of
#      request an MCP client sends (non-browser, tool User-Agent).
#
# Usage: ./start-searxng.sh            # runs searxng-local on port 8888
# Env:   SEARXNG_PORT (default 8888), SEARXNG_NAME (default searxng-local)
# Then:  export SEARXNG_URL=http://localhost:8888          # host use
#        export SEARXNG_URL=http://<host-LAN-IP>:8888      # before ./start-sbx.sh
set -euo pipefail

PORT="${SEARXNG_PORT:-8888}"
NAME="${SEARXNG_NAME:-searxng-local}"

if docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
  echo "$NAME already running — http://localhost:$PORT"
  exit 0
fi

cfg_dir="${TMPDIR:-/tmp}/searxng-local"
mkdir -p "$cfg_dir"
cat > "$cfg_dir/settings.yml" <<EOF
use_default_settings: true
server:
  secret_key: "$(openssl rand -hex 16)"
  limiter: false
search:
  formats:
    - html
    - json
EOF

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" -p "$PORT:8080" \
  -v "$cfg_dir/settings.yml:/etc/searxng/settings.yml" \
  docker.io/searxng/searxng:latest >/dev/null

echo "SearXNG up: http://localhost:$PORT  (JSON API: /search?q=...&format=json)"
echo "Host use:    export SEARXNG_URL=http://localhost:$PORT"
echo "Sandbox use: export SEARXNG_URL=http://<host-LAN-IP>:$PORT  # then ./start-sbx.sh"
