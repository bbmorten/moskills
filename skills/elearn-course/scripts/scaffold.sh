#!/usr/bin/env bash
# Scaffold a new course from sites/elearn-course-template.
#
# Course IDENTITY is domain-qualified: the directory, k8s resource names, image,
# and catalog slug are <domain-label>-<slug> (e.g. morten-local-ccaf), while the
# browser HOST stays clean as <slug>.<base-domain> (e.g. ccaf.morten.local). This
# lets the same logical course live under several base domains without colliding.
#
# Usage:
#   scaffold.sh <slug> "<Title>" [--dev-port N] [--nodeport N] [--fwd-port N]
#               [--host H] [--platform-url U] [--platform-public-url U] [--image REF]
#
# <slug> is the BARE slug (e.g. ccaf); the domain prefix is added automatically.
# Idempotent-ish: refuses to overwrite an existing sites/elearn-<course-id>.
set -euo pipefail

# This skill lives in ~/.claude, outside the repo: resolve the repo from the
# working directory (or ELEARN_REPO_ROOT), never from the script's own location.
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${ELEARN_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -d "$ROOT/elearn-platform" ] || { echo "ERROR: not inside the mydocs-plog-nextra repo (cd there or set ELEARN_REPO_ROOT)" >&2; exit 2; }
TEMPLATE="$ROOT/sites/elearn-course-template"

# Inherit the active deployment (env ELEARN_DEPLOYMENT > .elearn-deployment) so the
# scaffolded course is domain-qualified for the right base domain.
source "$ROOT/elearn-platform/scripts/deployment.sh"
apply_deployment || true
BASE_DOMAIN="$(resolve_base_domain)"

SLUG="${1:?slug required}"; shift          # bare slug, e.g. ccaf
TITLE="${1:?title required}"; shift

DEV_PORT=3971
NODEPORT=30971
FWD_PORT=8971
HOST=""
PLATFORM_URL="http://elearn-platform"            # in-cluster Service DNS (same namespace, plain HTTP)
PLATFORM_PUBLIC_URL="https://$BASE_DOMAIN"       # browser-facing platform origin (TLS at the ingress)
IMAGE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dev-port) DEV_PORT="$2"; shift 2;;
    --nodeport) NODEPORT="$2"; shift 2;;
    --fwd-port) FWD_PORT="$2"; shift 2;;
    --host) HOST="$2"; shift 2;;
    --platform-url) PLATFORM_URL="$2"; shift 2;;
    --platform-public-url) PLATFORM_PUBLIC_URL="$2"; shift 2;;
    --image) IMAGE="$2"; shift 2;;
    *) echo "unknown flag: $1" >&2; exit 2;;
  esac
done

[[ "$SLUG" =~ ^[a-z0-9-]+$ ]] || { echo "slug must be kebab-case (a-z0-9-)" >&2; exit 2; }
# Domain-qualified identity vs clean public host.
COURSE_ID="$(course_id "$BASE_DOMAIN" "$SLUG")"   # e.g. morten-local-ccaf
HOST="${HOST:-$SLUG.$BASE_DOMAIN}"                # e.g. ccaf.morten.local
IMAGE="${IMAGE:-elearn-$COURSE_ID:dev}"
DEST="$ROOT/sites/elearn-$COURSE_ID"

[ -e "$DEST" ] && { echo "ERROR: $DEST already exists" >&2; exit 1; }
[ -d "$TEMPLATE" ] || { echo "ERROR: template not found at $TEMPLATE" >&2; exit 1; }

echo "Scaffolding sites/elearn-$COURSE_ID from template (slug=$SLUG host=$HOST)…"
# Copy everything except build/dev artifacts.
rsync -a --exclude node_modules --exclude .next --exclude out \
      --exclude 'public/_pagefind' "$TEMPLATE/" "$DEST/"

render() { # <src> <dst>
  # {{SLUG}} carries the domain-qualified COURSE_ID (k8s names, COURSE_SLUG,
  # localStorage namespace); {{HOST}} carries the clean public host.
  perl -pe "
    s/\{\{SLUG\}\}/$COURSE_ID/g;
    s/\{\{TITLE\}\}/$TITLE/g;
    s/\{\{HOST\}\}/$HOST/g;
    s/\{\{BASE_DOMAIN\}\}/$BASE_DOMAIN/g;
    s{\{\{IMAGE\}\}}{$IMAGE}g;
    s/\{\{NODEPORT\}\}/$NODEPORT/g;
    s/\{\{FWD_PORT\}\}/$FWD_PORT/g;
    s{\{\{PLATFORM_URL\}\}}{$PLATFORM_URL}g;
    s{\{\{PLATFORM_PUBLIC_URL\}\}}{$PLATFORM_PUBLIC_URL}g;
  " "$1" > "$2"
}

render "$DEST/Tiltfile.tmpl" "$DEST/Tiltfile" && rm "$DEST/Tiltfile.tmpl"
render "$DEST/k8s/deployment.yaml.tmpl" "$DEST/k8s/deployment.yaml" && rm "$DEST/k8s/deployment.yaml.tmpl"

# package.json: name (domain-qualified) + dev/start port.
perl -pi -e "s/\"elearn-course-template\"/\"elearn-$COURSE_ID\"/g; s/3970/$DEV_PORT/g;" "$DEST/package.json"

# Release history starts empty (the template's belongs to the template), and the
# page created/updated dates are computed for THIS course's content. Both files
# are baked into the image later — see content/history.mdx.
node "$SKILL_DIR/scripts/record-deploy.mjs" init "$DEST" --course-id "$COURSE_ID" --slug "$SLUG"
node "$DEST/scripts/gen-page-timestamps.mjs"

echo "Done. Created:"
echo "  $DEST  (name=elearn-$COURSE_ID slug=$SLUG host=$HOST base-domain=$BASE_DOMAIN devport=$DEV_PORT nodeport=$NODEPORT fwd=$FWD_PORT image=$IMAGE)"
echo "COURSE_ID=$COURSE_ID"
echo "HOST=$HOST"
