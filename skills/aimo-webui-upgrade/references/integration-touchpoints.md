# aimo ↔ Open WebUI integration touchpoints

The register of everything the aimo deployment assumes about Open WebUI
**internals**. A version upgrade is checked by intersecting the upstream file
diff with the "upstream" column below; a release note is only trusted after the
named file has been read at both tags. Built 2026-08-26 against v0.11.0 from a
complete read of `deploy/aimo-webui/` (CLAUDE.md, deployment.yaml, all six
`functions/*.py`, the three `reconcile-*.sh`, `sync-mcp-tool-servers.sh`,
`provision-service-key.sh`, `load-knowledge.sh`, the companion yamls) plus
`apps/rag-admin/lib/webui.ts` — all paths relative to the platform repo.

Legend: **upstream** = the Open WebUI backend file(s) implementing the
assumption (all under `backend/open_webui/`); **breaks as** = how a violation
presents (most surfaces fail SILENTLY by design — the filters swallow errors).

## Identity (the reason the tag is pinned)

| assumption | upstream | breaks as |
|---|---|---|
| With `ENABLE_FORWARD_USER_INFO_HEADERS` + `FORWARD_USER_INFO_HEADER_JWT_SECRET`, one HS256 JWT per upstream request, payload exactly `{sub,email,name,role,iss:'open-webui',iat,exp}`, header `X-OpenWebUI-User-Jwt`, 300s expiry. Control plane verifies with the paired secret. | `utils/headers.py`, `env.py` | Every chat loses per-user identity: per-user limits, BYOK, notifications stop resolving; with `AUTH_REQUIRED=true`, WebUI traffic denied |
| Plain `X-OpenWebUI-User-*` header fallback exists (trusted only against the service key id when no JWT secret) | `utils/headers.py` | Fallback attribution lost or spoofable |
| The two identity filters + `sync-mcp-tool-servers.sh` SELF-MINT the same JWT from container env (PyJWT + `requests` bundled in the image; `OPENAI_API_KEY`/base-URL/JWT-secret readable via os.environ) | dependency set + `config.py` wiring | BYOK sync and toasts silently stop (log-and-swallow) |

## PersistentConfig (DB wins over env)

| assumption | upstream | breaks as |
|---|---|---|
| Flat `config` table (key text PK, value json, updated_at); a present row OVERRIDES env on boot; reconcilers upsert with raw SQL | `config.py` (PersistentConfig) | Env edits "don't take"; reconcile SQL writes keys nothing reads |
| `reconcile-code-exec-config.sh` owns the 12 `code_execution.*` / `code_interpreter.*` keys; engine value `jupyter` valid | `config.py` + `routers/configs.py` | Execution silently reverts to Pyodide ("Python doesn't work") |
| `reconcile-web-search-config.sh` owns the 10 `web.search.*`/`web.loader.*`/`web.fetch.*` keys; first boot writes the subtree with search DISABLED, so the script IS the ship mechanism | `config.py` | Web Search toggle absent despite correct env |
| `reconcile-rag-config.sh` owns `rag.*` + `oauth.{enable_group_mapping,enable_group_creation,group_claim,blocked_groups,provider_url}`; `oauth.blocked_groups` stored as a JSON array | `config.py` | RAG/group env shadowed forever by stale rows |
| `DEFAULT_LOCALE` is a bare env read, NOT PersistentConfig (the `ui.default_locale` row is inert) | `config.py` + `/api/config` | tr-TR first-visit default silently stops applying |

## OAuth / Entra

| assumption | upstream | breaks as |
|---|---|---|
| `OAUTH_ALLOWED_DOMAINS` checks the OIDC email claim in the callback | `utils/oauth.py` | Out-of-domain sign-ins, or legit domains rejected |
| Group sync on EVERY login adds AND removes per the `roles` claim; pre-created groups adopted by name | `utils/oauth.py` (update_user_groups) | Knowledge RBAC drifts on next sign-in |
| `is_in_blocked_groups` (exact/glob/regex) exempts `rag-*` groups from the REMOVE half — load-bearing for rag-admin's hand-managed reader groups | `utils/oauth.py` | Every mapped doc-RAG user loses collection access at next login |
| Redirect URI derived per request when unset; the `oauth.microsoft.redirect_uri` config row must stay empty | OAuth login flow + proxy headers | Entra redirect mismatch on one of the two entry paths |
| First sign-in becomes admin; `DEFAULT_USER_ROLE=user` avoids upstream's pending-approval default | `routers/auths.py` | New users stranded pending, or duplicate accounts |
| `OPENID_PROVIDER_URL` discovery drives sign-out via end_session_endpoint | `config.py` + logout route | Entra SSO session survives sign-out |

