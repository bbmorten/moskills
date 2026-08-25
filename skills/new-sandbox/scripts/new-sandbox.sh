#!/usr/bin/env bash
# Scaffold a new sandbox folder from a template folder's Claude Code config.
# Usage: new-sandbox.sh <name> [--from <template-dir>] [--parent <dir>] [--python] [--no-open]
#                       [--skills <list>] [--commands <list>] [--all-assets]
#   <name>           new folder name, e.g. sbx-minimax-trials
#   --from DIR       template to copy .claude/, .mcp.json, .gitignore, .vscode/ from (default: $PWD)
#   --parent DIR     where to create the folder (default: dirname of template)
#   --python         add .venv-ready layout: requirements.txt, .env.example, main.py, output/
#   --no-open        don't launch `code <folder>` at the end
#   --skills LIST    comma-separated skills to export: p:<name> = template's .claude/skills,
#                    g:<name> = ~/.claude/skills (bare names try template first, then global)
#   --commands LIST  comma-separated commands to export, same p:/g: prefixes
#   --all-assets     copy the template's .claude/skills + .claude/commands verbatim instead
#   --mcp LIST       comma-separated MCP server names to KEEP in the copied .mcp.json
#                    (default: keep all; "none" strips every server)
# Exported skills/commands are adapted to the sandbox: references to their old home
# (~/.claude/..., $HOME/..., or the template's .claude/...) are rewritten to <new>/.claude/,
# including cross-references between co-exported assets. Refs to non-exported assets stay global.
# Also generated: .env.example listing every ${VAR} the kept .mcp.json servers reference,
# and a "Docker Sandbox environment notes" section appended to the new folder's CLAUDE.md.
set -euo pipefail

name=""; from="$PWD"; parent=""; python=0; open=1; skills=""; commands=""; all_assets=0; mcp_keep=""
while [ $# -gt 0 ]; do
  case "$1" in
    --from) from="$2"; shift 2;;
    --parent) parent="$2"; shift 2;;
    --python) python=1; shift;;
    --no-open) open=0; shift;;
    --skills) skills="$2"; shift 2;;
    --commands) commands="$2"; shift 2;;
    --all-assets) all_assets=1; shift;;
    --mcp) mcp_keep="$2"; shift 2;;
    -h|--help) sed -n '2,20p' "$0"; exit 0;;
    *) name="$1"; shift;;
  esac
done
[ -n "$name" ] || { echo "error: name required" >&2; exit 1; }
from="$(cd "$from" && pwd)"
parent="${parent:-$(dirname "$from")}"
dst="$parent/$name"
[ ! -e "$dst" ] || { echo "error: $dst already exists" >&2; exit 1; }

# --- exported skills/commands: copy + adapt -----------------------------------
exported_kinds=(); exported_names=()

adapt_all() { # rewrite every exported asset's old paths across ALL exported files,
              # so cross-references between co-exported assets land in the sandbox too
  [ ${#exported_kinds[@]} -gt 0 ] || return 0
  local -a expr=()
  local i=0 kind asset new f
  while [ $i -lt ${#exported_kinds[@]} ]; do
    kind=${exported_kinds[$i]}; asset=${exported_names[$i]}
    new="$dst/.claude/$kind/$asset"
    expr+=(-e "s#~/.claude/$kind/$asset#$new#g")
    expr+=(-e "s#\$HOME/.claude/$kind/$asset#$new#g")
    expr+=(-e "s#$HOME/.claude/$kind/$asset#$new#g")
    expr+=(-e "s#$from/.claude/$kind/$asset#$new#g")
    i=$((i+1))
  done
  find "$dst/.claude/skills" "$dst/.claude/commands" -type f -print0 2>/dev/null | while IFS= read -r -d '' f; do
    grep -Iq . "$f" || continue   # skip binary/empty files
    sed -i '' "${expr[@]}" "$f"
  done
  find "$dst/.claude/skills" "$dst/.claude/commands" -type f -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
}

copy_asset() { # $1 kind (skills|commands), $2 spec (p:<name> | g:<name> | <name>)
  local kind=$1 spec=$2 scope asset src="" root cand
  case "$spec" in
    g:*) scope=g; asset=${spec#g:};;
    p:*) scope=p; asset=${spec#p:};;
    *)   scope=auto; asset=$spec;;
  esac
  asset=${asset%.md}
  local roots=()
  case "$scope" in
    g) roots=("$HOME/.claude");;
    p) roots=("$from/.claude");;
    *) roots=("$from/.claude" "$HOME/.claude");;
  esac
  for root in "${roots[@]}"; do
    for cand in "$root/$kind/$asset" "$root/$kind/$asset.md"; do
      if [ -e "$cand" ]; then src=$cand; break 2; fi
    done
  done
  [ -n "$src" ] || { echo "warn: $kind '$spec' not found — skipped" >&2; return 0; }
  mkdir -p "$dst/.claude/$kind"
  cp -R "$src" "$dst/.claude/$kind/$(basename "$src")"
  exported_kinds+=("$kind"); exported_names+=("$asset")
  echo "exported $kind/$asset (from $src)"
}
# ------------------------------------------------------------------------------

