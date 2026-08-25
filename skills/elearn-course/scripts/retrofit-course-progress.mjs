#!/usr/bin/env node
// Sync the learner-progress feature from the course template into courses.
//
//   retrofit-course-progress.mjs <course-id|dir> [...]   one or more courses
//   retrofit-course-progress.mjs --all                   every eligible course
//   retrofit-course-progress.mjs --all --dry-run
//
// What it copies (the template is always the source of truth — never edit a
// course's copy, exactly as with proxy.js / ProgressTracker.jsx):
//
//   app/api/progress/route.js        + GET, forwarding to the platform's
//                                      self-scoped /api/me/progress/<slug>
//   components/CourseProgress.jsx    the home-page "you are 12 of 21 pages in,
//                                      continue where you left off" block
//   components/RecentlyVisited.jsx   now platform-first (localStorage fallback)
//   components/QuizAttempts.jsx      now platform-first (localStorage fallback)
//   messages/{en,tr}.json            the courseProgress namespace + one string
//   mdx-components.js                registers <CourseProgress />
//   content/index.mdx                inserts <CourseProgress /> under the H1
//
// Eligibility — a course is SKIPPED unless it has `i18n/` and `messages/en.json`.
// The eight pre-i18n courses (elearn-elearn-local-ccaf, elearn-intro-k8s, the five
// elearn-morten-local-*, elearn-mp1-local-ccaf) would crash on `useTranslations`,
// and they run against platforms that predate `/api/me/progress` anyway. They need
// a full template sync first — a much bigger change than this one.
//
// Idempotent: re-running copies the same bytes and leaves `content/index.mdx`
// alone (the insertion is marker-guarded). Safe to run again after a template fix.

import { readFile, writeFile, copyFile, readdir, access } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { join, resolve, basename, dirname } from 'node:path'

// The skill lives in ~/.claude, outside the repo: resolve the repo from cwd
// (or ELEARN_REPO_ROOT), never from this script's own location.
const REPO = resolve(process.env.ELEARN_REPO_ROOT || process.cwd())
const SITES = join(REPO, 'sites')
const TEMPLATE = join(SITES, 'elearn-course-template')
if (!fs.existsSync(TEMPLATE)) {
  console.error('ERROR: not inside the mydocs-plog-nextra repo (cd there or set ELEARN_REPO_ROOT)')
  process.exit(2)
}

// Courses this script must not touch on an --all run. Empty since 2026-08-18:
// the collab-automation exclusion ended when that course's authoring finished
// and it was synced (naming a course explicitly always overrides this list).
const SKIP_ON_ALL = new Set()

// `isNew` files are created by this retrofit and so are legitimately absent from
// a course. Everything else MUST already exist: its absence means the course does
// not have the shape this change assumes (a pre-i18n tree, a hand-modified
// course), and copying into it would be a guess. That distinction is the whole
// reason this is a list of objects rather than of paths.
const COPY_FILES = [
  { rel: 'app/api/progress/route.js' },
  { rel: 'components/CourseProgress.jsx', isNew: true },
  { rel: 'components/RecentlyVisited.jsx' },
  { rel: 'components/QuizAttempts.jsx' },
  { rel: 'messages/en.json' },
  { rel: 'messages/tr.json' },
  { rel: 'mdx-components.js' },
]

const MARKER_START = '{/* course-progress:start — <CourseProgress /> reads the learner\'s own record from the platform */}'
const MARKER_END = '{/* course-progress:end */}'

const dry = process.argv.includes('--dry-run')
const all = process.argv.includes('--all')
const args = process.argv.slice(2).filter((a) => !a.startsWith('--'))

const courseId = (dir) => basename(dir).replace(/^elearn-/, '')

async function eligibleCourses() {
  const entries = await readdir(SITES, { withFileTypes: true })
  const out = []
  for (const e of entries) {
    if (!e.isDirectory()) continue
    if (e.name === 'elearn-course-template') continue
    const dir = join(SITES, e.name)
    if (!existsSync(join(dir, 'package.json'))) continue
    if (!existsSync(join(dir, 'proxy.js'))) continue // not a course
    out.push(dir)
  }
  return out.sort()
}

function resolveDir(ref) {
  for (const c of [ref, join(SITES, ref), join(SITES, `elearn-${ref}`)]) {
    if (existsSync(c) && existsSync(join(c, 'package.json'))) return resolve(c)
  }
  return null
}

