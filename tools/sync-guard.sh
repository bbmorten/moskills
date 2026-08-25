#!/usr/bin/env bash
# Refresh tools/guard.mjs from the skills service image, so local validation
# stays byte-identical to the screening the server runs. Re-run the validator
# afterwards: a rule added upstream can block a skill that passed last month.
set -euo pipefail

SRC="${SKILLS_IMAGE_DIR:-$HOME/git-msp_x/ai-resource-sched/deploy-skills/image}/guard.mjs"
DEST="$(cd "$(dirname "$0")" && pwd)/guard.mjs"

[ -f "$SRC" ] || { echo "not found: $SRC (set SKILLS_IMAGE_DIR)" >&2; exit 1; }

{
  echo "// VENDORED VERBATIM from ai-resource-sched/deploy-skills/image/guard.mjs"
  echo "// Do not edit here. Refresh with tools/sync-guard.sh so local validation"
  echo "// stays byte-identical to the screening the skills service actually runs."
  cat "$SRC"
} > "$DEST"

echo "refreshed $DEST from $SRC"