mkdir -p "$dst"
if [ -e "$from/.claude" ]; then
  if [ $all_assets -eq 1 ]; then
    cp -R "$from/.claude" "$dst/.claude"
  else
    # copy .claude except skills/ and commands/ — those are exported per selection below
    mkdir -p "$dst/.claude"
    for e in "$from/.claude"/* "$from/.claude"/.[!.]*; do
      [ -e "$e" ] || continue
      case "$(basename "$e")" in skills|commands) continue;; esac
      cp -R "$e" "$dst/.claude/$(basename "$e")"
    done
  fi
fi
for item in .mcp.json .vscode .gitignore .editorconfig CLAUDE.md; do
  [ -e "$from/$item" ] && cp -R "$from/$item" "$dst/$item"
done

# prune the copied .mcp.json to the selected servers ("none" strips all)
if [ -n "$mcp_keep" ] && [ -f "$dst/.mcp.json" ]; then
  MCP_KEEP="$mcp_keep" python3 - "$dst/.mcp.json" <<'PYEOF'
import json, os, sys
p = sys.argv[1]
keep = [s.strip() for s in os.environ["MCP_KEEP"].split(",") if s.strip()]
d = json.load(open(p))
servers = d.get("mcpServers", {})
if keep == ["none"]:
    kept = {}
else:
    kept = {k: v for k, v in servers.items() if k in keep}
    missing = [k for k in keep if k not in servers]
    if missing:
        print("warn: mcp servers not in template: " + ", ".join(missing), file=sys.stderr)
d["mcpServers"] = kept
with open(p, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
print("kept mcp servers: " + (", ".join(kept) or "(none)"))
PYEOF
fi

# add a searxng MCP server (aimo-style, model-independent web search) unless present
if [ -f "$dst/.mcp.json" ]; then
  python3 - "$dst/.mcp.json" <<'PYEOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
servers = d.setdefault("mcpServers", {})
if "searxng" not in servers:
    servers["searxng"] = {
        "command": "npx",
        "args": ["-y", "mcp-searxng"],
        "env": {"SEARXNG_URL": "${SEARXNG_URL}"},
    }
    with open(p, "w") as f:
        json.dump(d, f, indent=2)
        f.write("\n")
    print("added searxng MCP server (web search via SEARXNG_URL)")
PYEOF
fi

# .env.example: list every ${VAR} the kept .mcp.json servers reference
if [ -f "$dst/.mcp.json" ]; then
  mcp_vars=$(grep -o '\${[A-Z_][A-Z0-9_]*}' "$dst/.mcp.json" | tr -d '${}' | sort -u || true)
  if [ -n "$mcp_vars" ]; then
    { echo "# Tokens referenced by .mcp.json — copy to .env and fill in. Never commit .env."
      echo "# start-sbx.sh forwards any of these that are set in your shell into the Docker sandbox."
      for v in $mcp_vars; do echo "$v="; done
    } > "$dst/.env.example"
  fi
fi

# CLAUDE.md: append ground truths about the Docker sandbox so agents don't rediscover them
cat >> "$dst/CLAUDE.md" <<'NOTES'

## Docker Sandbox (sbx) environment notes

When running inside the `claude-<folder>` Docker sandbox (started via `./start-sbx.sh`):

- **Python**: the image's python3 has no `ensurepip`, so `python3 -m venv` FAILS. Use uv
  (preinstalled): `uv venv && source .venv/bin/activate && uv pip install -r requirements.txt`.
- **Browsers**: there is no system Chrome and `/opt` is not writable — do not try to install
  or symlink one there. For browser automation run `npx playwright install chromium` and make
  the playwright MCP server use it (add `"--browser","chromium"` to its args in `.mcp.json`,
  then restart the session); the chrome-devtools MCP server will not work here.
- **WebSearch**: the gateway forwards the built-in WebSearch server tool only for claude
  models; on non-claude models it 400s, so start-sbx.sh denies the tool there. Use the
  searxng MCP tools instead (`searxng_web_search`, `web_url_read`) — the same mechanism the
  aimo WebUI uses. They need `SEARXNG_URL` set (see `.env.example`); if no shared instance
  is available, run `./start-searxng.sh` on the host and
  `export SEARXNG_URL=http://<host-LAN-IP>:8888` before `./start-sbx.sh`.
- **git over https**: run `gh auth setup-git` once before cloning/pushing; creating repos
  needs a PAT with the right scopes.
- **MCP tokens**: servers in `.mcp.json` read `${VARS}` from the environment (see
  `.env.example`). On the host, put them in `.env`; for the sandbox, export them in the shell
  where you run `./start-sbx.sh` — it forwards them into the container's settings.
NOTES

if [ -n "$skills" ]; then
  IFS=, read -ra sel <<<"$skills"
  for s in "${sel[@]}"; do [ -n "$s" ] && copy_asset skills "$s"; done
fi
if [ -n "$commands" ]; then
  IFS=, read -ra sel <<<"$commands"
  for c in "${sel[@]}"; do [ -n "$c" ] && copy_asset commands "$c"; done
fi
adapt_all

# settings.local.json: rewrite absolute paths pointing at the template to the new folder
sl="$dst/.claude/settings.local.json"
if [ -f "$sl" ]; then
  base=$(basename "$from")
  # rewrite any permission path ending in /<template-basename>/ (even stale/typo'd ones) to the new folder
  sed -i '' -E "s#\(//[^)]*/${base}/#(/${dst}/#g" "$sl"
