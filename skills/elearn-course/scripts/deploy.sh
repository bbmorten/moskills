#!/usr/bin/env bash
# Build a course image, load it into the target cluster, and apply its manifests.
#
# Usage:
#   deploy.sh <slug> "<Title>" [--kind-cluster NAME] [--registry REG]
#             [--context CTX] [--kubeconfig FILE] [--namespace NS]
#             [--platform-public-url URL] [--course-slug SLUG] [--note TEXT]
#
# <slug> is the BARE slug (e.g. ccaf); the domain-qualified course id
# (<domain-label>-<slug>) is derived for the directory, image, and k8s names.
# --kubeconfig points kubectl at a specific config (e.g. the standalone one
# create-platform-k8s.sh writes for a real cluster, never merged into ~/.kube).
# --course-slug overrides the CATALOG slug baked into the image as
# NEXT_PUBLIC_COURSE_SLUG (defaults to the course-id). Use it for a legacy course
# whose catalog slug must stay decoupled from its renamed course-id so existing
# enrollments survive — e.g. elearn-local-ccaf's catalog slug stays `ccaf`. The
# SERVER COURSE_SLUG comes from k8s/deployment.yaml, so pin it there to match.
#
# Phase 1 (default): kind — `kind load docker-image`.
# Phase 2: pass --registry to docker push instead.
#
# Videos: a course with public/assets/videos/ has them rsync'd to the deployment's
# media host before the build and routed there by a media Ingress after the
# rollout (see "Course media" below). MEDIA_SYNC=0 skips the rsync for a
# content-only roll; MEDIA_EMBED=1 is the rollback mode (videos in the image,
# media Ingress removed).
set -euo pipefail

# This skill lives in ~/.claude, outside the repo: resolve the repo from the
# working directory (or ELEARN_REPO_ROOT), never from the script's own location.
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${ELEARN_REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -d "$ROOT/elearn-platform" ] || { echo "ERROR: not inside the mydocs-plog-nextra repo (cd there or set ELEARN_REPO_ROOT)" >&2; exit 2; }

# Inherit the active deployment (env ELEARN_DEPLOYMENT > .elearn-deployment) so the
# course gets the same BASE_DOMAIN and cluster targeting (context / kubeconfig /
# registry / kind cluster) the platform was created with. Explicit flags below
# still win. With no deployment selected this is legacy single-domain behavior.
source "$ROOT/elearn-platform/scripts/deployment.sh"
apply_deployment || true
BASE_DOMAIN="$(resolve_base_domain)"

SLUG="${1:?slug required}"; shift
TITLE="${1:?title required}"; shift

KIND_CLUSTER=""
REGISTRY="${REGISTRY:-}"          # may be pre-set by the deployment profile (k8s)
CONTEXT=""
KUBECONFIG_FILE=""
CATALOG_SLUG=""                   # catalog slug for NEXT_PUBLIC_COURSE_SLUG; defaults to course-id below
NAMESPACE="${NAMESPACE:-elearn}"  # may be pre-set by the deployment profile
NOTE=""                           # free-text note recorded in the course's release history
# Browser-facing platform origin baked into the course image (NEXT_PUBLIC_PLATFORM_URL:
# CSP connect-src + the ProgressTracker/quiz beacons). HTTPS so a course served over
# https://<slug>.<domain> doesn't get its beacons blocked as mixed content. The
# in-cluster server-side authz call still uses the plain-HTTP Service (PLATFORM_URL).
PLATFORM_PUBLIC_URL="https://$BASE_DOMAIN"
# Cluster nodes are linux/amd64. Pin the target platform so an arm64 build host
# (Apple Silicon) doesn't push an unpullable arm64 image. --provenance=false keeps
# the push a single-arch manifest instead of a manifest list with attestations.
BUILD_PLATFORM="${BUILD_PLATFORM:-linux/amd64}"

while [ $# -gt 0 ]; do
  case "$1" in
    --kind-cluster) KIND_CLUSTER="$2"; shift 2;;
    --registry) REGISTRY="$2"; shift 2;;
    --context) CONTEXT="$2"; shift 2;;
    --kubeconfig) KUBECONFIG_FILE="$2"; shift 2;;
    --course-slug) CATALOG_SLUG="$2"; shift 2;;
    --namespace) NAMESPACE="$2"; shift 2;;
    --platform-public-url) PLATFORM_PUBLIC_URL="$2"; shift 2;;
    --note) NOTE="$2"; shift 2;;
    *) echo "unknown flag: $1" >&2; exit 2;;
  esac
