---
name: aimo-webui-upgrade
description: Plan and execute an Open WebUI version upgrade for the aimo deployment (namespace aimo on the GPU Pool platform cluster) — evaluate a new release's notes and file diff against the platform's integration touchpoints, decide safe or not, back up, bump the pinned image tag, re-run the PersistentConfig reconcilers and the MCP tool-server sync, verify the six global filters and the signed identity JWT, and roll back if needed. Use when the user asks to "upgrade aimo", "upgrade Open WebUI", "bump the open-webui image tag", "is Open WebUI vX.Y.Z safe to upgrade", "check Open WebUI release notes against our codebase", or wants an aimo image change verified or rolled back.
---

# aimo-webui-upgrade

aimo is Entra-authenticated Open WebUI (namespace `aimo`, NodePort 30900,
`https://aimo.morten.com.tr`) in front of the GPU Pool gateway, deployed from
`deploy/aimo-webui/` in the platform repo (`ai-resource-sched`). Upgrading it is
**never just an image bump**: the deployment carries six SQL-installed global
filter functions, three shell reconcilers that own PersistentConfig rows, an MCP
tool-server mirror, raw-SQL admin scripts, a signed identity-JWT contract with
the control plane, and a rag-admin app driving the admin REST API — all of them
assumptions about Open WebUI *internals* that a new version can silently break.
The image tag is pinned for exactly this reason.

Work from the platform repo root. Cluster commands target the `.31` cluster —
set `KUBECONFIG` per the repo root `CLAUDE.md` "Common commands" section; the
repo's `scripts/*.sh` helpers refuse to run against the wrong cluster.

## Phase 0 — scope the release (before touching anything)

1. Read the target release's notes AND the real file diff:
   - `https://github.com/open-webui/open-webui/releases/tag/<tag>`
   - `https://api.github.com/repos/open-webui/open-webui/compare/<current>...<target>`
     (the `files` array caps at 300 entries — check `total_commits` and note truncation)
   - New DB migrations: any added files under
     `backend/open_webui/migrations/versions/`. **Open WebUI migrations are
     forward-only in practice** (downgrades are often `pass`); every migration
     in the diff makes the pre-upgrade backup the ONLY rollback path.
2. Cross-check every change against `references/integration-touchpoints.md`
   (the register of everything aimo assumes about Open WebUI internals, with
   the upstream file each assumption lives in). A change is relevant iff it
   touches a file named in the register.
3. For each intersection, **verify at source, don't trust the release note**:
   fetch `https://raw.githubusercontent.com/open-webui/open-webui/<tag>/<path>`
   and the same path at the current tag, diff, and quote the decisive lines.
   Most feared breaks refute in minutes this way; the ones that don't become
   pre-flight checks or upgrade-plan steps.
4. Check the env/PersistentConfig registry diff (`backend/open_webui/config.py`
   at both tags): renamed or removed keys break the reconcilers even when the
   app behaves. New keys are decisions, not breaks.
5. Write the verdict + risk register into a dated assessment file next to this
   skill (see `references/v0.11.1-assessment.md` for the worked example and
   format). A completed assessment for the target version means Phase 0 is
   already done — read it and continue.

## Phase 1 — pre-flight (read-only)

```sh
# current image actually running
kubectl -n aimo get deploy aimo-webui -o jsonpath='{.spec.template.spec.containers[0].image}'
# alembic head — must match the assessment's expected pre-upgrade revision
scripts/pg-psql.sh webui -c "select version_num from alembic_version"
# the six filters present, enabled, global
scripts/pg-psql.sh webui -c "select id, is_active, is_global from function order by id"
# load-bearing PersistentConfig rows in place
scripts/pg-psql.sh webui -c "select key from config where key in ('oauth.blocked_groups','web.search.enable','code_execution.engine','rag.template') order by key"
```

Plus any version-specific pre-flight the assessment prescribes (for v0.11.1:
the oauth-column shape check and the tag-based interpreter usage count).

## Phase 2 — backup (mandatory, not optional)

```sh
backup/backup.sh        # from the platform repo root; produces backups/<stamp>.tar.gz
```

Record the archive name in the deploy note. It captures the full `webui`
pg_dump (users, chats, the six filter rows, the config table, groups/knowledge/
grants, pgvector embeddings) and the data-PVC tar — together the only way back
once a schema migration has run, because the old image refuses to boot on a
newer `alembic_version`.

## Phase 3 — bump and roll

1. Edit `deploy/aimo-webui/deployment.yaml`: change the image tag. Keep the pin
   comment accurate (it names the identity-JWT contract as the reason for the
   pin and the date it was last re-verified — update both).
2. Apply and watch (single replica + `Recreate` = a brief outage window; the
   startupProbe budget is 10 min for a cold embedding-model download):