/** Why a course cannot take this change, or null when it can. */
function ineligible(dir) {
  if (!existsSync(join(dir, 'i18n'))) return 'pre-i18n (no i18n/) — needs a full template sync first'
  if (!existsSync(join(dir, 'messages', 'en.json'))) return 'pre-i18n (no messages/en.json)'
  if (!existsSync(join(dir, 'content', 'index.mdx'))) {
    return existsSync(join(dir, 'content', 'index.md'))
      ? 'home page is .md — rename to .mdx first (JSX does not render in .md)'
      : 'no content/index.mdx'
  }
  return null
}

/**
 * Insert <CourseProgress /> directly under the home page's H1.
 *
 * Under the H1 rather than lower down because a learner coming back looks at the
 * top of the page; a first-time learner sees nothing at all, since the component
 * renders null until there is progress to report.
 */
function insertIntoHome(src) {
  if (src.includes('course-progress:start')) return { text: src, changed: false, reason: 'already present' }
  const lines = src.split('\n')
  const h1 = lines.findIndex((l) => /^# /.test(l))
  if (h1 === -1) return { text: src, changed: false, reason: 'no H1 to anchor to' }
  const block = ['', MARKER_START, '', '<CourseProgress />', '', MARKER_END]
  lines.splice(h1 + 1, 0, ...block)
  return { text: lines.join('\n'), changed: true }
}

async function retrofit(dir) {
  const id = courseId(dir)
  const why = ineligible(dir)
  if (why) return { id, status: 'skip', detail: why }

  const copied = []
  for (const { rel, isNew } of COPY_FILES) {
    const from = join(TEMPLATE, rel)
    const to = join(dir, rel)
    if (!existsSync(from)) return { id, status: 'fail', detail: `template missing ${rel}` }
    if (!existsSync(to) && !isNew) {
      return { id, status: 'fail', detail: `course missing ${rel} (unexpected shape)` }
    }
    const a = await readFile(from, 'utf8')
    const b = existsSync(to) ? await readFile(to, 'utf8') : null
    if (a !== b) {
      if (!dry) await copyFile(from, to)
      copied.push(rel)
    }
  }

  const homePath = join(dir, 'content', 'index.mdx')
  const home = await readFile(homePath, 'utf8')
  const { text, changed, reason } = insertIntoHome(home)
  if (changed && !dry) await writeFile(homePath, text, 'utf8')

  const bits = []
  if (copied.length) bits.push(`${copied.length} file${copied.length === 1 ? '' : 's'}`)
  if (changed) bits.push('home page')
  else if (reason && reason !== 'already present') bits.push(`home page NOT updated: ${reason}`)
  return {
    id,
    status: bits.length ? 'ok' : 'nochange',
    detail: bits.length ? bits.join(' + ') : 'already in sync',
  }
}

async function main() {
  if (!all && args.length === 0) {
    console.error('usage: retrofit-course-progress.mjs <course-id|dir> [...] | --all [--dry-run]')
    process.exit(2)
  }

  let dirs = []
  if (all) {
    dirs = (await eligibleCourses()).filter((d) => !SKIP_ON_ALL.has(courseId(d)))
  } else {
    for (const ref of args) {
      const d = resolveDir(ref)
      if (!d) {
        console.error(`error: no course matches '${ref}'`)
        process.exit(1)
      }
      dirs.push(d)
    }
  }

  const results = []
  for (const d of dirs) results.push(await retrofit(d))

  const w = Math.max(...results.map((r) => r.id.length), 10)
  for (const r of results) {
    const tag = { ok: 'ok   ', skip: 'skip ', fail: 'FAIL ', nochange: '=    ' }[r.status]
    console.log(`  ${tag} ${r.id.padEnd(w)}  ${r.detail}`)
  }
  const count = (s) => results.filter((r) => r.status === s).length
  console.log(
    `\n  updated ${count('ok')}   in-sync ${count('nochange')}   skipped ${count('skip')}   failed ${count('fail')}` +
      (dry ? '   (dry run — nothing written)' : ''),
  )
  if (all) {
    for (const id of SKIP_ON_ALL) console.log(`  note: '${id}' is on the --all skip list; name it explicitly to sync it`)
  }
  process.exit(count('fail') ? 1 : 0)
}

main().catch((err) => {
  console.error(`error: ${err.message}`)
  process.exit(1)
})