done

# Fill cluster targeting from the active deployment profile when flags were omitted.
# (Profile exports CTX_NAME / KUBECONFIG_OUT / CLUSTER_NAME / CLUSTER_TYPE; REGISTRY
# was preserved above.) Explicit --flags above always take precedence.
if [ -n "${DEPLOYMENT_NAME:-}" ]; then
  case "${CLUSTER_TYPE:-}" in
    k8s)
      [ -n "$CONTEXT" ]         || CONTEXT="${CTX_NAME:-}"
      [ -n "$KUBECONFIG_FILE" ] || KUBECONFIG_FILE="${KUBECONFIG_OUT:-$ROOT/elearn-platform/.kube/${CTX_NAME}.config}"
      ;;
    kind)
      [ -n "$KIND_CLUSTER" ]    || KIND_CLUSTER="${CLUSTER_NAME:-}"
      [ -n "$CONTEXT" ]         || CONTEXT="kind-${CLUSTER_NAME:-}"
      ;;
  esac
fi

# Domain-qualified identity; the directory/image/k8s names all use it.
COURSE_ID="$(course_id "$BASE_DOMAIN" "$SLUG")"
# Catalog slug baked into the image (NEXT_PUBLIC_COURSE_SLUG). Defaults to the
# course-id (the convention); --course-slug decouples it for legacy courses.
CATALOG_SLUG="${CATALOG_SLUG:-$COURSE_ID}"
DIR="$ROOT/sites/elearn-$COURSE_ID"
[ -d "$DIR" ] || { echo "ERROR: $DIR not found — run scaffold first" >&2; exit 1; }
# kubectl flags: optional standalone kubeconfig + optional context.
KFLAGS=(); [ -n "$KUBECONFIG_FILE" ] && KFLAGS=(--kubeconfig "$KUBECONFIG_FILE")
[ -n "$CONTEXT" ] && KFLAGS+=(--context "$CONTEXT")

if [ -n "$REGISTRY" ]; then
  IMAGE="$REGISTRY/elearn-$COURSE_ID:latest"
else
  IMAGE="elearn-$COURSE_ID:dev"
fi

# --- Page dates + release history -------------------------------------------
# Both are baked into the image, and neither can be computed inside the build
# (.dockerignore excludes .git), so they are refreshed here on the host first.
if [ -f "$DIR/scripts/gen-page-timestamps.mjs" ]; then
  echo "==> Refreshing page created/updated dates from git"
  node "$DIR/scripts/gen-page-timestamps.mjs"
fi

HISTORY_RECORDED=0
REC="$SKILL_DIR/scripts/record-deploy.mjs"
# A failed build/rollout must not leave a release in the history — drop the
# entry again on any error before the rollout is confirmed.
rollback_history() { if [ "$HISTORY_RECORDED" = 1 ]; then node "$REC" rollback "$DIR" || true; fi; }
trap rollback_history ERR

if [ -f "$DIR/data/deploy-history.json" ] || [ -f "$DIR/content/history.mdx" ]; then
  node "$REC" add "$DIR" \
    --image "$IMAGE" \
    --commit "$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '')" \
    --deployment "${DEPLOYMENT_NAME:-}" \
    --namespace "$NAMESPACE" \
    --host "$SLUG.$BASE_DOMAIN" \
    --course-id "$COURSE_ID" \
    --slug "$CATALOG_SLUG" \
    --note "$NOTE"
  HISTORY_RECORDED=1
fi

