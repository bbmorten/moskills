---
name: elearn-course
description: Helper scripts that scaffold, build, deploy, register and tear down a single course on the e-learning platform (elearn-platform) — domain-qualified course ids, k8s manifests, catalog registration, media bridge, and progress/timestamp retrofits. The /new-elearn-course and /manage-elearn-course commands orchestrate these; invoke the commands rather than the scripts directly. Use when creating, deploying, updating, re-registering or removing an e-learn course, or when debugging a course that is built but missing from the catalog.
---

# elearn-course

Helper scripts that create, deploy, register, and tear down a course on the
e-learning platform (`elearn-platform`). The `/new-elearn-course` and
`/manage-elearn-course` commands orchestrate these; you normally invoke the
commands, not the scripts directly.

## Domain-qualified course identity

All scripts take the **bare slug** (e.g. `ccaf`) and derive a **domain-qualified
course id** = `<domain-label>-<slug>` from the persisted `BASE_DOMAIN`
(`domain_label` in `scripts/domain.sh`; `morten.local` → `morten-local` →
`morten-local-ccaf`). The course id is used for the directory
(`sites/elearn-<course-id>`), k8s resource names, image, and **catalog slug** (so
the pod's `COURSE_SLUG` matches the registered slug and enrollment checks line up).
The public **host stays clean**: `<slug>.<base-domain>` (e.g. `ccaf.morten.local`).
This lets the same logical course be deployed under several base domains without
colliding in the monorepo or the cluster.

## Scripts (`scripts/`)

- `scaffold.sh <slug> "<Title>" [flags]` — clone `sites/elearn-course-template`
  into `sites/elearn-<course-id>`, render `Tiltfile`/`k8s/deployment.yaml` from the
  `.tmpl` files (`{{SLUG}}`→course-id, `{{HOST}}`→clean host), and set the package
  name + dev port. Also starts the course's release history empty and generates
  its page dates. Prints `COURSE_ID=` and `HOST=`.
- `deploy.sh <slug> "<Title>" [flags]` — refresh the page dates from git and
  record the release (see "Dates and history" below), `docker build` (passing the
  `NEXT_PUBLIC_*` build args, `NEXT_PUBLIC_COURSE_SLUG`=course-id), then `kind load`
  (default) or `docker push` (`--registry`), then `kubectl apply` + `rollout status`.
  `--note "<text>"` annotates the release entry. Prints `IMAGE=` and `COURSE_ID=`.
  **Videos are not in the image**: for a course with `public/assets/videos/` it
  first runs `scripts/sync-media.sh` (rsync to the profile's `MEDIA_SSH_HOST`),
  server-dry-runs the rendered `k8s/media-ingress.yaml.tmpl`, and after the
  rollout applies `k8s/media-bridge.yaml` + that Ingress and checks that an
  unauthenticated video request bounces to login. `MEDIA_SYNC=0` skips the rsync;
  `MEDIA_EMBED=1` is the rollback (videos baked in, media Ingress deleted).
  The push is **retried up to 5 times** (3s apart): the ~200MB app layer regularly
  trips `net/http: timeout awaiting response headers` because the client stops
  waiting while the in-cluster registry is still committing the blob — the registry
  finishes anyway, so the retry sees `Layer already exists` and succeeds in seconds.
  A single-attempt push failed often enough to lose a course mid-fleet-roll. If
  *every* attempt fails at the very first layer, that is the different problem the
  error message names: the registry is insecure (HTTP) and the local Docker daemon
  needs it under `insecure-registries`. Same loop as
  `elearn-platform/scripts/update-platform-k8s.sh`.
- `register.sh <slug> "<Title>" [host] [flags]` — log in as admin and
  `POST /api/admin/courses` with slug=course-id, host defaulting to
  `<slug>.<base-domain>`. HTTP-only (no kubeconfig). `--description` falls back
  to the course `package.json` "description" and is OMITTED when empty (a
  re-registration must not blank the admin's text); `--group <CourseGroup key>`
  files the course (omitted = leave the filing alone).
- `teardown.sh <slug> [flags]` — `DELETE /api/admin/courses` (course-id), delete k8s
  objects (the media Ingress included), optionally `docker rmi`. Leaves the local
  source dir AND the media host's copy intact (`scripts/sync-media.sh --purge`).
- `k8s/media-bridge.yaml` + `k8s/media-ingress.yaml.tmpl` — the media routing
  `deploy.sh` applies for video courses (see the repo `CLAUDE.md` "Media host").
- `record-deploy.mjs <init|add|rollback|backfill> <course-dir> [flags]` — maintain
  `data/deploy-history.json`. Called by `scaffold.sh` (init) and `deploy.sh`
  (add before the build, rollback if it fails). `backfill --at <iso>` prepends
  the release an already-live course had before it was retrofitted, so its
  history page doesn't claim it first went live on retrofit day.
- `retrofit-timestamps.mjs <slug|dir>… | --all [--force] [--dry-run]` — add the
  page-dates / what's-new / history feature to courses scaffolded before it
  existed. Idempotent. Notes:
  - Skips courses that predate the i18n template (no `messages/` + `i18n/`) —
    the new components use `next-intl`, so those need a template sync first.
  - A `.md` home page is renamed to `.mdx` (`git mv`) so it can host
    `<RecentPages />` — Nextra parses `.md` as plain markdown, where JSX leaks
    through as literal text. A home page carrying raw `<tag`s or braces outside
    code is left alone with a warning instead (it would break the MDX build).
  - `mdx-components.js` / `page.jsx` are overwritten only when they still match
    the committed template, or were written by an earlier run of this script;
    anything else warns and needs `--force`.

## Dates and history (every course page)

Each page shows when it was created and last updated, the home page lists what
changed recently, and `content/history.mdx` shows the course's releases. Two
generated files feed this, both **baked into the image** because the Docker
build context excludes `.git`:

- `data/page-timestamps.json` — written by the course's own
  `scripts/gen-page-timestamps.mjs` from `git log` over `content/` (mtime for
  untracked/dirty pages; frontmatter `created:`/`updated:` override). Runs from
  npm `predev`/`prebuild` and from `deploy.sh` before `docker build`.
- `data/deploy-history.json` — appended by `record-deploy.mjs` from `deploy.sh`
  **before** the build (the pod can only describe a release that is already in
  its image); the entry is rolled back if the build or rollout fails.

Both files are committed with the course, so the git diff of a deploy shows
which pages moved and which release was cut.

All scripts derive the orchestrator root from their own location and accept
`--context`, `--namespace`, `--platform-url`, and admin-cred flags. The cluster
scripts (`deploy`, `teardown`) also accept **`--kubeconfig FILE`** to target a
specific config — e.g. the standalone kubeconfig `create-platform-k8s.sh` writes
for a real cluster (`elearn-platform/.kube/<ctx>.config`), which is never
merged into your default kubeconfig. Run `bash <script>` with no args to see positionals.

## Conventions

- slug is the bare kebab-case slug; the directory / k8s / image / catalog-slug are
  the domain-qualified course id `<domain-label>-<slug>`; the host is
  `<slug>.<base-domain>` (persisted `BASE_DOMAIN`, default `elearn.local`, via
  `scripts/domain.sh`). Image defaults to `elearn-<course-id>:dev` (or
  `<registry>/elearn-<course-id>:latest`).
- Course pods deploy into the **same namespace** as the platform so they can
  read the shared `elearn-secrets` Secret (`PLATFORM_JWT_SECRET`).
- Default ports for the first course: dev 3971, nodePort 30971, forward 8971.
  Bump these for additional courses to avoid collisions.
