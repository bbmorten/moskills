---
name: course-precontent
description: Turn raw source material — a syllabus PDF, markdown files, URLs, context7 lookups — into a sign-off-ready precontent pack for a new e-learning course, before /new-elearn-course runs. Produces a course brief (slug, title, ports, identity), a table of contents at least three levels deep, an instructor lab guide when the labs need real systems, a lab runtime spec when the course needs interactive code cells, and dated research notes. Use whenever the user wants a new course planned, scoped, or blueprinted from supplied material, mentions a TOC/outline/syllabus for a course, or asks what a course would contain before building it.
---

# Course precontent

`/new-elearn-course` scaffolds and deploys. It does not decide *what the course
is*. This skill produces that decision as a reviewable document set, so the
expensive part — generating 40+ lesson pages and several hundred quiz questions
— starts from an agreed plan rather than an improvised one.

**Output:** `course-blueprint/<slug>/` in the orchestrator root.

| File | Always? | Contents |
| --- | --- | --- |
| `00-course-brief.md` | yes | identity (slug, title, course-id, host, ports, profile), audience, design rules, differentiators, sizing, open decisions |
| `01-table-of-contents.md` | yes | Part → Chapter → Lesson → subtopics + per-lesson lab. **≥3 heading levels** |
| `02-instructor-lab-guide.md` | when labs need systems the learner may not have | environment inventory, fixture capture + sanitisation, per-part verification matrix, what the user must provide |
| `03-lab-runtime-spec.md` | when the course has interactive/executable cells | runtime, reachability, components, template changes, known limits |
| `04-research-notes.md` | yes | every currency claim with a date and a source |

**The skill stops before scaffolding.** It ends by presenting the pack and the
open decisions. Scaffolding happens only after the user confirms.

## Inputs

Free-form. Any mix of: PDF or markdown attached to the conversation or given as
a path, URLs to research, a product/technology to look up in context7, a
plain-English brief, an existing course to model against.

Useful flags if the user supplies them: `--slug`, `--title`, `--no-labs`,
`--core-only`, `--sources <paths/urls>`.

Missing slug or title is not a blocker — propose them (§3) and let the user
correct at sign-off.

---

## Workflow

### 1. Read every source completely

Attached documents, every path, every URL. Do not skim a syllabus and infer the
rest — the structure of the source is the contract with whoever supplied it.
Note where the source is thin: a syllabus bullet that names a whole product
family is a chapter, not a lesson, and that expansion is yours to justify.

### 2. Currency research — and verify, do not recall

For every product, platform, exam code, version number and API named in the
source:

- **context7 first** (`resolve-library-id` → `query-docs`) for library, SDK and
  platform documentation. It is current where training data is not.
- **Web search + fetch** for changelogs, release notes, end-of-life bulletins
  and certification changes.
- **Direct protocol checks** where a claim is testable — see §5.

Record everything in `04-research-notes.md` **with a date and a link**. A
version number without a date is a future bug.

> **Hard rule: never restate an exam code, version number, product name or
> support date from memory.** In the CLAUTO run this caught a supplied syllabus
> citing exam "300-800" when the real code was 300-835 *and had been retired
> six months earlier*. That single check changed the course title, added an
> intro note and re-weighted a whole part. Assume every syllabus you are handed
> has at least one such fact in it.

When research contradicts the supplied source, **do not silently correct it**.
Put it in the brief as a decision with options and a recommendation — the user
may be selling the course under the name on the PDF, which is their call.

### 3. Identity

- **Slug** — bare kebab-case, no exam numbers or version digits (they expire).
- **Title** — what the catalog shows. If the source's title carries a code or a
  version, raise it as a decision rather than choosing unilaterally.
- **Ports** — `scripts/course-inventory.sh --next-port`. Never guess, never
  "next number"; 3960–3982 is fully allocated and 3983–3986 are taken.
- **Course id / directory / host** — derive from the deployment profile's
  `DOMAIN_LABEL` and `BASE_DOMAIN`; see the elearn-course skill. State them
  explicitly so the user can spot a collision before it exists.
- **Catalog group** — suggest one; flag if the course warrants a new group.

### 4. Design the table of contents

**Three levels minimum**, four in practice: Part → Chapter → Lesson →
subtopics. One lesson = one `.mdx` page = one `_meta.ts` row.

Per lesson: 3–6 subtopic bullets and **a named lab or exercise**. A lesson with
no exercise is a lesson nobody remembers.

Tag every lesson so the plan is auditable at a glance:

| Tag | Meaning |
| --- | --- |
| ◇ | vendor-neutral — names no vendor, transfers elsewhere |
| ★ | differentiator — carries a *"why this is hard to match"* section |
| `[core]` / `[ext]` | which lessons survive a trim |
| track / lab type | what the learner needs to run it |

**When the user asks for vendor-neutral fundamentals plus vendor strengths,
build it structurally, not with disclaimers:** the general pattern gets its own
lesson *before* the vendor implementation appears (SOAP/WSDL before AXL; OAuth
flows before Webex tokens). Then each differentiator claim is tied to a lab that
demonstrates it — a claim an engineer can check is worth ten that they cannot.

**Balance it with an honest weakness section.** A course that only praises loses
the room. Name where the vendor is behind, in the same chapter that says where
they are ahead.

**Quarantine currency.** Version numbers, EoL dates and release specifics go in
one chapter plus one appendix, so the rest does not rot. Give that appendix its
own "keeping this page current" checklist.

