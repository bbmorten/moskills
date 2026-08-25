---
name: new-sandbox
description: Scaffold a new sandbox project folder (sbx-*) next to the current one, copying this project's Claude Code config (.claude/, .mcp.json, settings.local.json with paths rewritten, .gitignore, .vscode) and optionally a Python venv-ready layout (requirements.txt, .env.example, main.py, output/). Asks the user which skills/commands to export into the sandbox — from ~/.claude and from the current project — and adapts the exported ones (path rewrite) to the new workspace. Use when the user says "create a new sandbox", "duplicate this folder as sbx-...", "new sbx folder from scratch", or "/new-sandbox <name>".
---

# new-sandbox

Creates `<parent>/<name>` from a template folder (default: the current working directory) and opens it in VS Code. Skills and commands are **not** copied blindly: the user picks which ones to export (from `~/.claude` and/or the template project), and the exported copies are adapted to the new sandbox workspace.

## Steps

1. Determine the name (required, e.g. `sbx-minimax-trials`). Ask only if the user gave none.
2. **Ask which skills/commands to export.** Enumerate the candidates from both sources:

   ```bash
   ls ~/.claude/skills ~/.claude/commands "$PWD/.claude/skills" "$PWD/.claude/commands" 2>/dev/null
   ```

   Then ask via AskUserQuestion (multiSelect: one question for skills, one for commands). AskUserQuestion allows at most 4 options per question, so offer the most relevant candidates — the template project's own assets first, then global ones matching the sandbox's topic (e.g. an `oreilly` sandbox → O'Reilly-related skills) — and tell the user the full list is available via "Other" (they can type any names from the enumeration). Always make "None" reachable (deselect everything). Skip the ask only when the user already named the assets to export in their prompt.

   Also ask which **MCP servers** to keep (third multiSelect question; enumerate them with `python3 -c 'import json;print(*json.load(open(".mcp.json"))["mcpServers"])'` in the template). For Docker-sandbox use recommend dropping browser-dependent servers (`chrome-devtools`, `playwright` — no Chrome in the container) and keeping the topic-relevant ones. A `searxng` server is always (re-)added by the script for web search.
3. Run the bundled script from the **template** folder (usually `$PWD`), passing the selections:

   ```bash
   ~/.claude/skills/new-sandbox/scripts/new-sandbox.sh <name> \
     [--skills p:<name>,g:<name>,...] [--commands p:<name>,g:<name>,...] [--all-assets] \
     [--mcp <name>,<name>,...] [--from <template>] [--parent <dir>] [--python] [--no-open]
   ```

   - `p:<name>` exports from the template's `.claude/skills|commands`, `g:<name>` from `~/.claude/skills|commands`; a bare name tries the template first, then global. Omitting `--skills`/`--commands` exports none; `--all-assets` restores the old copy-everything-from-template behaviour (use it only if the user asks for "everything").
   - `--mcp` prunes the copied `.mcp.json` to the named servers (`none` strips all; omit the flag to keep all). The script then always adds a `searxng` server (`npx mcp-searxng`, driven by `SEARXNG_URL`) — aimo-WebUI-style web search that works with any gateway model, unlike the built-in WebSearch server tool which the gateway only forwards for claude models.
   - The script also generates `.env.example` from every `${VAR}` the kept servers reference, and appends a "Docker Sandbox environment notes" section to the new folder's `CLAUDE.md` (uv instead of venv, no Chrome/`/opt`, searxng for web search, `gh auth setup-git`, token forwarding).
   - Pass `--python` when the user will run Python code in the sandbox.
   - The script never copies `.env` / `*.env` secrets; it copies `*.env.example` only if asked (do it manually with `cp`).
4. **Verify the adaptation.** The script rewrites references to every exported asset's old home (`~/.claude/skills|commands/<name>`, the `$HOME` and absolute-path spellings, and `<template>/.claude/...`) to `<new-folder>/.claude/...` across **all** exported files — so cross-references between co-exported assets (e.g. a command that calls a skill's scripts) land in the sandbox too — and keeps `*.sh` executable. Grep for leftovers and fix any by hand (other absolute paths, hardcoded template folder names inside skill scripts, etc.):

   ```bash
   grep -rn "$HOME/.claude/\|<template-abs-path>" <new-folder>/.claude/skills <new-folder>/.claude/commands
   ```

   References to *non-exported* global skills/commands are intentionally left pointing at `~/.claude`; a leftover pointing at an asset the user chose to export means something the sed rules missed — fix it by hand.
5. If the user supplied code to run (e.g. a script in the prompt), write it into the new folder as a properly named file (`<topic>.py`), make it read its API key from the environment via `python-dotenv`, update `.env.example` with the actual variable names (e.g. `MINIMAX_API_KEY`), and extend `README.md` with run instructions.
6. Run `python3 -m py_compile` on any Python file you created and report the folder tree, including which skills/commands were exported and from where.
7. **Docker Sandbox (sbx)**: every scaffolded folder gets a copy of `scripts/start-sbx.sh`. If the user wants to run Claude Code inside a Docker Sandbox against the GPU Pool gateway, tell them:

   ```bash
   export GPUPOOL_API_KEY=gpk_...
   cd <new-folder>
   ./start-sbx.sh                         # creates claude-<folder> if missing, configures, attaches
   ./start-sbx.sh --model BT/qwen3.6-35b-a3b   # pick a model
   ./start-sbx.sh my-name --no-attach     # custom sandbox name, configure only
   ```

   The script is idempotent: it re-applies the gateway config to the container's `~/.claude/settings.json` on every start (that file is lost on `sbx rm`, but the workspace `.mcp.json` is bind-mounted and persists). Defaults: gateway `http://192.168.48.31:30800`, model `BT/gpt-oss-120b`, `CLAUDE_CODE_MAX_OUTPUT_TOKENS=65536`; override via `GATEWAY`/`MODEL`/`MAX_OUTPUT` env or flags. On every start it also forwards every `${VAR}` the workspace `.mcp.json` references that is set in the launching shell (MCP tokens, `SEARXNG_URL`) into the container settings, and denies the built-in WebSearch tool when `MODEL` is not a claude model (the gateway 400s Anthropic server tools there — searxng MCP is the web-search path; run `./start-searxng.sh` on the host if no shared SearXNG instance is available).

## What gets copied

| Item | Behaviour |
|---|---|
| `.claude/` (minus `skills/`, `commands/`) | copied; `settings.local.json` absolute paths rewritten to the new folder |
| `.claude/skills/`, `.claude/commands/` | only the ones the user selects, exported from `~/.claude` (`g:`) or the template (`p:`), then path-adapted to the sandbox; `--all-assets` copies the template's verbatim |
| `.mcp.json` | copied if present; pruned to the `--mcp` selection; a `searxng` web-search server is added |
| `.vscode/`, `.gitignore`, `.editorconfig`, `CLAUDE.md` | copied if present; `CLAUDE.md` gets a "Docker Sandbox environment notes" section appended (created if absent) |
| `.env`, `*.env` | **never** copied |
| `.env.example` | generated from the `${VAR}`s the kept `.mcp.json` servers reference |
| `README.md` | generated fresh |
| `start-sbx.sh`, `start-searxng.sh` | copied from this skill's `scripts/` — Docker Sandbox starter + local SearXNG for web search |