## Model picker

| assumption | upstream | breaks as |
|---|---|---|
| `BYPASS_MODEL_ACCESS_CONTROL=true` disables webui-side model ACLs; without it, connection-synced models with no `model` row are admin-only | `utils/models.py` | Non-admins get an EMPTY picker |
| Picker cached app-wide under the ONE service key; per-user gating is at gateway dispatch; chats pin model ids against webui's own list | `routers/openai.py` (get_all_models) | Users see undispatachable models; old chats stuck on stale ids |
| `meta.capabilities.code_interpreter` absent-hides the toggle, `web_search` defaults TRUE when unset — opposite traps | `utils/models.py` (get_model_capability) | One model loses the interpreter toggle, or all lose search |

## The six global filters (SQL-installed rows in the `function` table)

| assumption | upstream | breaks as |
|---|---|---|
| Filter plugin contract: `Filter` class, `Valves`/`UserValves` pydantic models, sync-or-async `inlet`/`outlet`, by-signature-name injection (`__user__` with `valves` attr-object, `__event_emitter__` awaitable), `priority` valve orders ascending | `utils/plugin.py`, `utils/filter.py`, `models/functions.py` | All six silently no-op |
| aimo_notifications: `{"type":"notification","data":{...}}` emitter event renders a toast; polls the control plane notifications feed, acks after emit | socket → frontend toast handling | Toasts stop; feed re-serves forever |
| anthropic_key_filter: `UserValves` surface under user Settings is the BYOK entry UI; syncs to the control plane key endpoint | `models/functions.py` valves storage | Users can't set keys; claude falls back to the cluster key |
| chart_guidance: string-appendable system message in `body["messages"]`; encodes kernel-per-execution, inline plt, printed data-URL convention | `utils/code_interpreter.py` + frontend Mermaid | Guidance turns wrong; models regress to NameError patterns |
| full_context_uploads: chat-upload items shaped `{type:'file', id, file:{data:{content}}}`; setting `context:'full'` injects the whole document via get_sources_from_items (which re-checks access itself) | `retrieval/utils.py`, `utils/middleware.py` | Whole-file asks regress to the view_file paging loop → gateway timeouts |
| spreadsheet_extract_fallback: docling-empty leaves the file row with empty content; filter re-extracts in-pod via `Files.get_file_by_id` / `update_file_data_by_id` / `check_access_by_user_id` + `Storage.get_file` (same PVC); priority runs BEFORE full_context_uploads | `models/files.py`, `storage/provider.py`, retrieval loaders | Strict-OOXML/.xls uploads regress to filename-only context |
| generated_file_downloads (outlet): message `output[]` blocks typed `message` / `function_call_output` (string OR parts list); BOTH `content` and `output` surfaces rewritten; stores via `Storage.upload_file` + `Files.insert_new_file(FileForm)` with `data={}` (keeps the file out of RAG); link `/api/v1/files/<id>/content?attachment=true` is cookie-authed, owner-scoped, attachment-disposition | outlet pipeline in `utils/middleware.py`, `models/files.py`, `routers/files.py` | Download links dead again, or inline payloads replayed to the model each turn |

## Admin REST + raw SQL surfaces

| assumption | upstream | breaks as |
|---|---|---|
| In-pod `open_webui.utils.auth.create_token({'id':...})` mints an admin session token; admin found by raw SQL over the `user` table (id/email/name/role/created_at) | `utils/auth.py`, `models/users.py` | sync-mcp + load-knowledge fail at auth |
| `GET/POST /api/v1/configs/tool_servers` round-trips `TOOL_SERVER_CONNECTIONS`; connection shape `{url, path, type:'mcp', auth_type:'bearer', key, config:{enable, access_grants}, info:{id,...}}`; entity id `server:mcp:<info.id>` — `info.id` load-bearing; empty `access_grants` list = admins-only | `routers/configs.py`, `utils/tools.py`, `utils/middleware.py` | Registry servers vanish, or tools list but calls fail / non-admins lose tools |
| Chat-time tool-server calls carry only the connection's bearer key (no per-user identity) | `utils/tools.py` HTTP client | requireUser servers start/stop working unexpectedly |
| `sk-` API key resolves to the full admin user (needs `auth.enable_api_keys`, which SHIPS false) | `utils/auth.py` (api-key branch) | Every rag-admin call 401/403s |
| rag-admin + load-knowledge endpoint contract: `users/all` (unpaginated), `groups/` (bare array), group create/delete/users add-remove (POST-as-read on members), `knowledge/?page=` (`{items,total}`), knowledge create/access-update (grants REPLACE; empty = admins-only), `<id>/files?page=`, file add/remove, `files/?process=true&process_in_background=false`, DELETE files/<id>, the "Duplicate content detected" detail string | `routers/{users,groups,knowledge,files}.py` | Reconciler drift; re-runs re-upload corpora; orphan file rows |

