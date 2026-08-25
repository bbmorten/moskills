# moskills — working notes for Claude

This repo is a **published skill library**, tapped by the skills service in
`ai-resource-sched/deploy-skills`. Read the README first; it explains the
consumption model. These are the rules that apply while editing here.

## Always validate before committing

```sh
node tools/validate.mjs           # or: node tools/validate.mjs <skill-name>
```

Exit 0 means every skill would install. **Do not commit a skill the validator
blocks** — the failure surfaces later as a refused install in the dashboard,
with the same findings but none of the context.

## Why the bar is "zero findings"

A tap added by hand installs at trust `community`. In that policy row both
`caution` and `dangerous` block; only `safe` installs. There is no override, no
allowlist, and no flag to force it. The only fix for a finding is to change the
content.

## Prose that trips the scanner

The scanner reads Markdown as readily as shell. Findings this repo has actually
hit came from documentation, not code:

- a literal `$HOME`-anchored path to a kubeconfig or cloud-credentials file,
  even in a sentence saying the file is *never* touched
- reading a dotfile of environment variables (`cat` plus that filename)
- `grep -r` for something spelled like a secret
- a base64-looking run of 512+ unbroken characters (an inlined blob or hash)
- zero-width characters, which arrive invisibly via copy-paste from a browser
- phrasing that reads as instructing an agent to disregard prior instructions,
  hide something from the user, or bypass an approval gate — quoting an attack
  in a security-focused skill still fires the rule

Reword. Do not try to defeat the regex; write the sentence a different way.

## Structural rules

- A skill is `skills/<name>/SKILL.md` plus support files. `name:` frontmatter
  must be kebab-case; it is the installed name, and the directory name is only
  the fallback.
- **Any** directory holding a `SKILL.md` is published as a skill, wherever it
  sits. The template is `SKILL.md.example` for exactly this reason.
- Hidden paths (any segment starting with `.`) are dropped from the install
  silently. A skill must not depend on one.
- Compiled artifacts (`.pyc`, `.so`, `.exe`, `.jar`, …) are `dangerous` at every
  trust level. `.gitignore` covers `__pycache__`; check before adding binaries.
- The executable bit that matters is the one in git, not the working tree.
  `chmod +x` only real scripts — an executable file with an extension the
  scanner cannot read is a finding.
- Caps: 200 files and 8 MB per skill, 2 MB per file, 8 path segments deep.

## Seeded skills came from ~/.claude/skills

`elearn-course`, `new-sandbox` and `course-precontent` were copied from the
local Claude skills directory and **edited to pass screening** — `elearn-course`
gained the frontmatter it never had and had one sentence reworded. The two
copies have diverged; when syncing changes in either direction, re-run the
validator rather than assuming a clean copy is still clean.

## Keeping the scanner honest

`tools/guard.mjs` is vendored verbatim from the service image. Never edit it —
a local edit makes the validator lie. Refresh with `tools/sync-guard.sh` and
re-run the validator when the service's rules change.
