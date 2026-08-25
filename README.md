# moskills

A skill library, published as a plain GitHub repo so the **skills service**
(`ai-resource-sched/deploy-skills`) can tap it and mirror skills into the
on-site library.

Nothing here is fetched by consumers. The dashboard's Hub pulls a skill from
this repo *once*, screens it, and commits it to the service's own PVC; every
consumer is served from there afterwards. This repo is the source, not the
runtime.

## Tapping it

In the dashboard's **Hub** panel, enter `bbmorten/moskills` under *Add tap*,
then search and install. Or, from an agent with the skills MCP server:

```
hub_taps(action="add", repo="bbmorten/moskills")
hub_search(query="elearn")
hub_install(identifier="bbmorten/moskills/skills/elearn-course")
```

The repo must stay **public**. The service reaches only `api.github.com` and
`raw.githubusercontent.com`, and the cluster has no `skills-secrets`/`GITHUB_TOKEN`
today — a private repo would 404 at index time.

## The one rule that shapes everything here

Built-in taps (anthropics, openai, huggingface, NVIDIA) install at trust
`trusted`, where a *caution* finding is tolerated. **Every tap added by hand,
including this one, installs at trust `community`, where ANY finding blocks the
install** — caution and dangerous are equally fatal.

So the bar for a skill in this repo is not "nothing malicious". It is *zero
findings from a regex scanner*, which is a bar you can trip by writing
``cat .env`` in a README. Run the validator before you push:

```sh
node tools/validate.mjs            # every skill
node tools/validate.mjs new-sandbox
```

It vendors the service's actual scanner (`tools/guard.mjs`), so a pass here is
the verdict the server will reach.

## Layout

```
skills/<name>/SKILL.md          required — the skill itself
skills/<name>/scripts/          executable helpers
skills/<name>/references/       docs the skill reads on demand
skills/<name>/templates/        files the skill copies out
skills/<name>/assets/           images, fonts, binaries it ships
tools/validate.mjs              pre-push contract check
tools/guard.mjs                 vendored scanner (do not edit)
tools/sync-guard.sh             refresh the vendored scanner
tools/templates/SKILL.md.example  starting point for a new skill
```

The support directory names are convention, not a filter — the installer keeps
whatever a skill ships, at any path that passes validation.

## Adding a skill

1. `mkdir -p skills/<name>` and write `SKILL.md` with `name:` and
   `description:` frontmatter. `name:` must be kebab-case and is what the skill
   installs as; `description:` is what tells an agent when to load it, so make
   it trigger-rich.
2. Add support files under the skill directory.
3. `node tools/validate.mjs <name>` — fix anything it reports.
4. Commit and push. The tap picks it up within the hub's 1-hour index TTL, or
   immediately with a refresh search.

## Things that will bite you

- **Any directory anywhere in this repo containing a `SKILL.md` is published as
  a skill** — the indexer keys on the path suffix, not on `skills/`. That is why
  the template is `SKILL.md.example`. The validator walks the whole repo, so it
  will show you a stray one.
- **Hidden files are silently dropped**, not rejected: `.DS_Store`,
  `.github/`, any segment starting with a dot. The validator lists them as
  `dropped on install` so a skill that depends on one does not arrive broken.
- **Compiled artifacts are a hard block** — `.pyc`, `.so`, `.exe`, `.jar` and
  friends are `dangerous` at any trust level. Keep `__pycache__` out (it is
  gitignored here).
- **Documentation trips the scanner.** Real findings this repo has already hit,
  all of them prose rather than code: a sentence containing the literal path to
  a kubeconfig under `$HOME`, and README lines that read a `.env` file. Reword
  rather than argue with it — the scanner is regex, and at community trust
  there is no override.
- **Caps**: 200 files and 8 MB per skill, 2 MB per file, 8 path segments deep.

## Keeping the scanner in step

`tools/guard.mjs` is a verbatim copy of the service image's `guard.mjs`. If the
service's rules change, refresh it:

```sh
tools/sync-guard.sh
```

and re-run the validator — a rule added upstream can block a skill that passed
last month.