## RAG / ingest / vector

| assumption | upstream | breaks as |
|---|---|---|
| `CONTENT_EXTRACTION_ENGINE=docling` posts to the docling service `/v1/convert/file` with `DOCLING_PARAMS` merged as form fields; NO client timeout (docling's 540s sync budget governs); any docling error stores the file with EMPTY content | retrieval loaders (DoclingLoader) | Uploads store empty content; knowledge attach rejects EMPTY_CONTENT |
| `VECTOR_DB=pgvector` embeds into the same DB; app runs CREATE EXTENSION itself; postgres image must stay pgvector-capable | `retrieval/vector/dbs/pgvector.py` | Knowledge queries error while other tables work |
| In-pod sentence-transformers engine; ~1.1GB model cache under the data PVC; 10-min startupProbe budget for the cold download | retrieval embedding path | Cold boot killed mid-download; bulk uploads crawl |
| Upload processing is background by default; background tasks die with the process (an OOMKill strands `pending` uploads); `?process_in_background=false` forces inline | `routers/files.py` | Files stuck pending after restarts |
| `RAG_TEMPLATE` = upstream default + the AIMO-RAG-CONTEXT-v1 marker as FIRST line; every injection path (knowledge, full-context uploads, web-search results) carries it; the gateway's OPA egress rule keys on it | `utils/middleware.py` + template application | Documents egressable externally, or search 403s on external models when OPA is on |

## Web search

| assumption | upstream | breaks as |
|---|---|---|
| Legacy forced-RAG search gated on `function_calling == 'legacy'` (never taken here); live path = builtin tools search_web/fetch_url; capability + permission + per-chat gates | `utils/middleware.py`, `tools/builtin.py` | Users flip onto the other pipeline: different costs/context shapes |
| SearXNG client requests `format=json` with a bot UA — SearXNG must keep json in `search.formats` and `server.limiter` false | `retrieval/web/searxng.py` | "No search results found" on every query, both pods healthy |
| `WEB_FETCH_MAX_CONTENT_LENGTH` bounds one fetch_url call | web retrieval utils | Unbounded fetches blow context/quota |

## Code execution / Notes / infra

| assumption | upstream | breaks as |
|---|---|---|
| JupyterCodeExecuter creates + deletes a kernel PER execution (basis of the workspace-isolation startup hack and the chart-guidance stateless rules); token auth | `utils/code_interpreter.py` | Isolation silently stops, or every Run fails at auth |
| Note content persists ONLY via the collaboration socket update handler; the REST autosave never carries typed text; pool sizing (`DATABASE_POOL_SIZE`/overflow) prevents QueuePool exhaustion during typing | `socket/main.py`, `internal/db.py` | Notes reopen empty with zero visible errors |
| `GET /health` on :8080 unauthenticated (all three probes); cold boot downloads the embedding model BEFORE health serves | `main.py` | Crashloop on rollout |
| `WEBUI_SECRET_KEY` signs both the browser token cookie (file download links auth off it) and in-pod create_token | `utils/auth.py` | Rotation signs everyone out and breaks in-pod scripts |
| Alembic migrations run automatically on boot against `DATABASE_URL`; effectively forward-only — rollback is old image + DB restore | `internal/db.py` + migrations | Old image refuses to boot on a newer alembic head |
| `/v1`, `/api/identity`, `/api/mcp` on the aimo host are control-plane carve-outs; Open WebUI must not claim those prefixes on its origin | route namespace | Wrong app answers on the shared host |
| Companion pods: searxng/jupyter need `enableServiceLinks:false` (service-link env clobbers port parsing); docling-serve stays 1 uvicorn worker per replica, replicas are the throughput lever | companion images | Crashloops on port parse; Task-Not-Found errors |

## Gateway-side compensations for observed client behavior

Not upstream files, but premises that a frontend change can invalidate —
re-check the release notes for chat-flow rewrites:

- Composer hard-locks on an errored assistant reply → every gateway failure is
  converted to a 200 assistant message for WebUI identities.
- The whole history is re-sent every turn → policy redaction + image-history
  recovery exist.
- Regenerate inside an errored chat sends an EMPTY messages array → the
  400-before-dispatch guard.
- Open WebUI sends NO max_tokens → the gateway's per-upstream default output
  caps. If a version starts sending one, the client value would WIN — re-verify
  `utils/payload.py` / `routers/openai.py` payload assembly on every bump.
