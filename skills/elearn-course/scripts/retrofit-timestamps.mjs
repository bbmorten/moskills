#!/usr/bin/env node
/**
 * Add the page-timestamps / what's-new / course-history feature to a course
 * that was scaffolded before it existed. Idempotent: re-running only fills in
 * what is missing.
 *
 * Usage:
 *   retrofit-timestamps.mjs <slug-or-dir> [...]   # e.g. elearn-local-gpu-pool
 *   retrofit-timestamps.mjs --all                 # every course under sites/
 *   [--force]   overwrite locally-customised mdx-components.js / page.jsx
 *   [--dry-run] report what would change, write nothing
 *
 * What it does per course:
 *   1. copies components/{PageTimestamps,RecentPages,DeployHistory}.jsx,
 *      lib/pageTimestamps.js and scripts/gen-page-timestamps.mjs from the template
 *   2. replaces mdx-components.js + app/[[...mdxPath]]/page.jsx with the template's
 *      (skipped, with a warning, if the course customised them — see --force)
 *   3. adds the missing pageTimestamps/recentPages/deployHistory message keys to
 *      messages/*.json, never touching existing translations
 *   4. adds the gen:timestamps / predev / prebuild npm scripts
 *   5. creates content/history.mdx and an empty data/deploy-history.json
 *   6. inserts a "What's new" block into the course home page
 *   7. generates data/page-timestamps.json from git history
 *
 * Courses that predate the i18n template (no messages/ + i18n/) are skipped:
 * the new components use next-intl, so those need a full template sync first.
 */
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'

// The skill lives in ~/.claude, outside the repo: resolve the repo from cwd
// (or ELEARN_REPO_ROOT), never from this script's own location.
const ROOT = path.resolve(process.env.ELEARN_REPO_ROOT || process.cwd())
const SITES = path.join(ROOT, 'sites')
const TEMPLATE = path.join(SITES, 'elearn-course-template')
if (!fs.existsSync(TEMPLATE)) {
  console.error('ERROR: not inside the mydocs-plog-nextra repo (cd there or set ELEARN_REPO_ROOT)')
  process.exit(2)
}

const args = process.argv.slice(2)
const FORCE = args.includes('--force')
const DRY = args.includes('--dry-run')
const ALL = args.includes('--all')
const targets = args.filter((a) => !a.startsWith('--'))

// Files copied verbatim from the template.
const COPY_FILES = [
  'components/PageTimestamps.jsx',
  'components/RecentPages.jsx',
  'components/DeployHistory.jsx',
  'lib/pageTimestamps.js',
  'scripts/gen-page-timestamps.mjs',
]
// Files replaced wholesale — identical across every scaffolded course, but
// checked before clobbering: safe when the course still has the committed
// template version, or a version this script wrote earlier (`marker`).
const REPLACE_FILES = [
  { rel: 'mdx-components.js', marker: 'RecentPages' },
  { rel: 'app/[[...mdxPath]]/page.jsx', marker: 'PageTimestamps' },
]
const MESSAGE_KEYS = ['pageTimestamps', 'recentPages', 'deployHistory']

const WHATS_NEW = `{/* course-whats-new:start — <RecentPages /> is generated from git history; see scripts/gen-page-timestamps.mjs */}

## What's new

<RecentPages />

See the [course history](/history) for every release and the full page list.

{/* course-whats-new:end */}
`

const changes = []
const note = (course, msg) => changes.push(`  ${course}: ${msg}`)

/**
 * Constructs that make MDX choke on a file markdown accepts: a raw `<tag` (MDX
 * reads it as JSX) or a brace (MDX reads it as an expression). Fenced and
 * inline code are exempt — MDX leaves those alone too.
 */
function mdxHazards(text) {
  const out = []
  let fenced = false
  text.split('\n').forEach((line, i) => {
    if (/^\s*(```|~~~)/.test(line)) {
      fenced = !fenced
      return
    }
    if (fenced) return
    if (/<[A-Za-z/!]|[{}]/.test(line.replace(/`[^`]*`/g, ''))) {
      out.push({ line: i + 1, text: line.trim().slice(0, 70) })
    }
  })
  return out
}
const write = (file, content) => {
  if (DRY) return
  fs.mkdirSync(path.dirname(file), { recursive: true })
  fs.writeFileSync(file, content)
}

/** The template file as it is committed — what an un-customised course holds. */
function committedTemplate(rel) {
  try {
    return execFileSync('git', ['show', `HEAD:sites/elearn-course-template/${rel}`], {
      cwd: ROOT,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    })
  } catch {
    return null
  }
}