```sh
kubectl -n aimo apply -f deploy/aimo-webui/deployment.yaml
kubectl -n aimo rollout status deploy/aimo-webui --timeout=600s
scripts/k-logs.sh webui --since 10m       # migration lines + level=warn|error tail
scripts/pg-psql.sh webui -c "select version_num from alembic_version"   # new head
curl -s https://aimo.morten.com.tr/health
```

## Phase 4 — re-assert owned state

Open WebUI persists admin config in the DB and the DB wins over env, so a new
image can resurrect nothing by itself — but every upgrade re-runs the owners:

```sh
deploy/aimo-webui/reconcile-rag-config.sh        # rag.* + oauth group rows
deploy/aimo-webui/reconcile-code-exec-config.sh  # code_execution.* / code_interpreter.*
deploy/aimo-webui/reconcile-web-search-config.sh # web.* rows (search ships disabled without it)
deploy/aimo-webui/sync-mcp-tool-servers.sh       # mirror the MCP registry into tool_server.connections
```

Then re-check the six filters are still `is_active=t, is_global=t` (Phase 1
query) — they are DB rows and ride the upgrade, but a migration touching the
`function` table would be visible here first.

## Phase 5 — verification checklist (live, per integration surface)

Run each; the touchpoint register names the silent-failure signature of each.

1. **Identity JWT**: one chat as a signed-in Entra user, then
   `scripts/dash-session.sh check /usage --expect "<that user's email>"` — the
   per-user row proves the control plane verified `X-OpenWebUI-User-Jwt`.
2. **Gateway path**: `scripts/gw-probe.sh all` (health, models incl. aimo-help
   and prefixed ids, chat, stream).
3. **Model picker as a NON-admin**: must not be empty (the
   `BYPASS_MODEL_ACCESS_CONTROL` trap).
4. **Code interpreter**: one turn that computes and writes a file; the reply's
   download link must actually download (not a dead data URL), and the stored
   message must hold a stored-file note rather than an inline payload.
5. **Web search**: one searched turn returns results (SearXNG `format=json` +
   limiter-off contract; "No search results found" on every query is the
   break signature).
6. **MCP tools**: as a non-admin, the tools picker lists registry servers and
   one tool call round-trips.
7. **Notes**: type a paragraph, wait a few seconds, reopen — content persists;
   `scripts/k-logs.sh webui --all | grep -i queuepool` stays empty.
8. **RAG**: upload one document in chat (extraction non-empty) and run one
   rag-admin reconcile cycle against a scratch collection.
9. **Notifications/BYOK filters**: trigger one toast (e.g. a per-user 429) or
   check the pod log shows the filters polling without errors.
10. **OAuth groups**: sign out, sign back in, and confirm `rag-<slug>` group
    memberships survived the login sync (blocked-groups strip exemption).
11. **Logs**: `scripts/k-logs.sh webui --since 15m` — match `level=warn|error`,
    never the bare substring "error".

## Phase 6 — rollback

- **No migration ran** (alembic head unchanged): revert the tag in
  `deployment.yaml`, `kubectl -n aimo apply`, done.
- **Migrations ran**: revert the tag AND restore the DB from the Phase-2
  archive — replay `aimo/webui.sql` into `aimo-postgres`
  (`kubectl -n aimo exec -i deploy/aimo-postgres -- psql -q -U postgres -d webui`
  with the dump on stdin; it is `--clean --if-exists`), re-untar
  `webui-data.tgz` over `/app/backend/data`, then
  `kubectl -n aimo rollout restart deploy/aimo-webui`. `backup/restore.sh` is
  the drill-tested end-to-end path. Note the restore signs the window's chats
  back to the backup point — say so in the announcement.
- The replacement postgres image must stay pgvector-capable once vector tables
  exist.

## Phase 7 — record

1. Update `deploy/aimo-webui/CLAUDE.md`: the pinned-tag text, the identity-JWT
   "last re-verified" line (tag + date + what the diff showed), and a deploy
   note (date, new tag, backup archive name, rollback target).
2. Update the deployment.yaml pin comment likewise.
3. Run the repo's `/sync-docs` flow and commit.
4. If the upgrade added a stateful surface (new PVC/Secret/datastore), run the
   repo's `/backup-sync` skill.

## Files

- `references/integration-touchpoints.md` — the register of every assumption
  aimo makes about Open WebUI internals (assumption → upstream file → breakage
  signal). Phase 0 diffs the release against THIS. Keep it current: when a
  filter/reconciler/endpoint is added or changed in `deploy/aimo-webui/`, add
  or amend its row.
- `references/v0.11.1-assessment.md` — the worked v0.11.0 → v0.11.1 assessment
  (2026-08-26): verdict, verified risk register, version-specific pre-flight
  and decisions. The template for every future release check.
