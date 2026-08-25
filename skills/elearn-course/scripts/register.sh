#!/usr/bin/env bash
# Register (or update) a course in the platform catalog via the admin API.
# Preferred over psql: the platform owns schema + validation.
#
# Usage:
#   register.sh <slug> "<Title>" [host] [--image REF] [--description D] [--group KEY]
#               [--status DRAFT|PUBLISHED|ARCHIVED] [--course-slug SLUG]
#               [--platform-url URL] [--admin-email E] [--admin-password P]
#
# <slug> is the BARE slug (e.g. ccaf). The catalog slug stored is the
# domain-qualified course id (<domain-label>-<slug>), matching the course pod's
# COURSE_SLUG so enrollment checks line up. [host] defaults to <slug>.<base-domain>.
# --description defaults to the course's package.json "description" (scaffold.sh
# seeds it); when neither is set the key is OMITTED so a re-registration never
# blanks what an admin typed on /admin/courses. --group files the course under a
# CourseGroup key (e.g. cisco-university); omitted = leave the filing alone.
# --course-slug overrides the stored catalog slug entirely (mirrors deploy.sh) —
# use it for a legacy course whose catalog slug is decoupled from its course-id
# (e.g. elearn-local-ccaf's catalog slug stays `ccaf`), so re-registering under a
# new base domain UPDATES the existing row (host, title, …) instead of creating a
# new course and stranding its enrollments.
# Admin creds default to env ADMIN_EMAIL/ADMIN_PASSWORD or the seeded dev admin.
# (HTTP-only — talks to the platform API, so no kubeconfig is needed here.)
set -euo pipefail

# Inherit the active deployment (env ELEARN_DEPLOYMENT > .elearn-deployment) so the
# catalog entry uses the same BASE_DOMAIN / portal URL the platform runs under.
# This skill lives in ~/.claude, outside the repo: resolve the repo from the
# working directory (or ELEARN_REPO_ROOT), never from the script's own location.
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${ELEARN_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -d "$ROOT/elearn-platform" ] || { echo "ERROR: not inside the mydocs-plog-nextra repo (cd there or set ELEARN_REPO_ROOT)" >&2; exit 2; }
source "$ROOT/elearn-platform/scripts/deployment.sh"
apply_deployment || true
BASE_DOMAIN="$(resolve_base_domain)"

SLUG="${1:?slug required}"; shift
TITLE="${1:?title required}"; shift
# Optional positional host (skip if the next arg is a flag); default <slug>.<domain>.
HOST=""
if [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; then HOST="$1"; shift; fi
HOST="${HOST:-$SLUG.$BASE_DOMAIN}"

IMAGE=""
DESCRIPTION=""
GROUP_KEY=""
CATALOG_SLUG=""
STATUS="PUBLISHED"
# Portal API over HTTPS (the ingress terminates TLS and force-redirects http→https).
PLATFORM_URL="${PLATFORM_URL:-https://$BASE_DOMAIN}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@$BASE_DOMAIN}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-changeme123}"

while [ $# -gt 0 ]; do
  case "$1" in
    --image) IMAGE="$2"; shift 2;;
    --description) DESCRIPTION="$2"; shift 2;;
    --group) GROUP_KEY="$2"; shift 2;;
    --course-slug) CATALOG_SLUG="$2"; shift 2;;
    --status) STATUS="$2"; shift 2;;
    --platform-url) PLATFORM_URL="$2"; shift 2;;
    --admin-email) ADMIN_EMAIL="$2"; shift 2;;
    --admin-password) ADMIN_PASSWORD="$2"; shift 2;;
    *) echo "unknown flag: $1" >&2; exit 2;;
  esac
done

# The catalog slug: --course-slug override, else the domain-qualified course id.
COURSE_ID="${CATALOG_SLUG:-$(course_id "$BASE_DOMAIN" "$SLUG")}"

JAR="$(mktemp)"
trap 'rm -f "$JAR"' EXIT

# Accept the platform's self-signed wildcard cert (override CURL_TLS='' to enforce).
CURL_TLS="${CURL_TLS:--k}"

echo "==> Logging in to $PLATFORM_URL as $ADMIN_EMAIL"
login_code=$(curl -s $CURL_TLS -o /dev/null -w '%{http_code}' -c "$JAR" \
  -H 'Content-Type: application/json' \
  -X POST "$PLATFORM_URL/api/auth/login" \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}")
[ "$login_code" = "200" ] || { echo "ERROR: admin login failed (HTTP $login_code)" >&2; exit 1; }

# Description: --description, else the course's package.json "description".
if [ -z "$DESCRIPTION" ]; then
  PKG="$ROOT/sites/elearn-$(course_id "$BASE_DOMAIN" "$SLUG")/package.json"
  [ -f "$PKG" ] && DESCRIPTION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("description",""))' "$PKG")"
fi
# Group: resolve a CourseGroup key to its id through the admin API.
GROUP_ID=""
if [ -n "$GROUP_KEY" ]; then
  GROUP_ID=$(curl -s $CURL_TLS -b "$JAR" "$PLATFORM_URL/api/admin/course-groups" \
    | python3 -c 'import json,sys; k=sys.argv[1]; g=[x for x in json.load(sys.stdin).get("groups",[]) if x.get("key")==k]; print(g[0]["id"] if g else "")' "$GROUP_KEY")
  [ -n "$GROUP_ID" ] || { echo "ERROR: no CourseGroup with key '$GROUP_KEY'" >&2; exit 1; }
fi

# Build the JSON body with python3 so quotes/newlines in the description are
# escaped, and so an EMPTY description / group is omitted rather than sent.
BODY=$(python3 - "$COURSE_ID" "$TITLE" "$HOST" "$IMAGE" "$DESCRIPTION" "$STATUS" "$GROUP_ID" <<'PY'
import json, sys
slug, title, host, image, desc, status, gid = sys.argv[1:8]
b = {"slug": slug, "title": title, "host": host, "image": image or None, "status": status}
if desc.strip(): b["description"] = desc.strip()
if gid: b["groupId"] = int(gid)
print(json.dumps(b))
PY
)

echo "==> Registering course '$COURSE_ID' (host=$HOST status=$STATUS)"
resp=$(curl -s $CURL_TLS -b "$JAR" -H 'Content-Type: application/json' \
  -X POST "$PLATFORM_URL/api/admin/courses" -d "$BODY" -w '\n%{http_code}')
code="${resp##*$'\n'}"
echo "${resp%$'\n'*}"
[ "$code" = "200" ] || { echo "ERROR: registration failed (HTTP $code)" >&2; exit 1; }
echo "Registered $COURSE_ID in the catalog (host $HOST)."

# A course's FIRST deploy.sh runs before it is registered, so its page
# inventory + search index uploads 404'd and were skipped (best-effort). Now
# that the catalog row exists, publish both — this is what makes a brand-new
# course searchable from aimo (the "elearn" MCP server) without a second
# deploy. Best-effort on the same terms: a failed upload never un-registers.
for up in upload-course-pages.sh upload-course-search.sh; do
  if [ -x "$ROOT/scripts/$up" ]; then
    echo "==> $up --course $COURSE_ID"
    "$ROOT/scripts/$up" --course "$COURSE_ID" \
      || echo "warn: $up did not complete — re-run: scripts/$up -c $COURSE_ID" >&2
  fi
done