# --- Course media (videos) ---------------------------------------------------
# Videos are NOT in the image: .dockerignore excludes public/assets/videos, and
# they are served by the deployment's media host (ai-resource-sched/
# deploy-151-media/) on the same URL, routed by a per-course media Ingress and
# gated by the platform session. So for a course that ships videos:
#   1. sync them to the media host BEFORE the build (a failed sync must not
#      produce a rollout whose videos 404);
#   2. render the media Ingress and server-dry-run it (the admission webhook
#      rejects a bad annotation now rather than after a 5-minute build);
#   3. after the rollout, apply the bridge Service + the media Ingress.
# Env knobs (env, not flags — roll-courses.sh passes the environment through):
#   MEDIA_SYNC=0    skip the rsync (content-only roll; videos already on the host)
#   MEDIA_EMBED=1   the ROLLBACK mode: build the OLD way with the videos in the
#                   image (a temp .dockerignore without the videos line is swapped
#                   in for the build), skip the sync, and DELETE the course's
#                   media Ingress after the rollout so the pod serves its own
#                   videos again. The shared .dockerignore set is never edited.
MEDIA_TPL="$SKILL_DIR/k8s/media-ingress.yaml.tmpl"
MEDIA_BRIDGE="$SKILL_DIR/k8s/media-bridge.yaml"
HAS_MEDIA=0
[ -n "$(find "$DIR/public/assets/videos" -type f -print -quit 2>/dev/null)" ] && HAS_MEDIA=1
MEDIA_TMP=""
if [ "$HAS_MEDIA" = 1 ] && [ "${MEDIA_EMBED:-0}" != 1 ]; then
  if [ -z "${MEDIA_SSH_HOST:-}" ]; then
    echo "ERROR: $COURSE_ID ships videos but deployment profile '${DEPLOYMENT_NAME:-(none)}' has no MEDIA_SSH_HOST." >&2
    echo "       The image no longer carries video. Add the media host to the profile, or MEDIA_EMBED=1 to embed." >&2
    exit 1
  fi
  if ! kubectl "${KFLAGS[@]}" -n elearn-media get svc elearn-media >/dev/null 2>&1; then
    echo "ERROR: media host not deployed on this cluster (svc elearn-media in ns elearn-media missing)." >&2
    echo "       Run ai-resource-sched/deploy-151-media/deploy.sh apply first." >&2
    exit 1
  fi
  if [ "${MEDIA_SYNC:-1}" != 0 ]; then
    echo "==> Syncing videos to the media host ($MEDIA_SSH_HOST)"
    "$ROOT/scripts/sync-media.sh" -d "$DEPLOYMENT_NAME" --course "$COURSE_ID"
  else
    echo "==> MEDIA_SYNC=0: not syncing videos (host copy assumed current)"
  fi
  MEDIA_TMP="$(mktemp)"
  perl -pe "
    s/\{\{COURSE_ID\}\}/$COURSE_ID/g;
    s/\{\{HOST\}\}/$SLUG.$BASE_DOMAIN/g;
    s/\{\{CATALOG_SLUG\}\}/$CATALOG_SLUG/g;
    s/\{\{BASE_DOMAIN\}\}/$BASE_DOMAIN/g;
    s/\{\{NAMESPACE\}\}/$NAMESPACE/g;
  " "$MEDIA_TPL" > "$MEDIA_TMP"
  echo "==> Validating the media Ingress (server dry-run)"
  kubectl "${KFLAGS[@]}" -n "$NAMESPACE" apply --dry-run=server -f "$MEDIA_TMP" >/dev/null
fi

# MEDIA_EMBED=1: build with the videos INSIDE the image. Docker only reads the
# .dockerignore at the context root, so the course's copy is swapped for a
# filtered one during the build and restored by the trap whatever happens.
DOCKERIGNORE_BAK=""
restore_dockerignore() { if [ -n "$DOCKERIGNORE_BAK" ]; then mv -f "$DOCKERIGNORE_BAK" "$DIR/.dockerignore"; DOCKERIGNORE_BAK=""; fi; }
if [ "$HAS_MEDIA" = 1 ] && [ "${MEDIA_EMBED:-0}" = 1 ]; then
  echo "==> MEDIA_EMBED=1: building with videos embedded in the image (rollback mode)"
  DOCKERIGNORE_BAK="$(mktemp)"
  cp "$DIR/.dockerignore" "$DOCKERIGNORE_BAK"
  grep -v '^public/assets/videos$' "$DOCKERIGNORE_BAK" > "$DIR/.dockerignore"
  trap 'restore_dockerignore; rollback_history' ERR
  trap restore_dockerignore EXIT
fi