fi

# never copy secrets:
rm -f "$dst"/*.env "$dst"/.env 2>/dev/null || true
touch "$dst/.${name}-workspace"

# ship the Docker Sandbox starter + local SearXNG runner alongside the workspace
for helper in start-sbx.sh start-searxng.sh; do
  if [ -f "$(dirname "$0")/$helper" ]; then
    cp "$(dirname "$0")/$helper" "$dst/$helper" && chmod +x "$dst/$helper"
  fi
done

if [ $python -eq 1 ]; then
  mkdir -p "$dst/output"
  [ -f "$dst/.gitignore" ] || : > "$dst/.gitignore"
  printf '\n# secrets\n.env\n*.env\n!*.env.example\n# python\n.venv/\n__pycache__/\n*.pyc\n# generated\noutput/\n' >> "$dst/.gitignore"
  printf 'requests>=2.32\npython-dotenv>=1.0\n' > "$dst/requirements.txt"
  [ -f "$dst/.env.example" ] || printf '# Copy to .env and fill in. Never commit .env.\n' > "$dst/.env.example"
  printf 'API_KEY=REPLACE_ME\n' >> "$dst/.env.example"
  cat > "$dst/main.py" <<'PY'
import os
from dotenv import load_dotenv

load_dotenv()
print("API_KEY set:", bool(os.environ.get("API_KEY")))
PY
fi

cat > "$dst/README.md" <<MD
# $name

Sandbox created $(date +%F) from \`$(basename "$from")\` (copied \`.claude/\`, \`.mcp.json\`, \`.gitignore\`).

$( [ $python -eq 1 ] && printf '## Setup\n\n```bash\ncp .env.example .env\n# with uv (preinstalled in the Docker sandbox; python3 -m venv fails there — no ensurepip):\nuv venv && source .venv/bin/activate && uv pip install -r requirements.txt\n# fallback without uv:\n# python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt\npython main.py\n```\n' )
MD

echo "created $dst"
ls -A "$dst"
if [ $open -eq 1 ]; then
  if [ "$(uname)" = Darwin ] && [ -d "/Applications/Visual Studio Code.app" ]; then open -a "Visual Studio Code" "$dst"
  elif command -v code >/dev/null; then code "$dst"; fi
fi