/** A gated course, not a plain docs site: only courses carry the tracker. */
const isCourse = (dir) =>
  fs.existsSync(path.join(dir, 'components/ProgressTracker.jsx')) && fs.existsSync(path.join(dir, 'content'))

function courseDirs() {
  if (ALL) {
    return fs
      .readdirSync(SITES)
      .filter((name) => name !== 'elearn-course-template')
      .map((name) => path.join(SITES, name))
      .filter(isCourse)
  }
  return targets.map((t) => {
    if (fs.existsSync(t) && fs.statSync(t).isDirectory()) return path.resolve(t)
    const asDir = path.join(SITES, t)
    if (fs.existsSync(asDir)) return asDir
    return path.join(SITES, `elearn-${t}`)
  })
}

function retrofit(dir) {
  const course = path.basename(dir)
  if (!isCourse(dir)) {
    note(course, 'SKIPPED — not an e-learn course (no components/ProgressTracker.jsx)')
    return
  }
  if (!fs.existsSync(path.join(dir, 'messages', 'en.json')) || !fs.existsSync(path.join(dir, 'i18n'))) {
    note(course, 'SKIPPED — predates the i18n template (no messages/ + i18n/); sync the template first')
    return
  }

  // 1. new files
  for (const rel of COPY_FILES) {
    const src = fs.readFileSync(path.join(TEMPLATE, rel), 'utf8')
    const dst = path.join(dir, rel)
    const existed = fs.existsSync(dst)
    if (existed && fs.readFileSync(dst, 'utf8') === src) continue
    write(dst, src)
    note(course, `${existed ? 'updated' : 'added'} ${rel}`)
  }

  // 2. wired-up files (only if untouched since scaffolding, or ours already)
  for (const { rel, marker } of REPLACE_FILES) {
    const src = fs.readFileSync(path.join(TEMPLATE, rel), 'utf8')
    const dst = path.join(dir, rel)
    const current = fs.existsSync(dst) ? fs.readFileSync(dst, 'utf8') : ''
    if (current === src) continue
    const baseline = committedTemplate(rel)
    const ours = current.includes(marker)
    if (!FORCE && !ours && baseline !== null && current !== baseline) {
      note(course, `WARNING — ${rel} is customised; wire it up by hand or re-run with --force`)
      continue
    }
    write(dst, src)
    note(course, `rewired ${rel}`)
  }

  // 3. message keys (add only; never overwrite an existing translation)
  for (const file of fs.readdirSync(path.join(dir, 'messages'))) {
    if (!file.endsWith('.json')) continue
    const tmplPath = path.join(TEMPLATE, 'messages', file)
    // A locale the template doesn't ship falls back to English strings.
    const source = JSON.parse(fs.readFileSync(fs.existsSync(tmplPath) ? tmplPath : path.join(TEMPLATE, 'messages/en.json'), 'utf8'))
    const dst = path.join(dir, 'messages', file)
    const target = JSON.parse(fs.readFileSync(dst, 'utf8'))
    const added = MESSAGE_KEYS.filter((k) => !target[k])
    if (added.length === 0) continue
    for (const k of added) target[k] = source[k]
    write(dst, JSON.stringify(target, null, 2) + '\n')
    note(course, `messages/${file}: added ${added.join(', ')}`)
  }

  // 4. npm scripts
  const pkgPath = path.join(dir, 'package.json')
  const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'))
  if (!pkg.scripts['gen:timestamps']) {
    const { dev, build, start, ...others } = pkg.scripts
    pkg.scripts = {
      ...others,
      'gen:timestamps': 'node scripts/gen-page-timestamps.mjs',
      predev: 'npm run gen:timestamps',
      dev,
      prebuild: 'npm run gen:timestamps',
      build,
      start,
    }
    write(pkgPath, JSON.stringify(pkg, null, 2) + '\n')
    note(course, 'package.json: added gen:timestamps / predev / prebuild')
  }

  // 5. history page + empty release history
  const historyPage = path.join(dir, 'content', 'history.mdx')
  if (!fs.existsSync(historyPage) && !fs.existsSync(path.join(dir, 'content', 'history.md'))) {
    write(historyPage, fs.readFileSync(path.join(TEMPLATE, 'content/history.mdx'), 'utf8'))
    note(course, 'added content/history.mdx')
  }
  const historyData = path.join(dir, 'data', 'deploy-history.json')
  if (!fs.existsSync(historyData)) {
    write(
      historyData,
      JSON.stringify({ courseId: course.replace(/^elearn-/, ''), slug: '', entries: [] }, null, 2) + '\n',
    )
    note(course, 'added data/deploy-history.json (empty — the next deploy records release 1)')
  }

  // 5b. sidebar entry for the history page (Nextra would otherwise append it
  // with an auto-generated label, after everything else)
  const metaPath = path.join(dir, 'content', '_meta.ts')
  if (fs.existsSync(metaPath)) {
    const meta = fs.readFileSync(metaPath, 'utf8')
    const lines = meta.replace(/\s+$/, '').split('\n')
    if (/['"]?history['"]?\s*:/.test(meta)) {
      // already listed
    } else if (lines[lines.length - 1].trim() === '}') {
      // The last property may have no trailing comma — appending after it
      // without one is a syntax error that only surfaces at build time.
      const last = lines.length - 2
      if (last >= 0 && lines[last].trim() && !/[,{[]$/.test(lines[last].trimEnd())) {
        lines[last] = lines[last].trimEnd() + ','
      }
      lines.splice(lines.length - 1, 0, "  history: 'Course History',")
      write(metaPath, lines.join('\n') + '\n')
      note(course, 'content/_meta.ts: added the Course History entry')
    } else {
      note(course, "WARNING — content/_meta.ts has an unusual shape; add `history: 'Course History'` by hand")
    }
  }

  // 6. "What's new" on the course home page
  let home = ['content/index.mdx', 'content/index.md']
    .map((rel) => path.join(dir, rel))
    .find((p) => fs.existsSync(p))
  // Nextra renders .md as plain markdown, so JSX there would show up as literal
  // text. Promote an MDX-safe home page to .mdx (keeping git history via git mv,
  // and its dates via route-keyed history); leave a risky one alone.
  if (home && home.endsWith('.md')) {
    const hazards = mdxHazards(fs.readFileSync(home, 'utf8'))
    if (hazards.length) {
      note(
        course,
        `WARNING — ${path.relative(dir, home)} is markdown, not MDX, and is not safe to convert ` +
          `(line ${hazards[0].line}: ${hazards[0].text}); "What's new" lives on /history only`,
      )
      home = null
    } else {
      const mdx = home.replace(/\.md$/, '.mdx')
      if (!DRY) {
        try {
          execFileSync('git', ['mv', home, mdx], { cwd: ROOT, stdio: ['ignore', 'ignore', 'ignore'] })
        } catch {
          fs.renameSync(home, mdx) // untracked file
        }
      }
      note(course, `renamed ${path.relative(dir, home)} → index.mdx (JSX needs MDX)`)
      home = DRY ? null : mdx
    }
  }
  if (!home) {
    if (!DRY) note(course, 'no MDX home page — add <RecentPages /> to the home page by hand if you want it there')
  } else {
    const text = fs.readFileSync(home, 'utf8')
    if (!text.includes('course-whats-new:start')) {
      // Keep the personalised "recently visited" list last, as on the template.
      const anchor = text.indexOf('<RecentlyVisited')
      const next =
        anchor >= 0
          ? text.slice(0, anchor) + WHATS_NEW + '\n' + text.slice(anchor)
          : text.replace(/\s*$/, '\n\n') + WHATS_NEW
      write(home, next)
      note(course, `added the What's new block to ${path.relative(dir, home)}`)
    }
  }

  // 7. page dates
  if (!DRY) {
    try {
      execFileSync('node', [path.join(dir, 'scripts/gen-page-timestamps.mjs'), '--quiet'], { stdio: 'inherit' })
      const data = JSON.parse(fs.readFileSync(path.join(dir, 'data/page-timestamps.json'), 'utf8'))
      note(course, `page dates generated for ${Object.keys(data.pages).length} pages`)
    } catch (err) {
      note(course, `WARNING — could not generate page dates: ${err.message}`)
    }
  }
}

const dirs = courseDirs()
if (dirs.length === 0) {
  console.error('usage: retrofit-timestamps.mjs <slug-or-dir> [...] | --all  [--force] [--dry-run]')
  process.exit(2)
}
for (const dir of dirs) {
  if (!fs.existsSync(dir)) {
    note(path.basename(dir), 'SKIPPED — directory not found')
    continue
  }
  retrofit(dir)
}
console.log(`${DRY ? '[dry run] ' : ''}retrofit-timestamps — ${dirs.length} course(s)`)
console.log(changes.length ? changes.join('\n') : '  nothing to do (all up to date)')
console.log('\nRebuild + redeploy each course for the change to reach learners:')
console.log('  ELEARN_DEPLOYMENT=<profile> ~/.claude/skills/elearn-course/scripts/deploy.sh <slug> "<Title>"')