echo "==> Building $IMAGE (course-id $COURSE_ID, platform $BUILD_PLATFORM)"
docker build \
  --platform "$BUILD_PLATFORM" \
  --provenance=false \
  --build-arg "NEXT_PUBLIC_PLATFORM_URL=$PLATFORM_PUBLIC_URL" \
  --build-arg "NEXT_PUBLIC_COURSE_SLUG=$CATALOG_SLUG" \
  --build-arg "NEXT_PUBLIC_COURSE_TITLE=$TITLE" \
  -t "$IMAGE" "$DIR"
restore_dockerignore

if [ -n "$REGISTRY" ]; then
  # The ~200MB app layer regularly trips "net/http: timeout awaiting response
  # headers": the client stops waiting while the in-cluster registry is still
  # committing the blob. The registry finishes anyway, so the next attempt sees
  # "Layer already exists" and completes in seconds — retrying IS the fix. A
  # single-attempt push fails often enough that a 27-course roll almost always
  # loses one to it (observed 2026-08-12 on llmfund, mid-fleet-roll), and it
  # looks alarmingly like a broken registry. Same loop as
  # elearn-platform/scripts/update-platform-k8s.sh.
  echo "==> Pushing $IMAGE"
  PUSH_OK=0
  # Back off long enough for that commit to FINISH. Measured 2026-08-21 on a
  # 315MB app layer: the registry returned 201 after 2m14s, while the client had
  # given up at ~34s. The old flat `sleep 3` fired all five attempts inside
  # 2.5min, so every one re-uploaded 315MB on top of a commit still in flight —
  # the commits got progressively SLOWER (2m14s, 3m41s, 3m51s) and the push
  # failed outright. Waiting is what makes the retry work.
  _delays="30 75 150 240"
  for _attempt in 1 2 3 4 5; do
    if docker push "$IMAGE"; then PUSH_OK=1; break; fi
    [ "$_attempt" -lt 5 ] || break   # last attempt failed; don't sleep, just report
    _sleep=$(echo "$_delays" | cut -d' ' -f"$_attempt")
    [ -n "$_sleep" ] || _sleep=240
    echo "    push attempt $_attempt failed (client gave up; registry may still be" >&2
    echo "    committing the blob). Waiting ${_sleep}s for it to finish, then retrying…" >&2
    sleep "$_sleep"
  done
  if [ "$PUSH_OK" != "1" ]; then
    echo "ERROR: push to '$REGISTRY' failed after 5 attempts." >&2
    echo "       If EVERY attempt failed at the very first layer, the registry is" >&2
    echo "       insecure (HTTP) and the Docker daemon needs:" >&2
    echo "         \"insecure-registries\": [\"$REGISTRY\"]" >&2
    exit 1
  fi
else
  : "${KIND_CLUSTER:?--kind-cluster required when --registry is not set}"
  echo "==> Loading $IMAGE into kind cluster '$KIND_CLUSTER'"
  kind load docker-image "$IMAGE" --name "$KIND_CLUSTER"
fi

# Make sure the manifest references the image we built/pushed.
TMP="$(mktemp)"
perl -pe "s{image: elearn-$COURSE_ID:dev}{image: $IMAGE}g" "$DIR/k8s/deployment.yaml" > "$TMP"

echo "==> Applying manifests to namespace '$NAMESPACE'"
kubectl "${KFLAGS[@]}" -n "$NAMESPACE" apply -f "$TMP"
rm -f "$TMP"

# Force a new pod even when the image tag is unchanged (e.g. rebuilt :dev). The
# freshly kind-loaded image only takes effect if the pods actually restart.
echo "==> Rolling pods to pick up the rebuilt image"
kubectl "${KFLAGS[@]}" -n "$NAMESPACE" rollout restart "deploy/elearn-$COURSE_ID"

echo "==> Waiting for rollout"
kubectl "${KFLAGS[@]}" -n "$NAMESPACE" rollout status "deploy/elearn-$COURSE_ID" --timeout=180s

# Rollout confirmed — the recorded release is real, so stop arming the rollback.
trap - ERR
if [ "$HISTORY_RECORDED" = 1 ]; then
  echo "Release recorded in sites/elearn-$COURSE_ID/data/deploy-history.json"
fi