Close with the assessment plan: 10 questions per lesson plus a 30–40 question
final, stable `quizId`s, decision-shaped questions rather than recall, and the
answer-bias target (≤30% longest-key, even answer spread, corrected by
lengthening distractors — never by trimming keys).

### 5. Lab feasibility — test it, do not assume it

The step that saves the most rework. Before promising any lab:

```bash
~/.claude/skills/course-precontent/scripts/api-reachability.sh https://api.example.com/v1/thing
```

It runs a CORS preflight and a simple request and tells you whether a
browser-based cell can reach that API at all. Then check, concretely:

- **CSP.** The course template ships `connect-src 'self' ${PLATFORM}`. Any
  external host a cell calls must be added, or the call fails with an opaque
  error that is invisible in a Python traceback. Check
  `sites/elearn-course-template/next.config.mjs` and list the required edits.
- **Runtime package availability.** For Pyodide, read `pyodide-lock.json` and
  confirm each library the labs need is actually in the distribution. Report the
  Python version and the missing packages, and decide per-lab what happens
  without them.
- **Private/on-prem systems are unreachable from a browser, permanently** — no
  CORS, private addressing, self-signed certs. Do not design around it; design
  *for* it.

When labs need systems the learner will not have, use the **two-track model**:

> Track A runs in the browser against recorded fixtures and any CORS-enabled
> cloud API, using **the learner's own credentials**. Track B runs the same
> notebook locally against real systems. **The learner's code is byte-identical
> in both** — only the transport underneath differs. Every lab shows a banner
> saying which it is and what the data source is, so nobody is ever misled about
> what is real.

If the course has executable cells, write `03-lab-runtime-spec.md`: the runtime
and its verified version, what is reachable, the components to build, the
template changes required, and the known limits stated up front.

**Secrets in browser cells** — the rules, every time:
`sessionStorage` never `localStorage`; namespaced per course slug; never
transmitted anywhere; output redaction of any stored value before render; a
visible statement of what the course can see; a clear-all control.

### 6. Instructor lab guide

Write `02-instructor-lab-guide.md` whenever validating or recording labs needs
access you do not have. It must be handable to whoever owns the lab **without
them reading anything else in the pack**, and must contain:

1. **What is already verified**, with evidence — separate from what is assumed.
2. **Environment inventory in tiers**: free/no-lab, needed-once-for-capture,
   optional-for-realism. Name concrete sources (vendor sandbox, trial org, own
   gear) and versions.
3. **The capture procedure** and the sanitisation rules — credentials removed
   not redacted, hosts and IPs rewritten into documentation ranges, names and
   identifiers replaced consistently, **and a human reading every artefact
   before commit**. Automation catches the classes it knows; a person catches a
   customer name in a description field.
4. **A per-part verification matrix** — what must be true before those labs are
   finished, and which are blocked on the user.
5. **Open technical questions**, each as a verification task with a decision
   rule and a fallback, so nothing gets written from an assumption.
6. **What you need from the user**, ranked by how much it unblocks, and what you
   can do unattended starting now.

Always state the no-lab fallback and its honest cost. Schema-derived fixtures
are structurally correct but encode what the docs say rather than what the
product does — usable, but marked `unverified` in the manifest *and* in the
learner-facing banner.

### 7. Write the pack

To `course-blueprint/<slug>/`. Working documents: tables over prose, every
number justified, every open question owned by a named party. Size the course
honestly — count the lessons you actually laid out rather than the number you
guessed earlier — and offer a concrete trim (the `[core]` cut) with the saving.

### 8. Present and stop

Report: proposed slug/title/ports, the shape (parts/chapters/lessons/labs/
questions), the differentiators and how each is proven, **the decisions you need**
(each with a recommendation), what is blocked and on whom, and what you can start
immediately.

**Do not scaffold. Do not run `/new-elearn-course`.** Wait for confirmation.

---

## Hard-won rules

- **Verify, don't recall** — exam codes, versions, EoL dates, API shapes. The
  supplied source is a claim, not a fact.
- **Check the CSP before promising a browser lab.** This one is silent: the cell
  runs, the request fails, and the Python traceback says nothing useful.
- **Check runtime package availability** before designing a lab around a
  library.
- **`--next-port`, never a guess.**
- **Every differentiator claim needs a lab.** Otherwise it is marketing in a
  course, which engineers detect immediately and forgive slowly.
- **Every course that praises must also admit.** Put the weaknesses in the same
  chapter.
- **Destructive operations are fixture-only.** A learner must not be able to
  damage a real system by following the course.
- **Count before you claim.** Lay out the lessons, then count them; do not write
  a total in the brief and design to it afterwards.
- **Name what is blocked and on whom**, and start the unblocked half now.

## Related

- `~/.claude/skills/elearn-course/` — scaffold, deploy, register, tear down. Runs
  *after* this.
- `.claude/skills/mermaid-diagram/` — diagram authoring and the browser audit
  (catches over-wide diagrams and `;`-in-`sequenceDiagram` errors that build
  cleanly and only fail in the browser).
- `scripts/quiz-answer-bias.py` — the longest-answer-is-the-key audit.
- `scripts/course-inventory.sh` — ports, hosts, drift.
- Reference pack: `course-blueprint/collab-automation/` (Cisco Collaboration
  automation, August 2026) — the run this skill was extracted from.
