#!/usr/bin/env bash
# Remove a course: delete it from the catalog (admin API), delete its k8s
# objects, and optionally remove the local image. Does NOT delete the local
# sites/elearn-<slug> source directory (the caller decides that).
#
# Usage:
#   teardown.sh <slug> [--context CTX] [--kubeconfig FILE] [--namespace NS]
#               [--platform-url URL] [--admin-email E] [--admin-password P]
#               [--kind-cluster NAME] [--rmi]
#
# <slug> is the BARE slug (e.g. ccaf); the domain-qualified course id
# (<domain-label>-<slug>) is derived for the catalog slug, k8s objects, directory,
# and image. --kubeconfig points kubectl at a specific config (e.g. the standalone
# one for a real cluster).
set -euo pipefail

# This skill lives in ~/.claude, outside the repo: resolve the repo from the
# working directory (or ELEARN_REPO_ROOT), never from the script's own location.
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${ELEARN_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -d "$ROOT/elearn-platform" ] || { echo "ERROR: not inside the mydocs-plog-nextra repo (cd there or set ELEARN_REPO_ROOT)" >&2; exit 2; }

# Inherit the active deployment (env ELEARN_DEPLOYMENT > .elearn-deployment) so the
# course is torn down on the same cluster / domain it was deployed to. Explicit
# flags below still win; with none selected this is legacy single-domain behavior.
source "$ROOT/elearn-platform/scripts/deployment.sh"
apply_deployment || true
BASE_DOMAIN="$(resolve_base_domain)"

SLUG="${1:?slug required}"; shift

CONTEXT=""
KUBECONFIG_FILE=""
NAMESPACE="${NAMESPACE:-elearn}"
# Portal API over HTTPS (the ingress terminates TLS and force-redirects http→https).
PLATFORM_URL="${PLATFORM_URL:-https://$BASE_DOMAIN}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@$BASE_DOMAIN}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-changeme123}"
RMI=0

while [ $# -gt 0 ]; do
  case "$1" in
    --context) CONTEXT="$2"; shift 2;;
    --kubeconfig) KUBECONFIG_FILE="$2"; shift 2;;
    --namespace) NAMESPACE="$2"; shift 2;;
    --platform-url) PLATFORM_URL="$2"; shift 2;;
    --admin-email) ADMIN_EMAIL="$2"; shift 2;;
    --admin-password) ADMIN_PASSWORD="$2"; shift 2;;
    --kind-cluster) shift 2;;  # accepted for symmetry; not needed to delete
    --rmi) RMI=1; shift;;
    *) echo "unknown flag: $1" >&2; exit 2;;
  esac
done

# Fill cluster targeting from the active deployment profile when flags were omitted.
if [ -n "${DEPLOYMENT_NAME:-}" ]; then
  case "${CLUSTER_TYPE:-}" in
    k8s)
      [ -n "$CONTEXT" ]         || CONTEXT="${CTX_NAME:-}"
      [ -n "$KUBECONFIG_FILE" ] || KUBECONFIG_FILE="${KUBECONFIG_OUT:-$ROOT/elearn-platform/.kube/${CTX_NAME}.config}"
      ;;
    kind)
      [ -n "$CONTEXT" ]         || CONTEXT="kind-${CLUSTER_NAME:-}"
      ;;
  esac
fi

# Domain-qualified identity.
COURSE_ID="$(course_id "$BASE_DOMAIN" "$SLUG")"
KFLAGS=(); [ -n "$KUBECONFIG_FILE" ] && KFLAGS=(--kubeconfig "$KUBECONFIG_FILE")
[ -n "$CONTEXT" ] && KFLAGS+=(--context "$CONTEXT")
DIR="$ROOT/sites/elearn-$COURSE_ID"

echo "==> Removing course '$COURSE_ID' from catalog"
# Accept the platform's self-signed wildcard cert (override CURL_TLS='' to enforce).
CURL_TLS="${CURL_TLS:--k}"
JAR="$(mktemp)"; trap 'rm -f "$JAR"' EXIT
curl -s $CURL_TLS -o /dev/null -c "$JAR" -H 'Content-Type: application/json' \
  -X POST "$PLATFORM_URL/api/auth/login" \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}" || true
curl -s $CURL_TLS -b "$JAR" -H 'Content-Type: application/json' \
  -X DELETE "$PLATFORM_URL/api/admin/courses" -d "{\"slug\":\"$COURSE_ID\"}" || true
echo

echo "==> Deleting k8s objects in namespace '$NAMESPACE'"
if [ -f "$DIR/k8s/deployment.yaml" ]; then
  kubectl "${KFLAGS[@]}" -n "$NAMESPACE" delete -f "$DIR/k8s/deployment.yaml" --ignore-not-found
else
  kubectl "${KFLAGS[@]}" -n "$NAMESPACE" delete deploy,svc,ingress -l "elearn/course=$COURSE_ID" --ignore-not-found
fi
# The media Ingress (created by deploy.sh for courses that ship videos) is not in
# the course manifest. The videos themselves stay on the media host on purpose —
# remove them deliberately with: scripts/sync-media.sh --purge --course <slug>
kubectl "${KFLAGS[@]}" -n "$NAMESPACE" delete ingress "elearn-$COURSE_ID-media" --ignore-not-found

if [ "$RMI" = "1" ]; then
  echo "==> Removing local image elearn-$COURSE_ID:dev"
  docker rmi "elearn-$COURSE_ID:dev" 2>/dev/null || true
fi

echo "Course '$COURSE_ID' torn down. Local source dir left intact: $DIR"