# Route /assets/videos/ to the media host (or, under MEDIA_EMBED=1, back to the pod).
if [ "$HAS_MEDIA" = 1 ]; then
  if [ "${MEDIA_EMBED:-0}" = 1 ]; then
    echo "==> MEDIA_EMBED=1: removing the media Ingress so the pod serves /assets/videos/ itself"
    kubectl "${KFLAGS[@]}" -n "$NAMESPACE" delete ingress "elearn-$COURSE_ID-media" --ignore-not-found
  else
    echo "==> Routing /assets/videos/ to the media host"
    kubectl "${KFLAGS[@]}" -n "$NAMESPACE" apply -f "$MEDIA_BRIDGE"
    kubectl "${KFLAGS[@]}" -n "$NAMESPACE" apply -f "$MEDIA_TMP"
    rm -f "$MEDIA_TMP"
    # The gate must be closed: an UNAUTHENTICATED request for a real video must
    # bounce to the platform login (the authenticated 200/206 probe lives in
    # scripts/check-live.sh --media, which needs the course registered).
    # No `| head -1` here: with hundreds of video links grep fills the pipe
    # before head closes it, takes SIGPIPE, and pipefail turns that into exit
    # 141 (bit CCNAU, 674 media files; DCCOR's 264 fit the buffer by luck).
    first="$(grep -rhoE '\]\(/assets/videos/[^)]+\.mp4\)' "$DIR/content" 2>/dev/null || true)"
    first="${first%%$'\n'*}"; first="${first#](}"; first="${first%)}"
    if [ -n "$first" ]; then
      # ingress-nginx reloads a few seconds after the apply; the first request
      # can land on a half-built upstream (502 "connect() failed" — seen on the
      # very first media deploy). Retry briefly before calling it a failure.
      out=""
      for _i in 1 2 3 4 5 6; do
        out="$(curl -s -o /dev/null -m 20 -w '%{http_code} %{redirect_url}' "https://$SLUG.$BASE_DOMAIN$first" || true)"
        case "$out" in 30[0-9]\ *login*) break;; esac
        sleep 5
      done
      case "$out" in
        30[0-9]\ *login*) echo "    media gate OK: $out";;
        *) echo "ERROR: expected a login redirect for $first, got: $out" >&2
           echo "       Inspect: kubectl -n ingress-nginx exec deploy/ingress-nginx-controller -- nginx -T | grep -A30 '$SLUG.$BASE_DOMAIN'" >&2
           exit 1;;
      esac
    fi
  fi
fi

# Publish the course's table of contents to the platform, so the learner-facing
# "N of M pages" has a denominator only the course author can move, and "next up"
# knows the reading order. Best-effort on purpose: it needs the course to be
# REGISTERED in the catalog, and a first deploy runs before register.sh does. A
# skipped upload costs the course nothing — the platform falls back to the derived
# page total, exactly as it did before inventories existed — so this must never
# fail a rollout that has already succeeded.
UPLOAD="$ROOT/scripts/upload-course-pages.sh"
if [ -x "$UPLOAD" ]; then
  echo "==> Publishing page inventory to the platform"
  if ! "$UPLOAD" --course "$COURSE_ID"; then
    echo "warn: page inventory not published (course may not be registered yet)." >&2
    echo "      Re-run after register.sh:  scripts/upload-course-pages.sh -c $COURSE_ID" >&2
  fi
fi

# Publish the course's SEARCH INDEX (every lesson / quiz / knowledge check /
# video as text) to the platform, so the cross-course search behind aimo's
# "elearn" assistant sees this deploy's content. Same best-effort contract as
# the inventory above: needs the course registered, never fails the rollout.
SEARCH_UPLOAD="$ROOT/scripts/upload-course-search.sh"
if [ -x "$SEARCH_UPLOAD" ]; then
  echo "==> Publishing search index to the platform"
  if ! "$SEARCH_UPLOAD" --course "$COURSE_ID"; then
    echo "warn: search index not published (course may not be registered yet)." >&2
    echo "      Re-run after register.sh:  scripts/upload-course-search.sh -c $COURSE_ID" >&2
  fi
fi

echo "Deployed elearn-$COURSE_ID (image=$IMAGE)"
echo "IMAGE=$IMAGE"
echo "COURSE_ID=$COURSE_ID"
