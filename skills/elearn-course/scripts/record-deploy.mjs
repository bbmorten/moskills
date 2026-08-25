#!/usr/bin/env node
/**
 * Maintain a course's release history: sites/elearn-<course-id>/data/deploy-history.json.
 *
 * The course's own `<DeployHistory />` component (content/history.mdx) renders
 * this file, so it has to be written BEFORE `docker build` — that is the only
 * way the running pod can describe when it was deployed. deploy.sh therefore
 * appends the entry up front and calls `rollback` if the build or the rollout
 * fails, so the history only ever lists releases that actually went live.
 *
 * Usage:
 *   record-deploy.mjs init     <course-dir> [--course-id ID] [--slug S]
 *   record-deploy.mjs add      <course-dir> [--image REF] [--commit SHA] [--deployment NAME]
 *                                           [--namespace NS] [--host H] [--note TEXT]
 *                                           [--course-id ID] [--slug S] [--action deploy|update]
 *   record-deploy.mjs rollback <course-dir>   # drop the last entry (failed deploy)
 *   record-deploy.mjs backfill <course-dir> --at <iso> [--note TEXT] [--image REF]
 *
 * `backfill` prepends the release a course already had before this feature
 * existed, so its history doesn't claim it was first deployed the day it was
 * retrofitted. Get the real date from the cluster:
 *   kubectl -n elearn get deploy elearn-<course-id> \
 *     -o jsonpath='{.metadata.creationTimestamp}'
 */
import fs from 'node:fs'
import path from 'node:path'

const [, , cmd, dirArg, ...rest] = process.argv
if (!cmd || !dirArg) {
  console.error('usage: record-deploy.mjs <init|add|rollback> <course-dir> [flags]')
  process.exit(2)
}

const flags = {}
for (let i = 0; i < rest.length; i++) {
  if (rest[i].startsWith('--')) flags[rest[i].slice(2)] = rest[i + 1]?.startsWith('--') ? '' : (rest[++i] ?? '')
}

const DIR = path.resolve(dirArg)
const FILE = path.join(DIR, 'data', 'deploy-history.json')

/** Same shape and local offset as git's %aI, matching gen-page-timestamps.mjs. */
function localISO(d = new Date()) {
  const pad = (n) => String(n).padStart(2, '0')
  const off = -d.getTimezoneOffset()
  const sign = off >= 0 ? '+' : '-'
  return (
    `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}` +
    `T${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}` +
    `${sign}${pad(Math.floor(Math.abs(off) / 60))}:${pad(Math.abs(off) % 60)}`
  )
}

function load() {
  try {
    const data = JSON.parse(fs.readFileSync(FILE, 'utf8'))
    if (!Array.isArray(data.entries)) data.entries = []
    return data
  } catch {
    return { courseId: path.basename(DIR).replace(/^elearn-/, ''), slug: '', entries: [] }
  }
}

function save(data) {
  fs.mkdirSync(path.dirname(FILE), { recursive: true })
  fs.writeFileSync(FILE, JSON.stringify(data, null, 2) + '\n')
}

const data = load()
if (flags['course-id']) data.courseId = flags['course-id']
if (flags.slug) data.slug = flags.slug

if (cmd === 'init') {
  data.entries = []
  save(data)
  console.log(`[deploy-history] initialised ${path.relative(process.cwd(), FILE)}`)
} else if (cmd === 'add') {
  const at = localISO()
  const entry = {
    at,
    date: at.slice(0, 10),
    // The first release is the course going live; everything after is an update.
    action: flags.action || (data.entries.length === 0 ? 'deploy' : 'update'),
    image: flags.image || '',
    commit: flags.commit || '',
    deployment: flags.deployment || '',
    namespace: flags.namespace || '',
    host: flags.host || '',
    note: flags.note || '',
  }
  data.entries.push(entry)
  save(data)
  console.log(`[deploy-history] recorded ${entry.action} on ${entry.date} (${data.entries.length} total)`)
} else if (cmd === 'backfill') {
  const at = flags.at
  if (!at || Number.isNaN(Date.parse(at))) {
    console.error('backfill needs --at <ISO timestamp> (e.g. the Deployment creationTimestamp)')
    process.exit(2)
  }
  // Idempotent: a retried deploy must not stack a second backfill on top of the
  // first (which would also demote the real one to an "update").
  if (data.entries.some((e) => e.at === at)) {
    console.log(`[deploy-history] already backfilled at ${at} — nothing to do`)
    process.exit(0)
  }
  // Whatever used to be first was only the first *recorded* release.
  if (data.entries[0]) data.entries[0].action = 'update'
  data.entries.unshift({
    at,
    date: at.slice(0, 10),
    action: 'deploy',
    image: flags.image || '',
    commit: flags.commit || '',
    deployment: flags.deployment || '',
    namespace: flags.namespace || '',
    host: flags.host || '',
    note: flags.note || 'Backfilled from the cluster',
  })
  save(data)
  console.log(`[deploy-history] backfilled the first deployment as ${at.slice(0, 10)}`)
} else if (cmd === 'rollback') {
  const dropped = data.entries.pop()
  save(data)
  console.log(
    dropped
      ? `[deploy-history] rolled back the ${dropped.action} entry from ${dropped.at}`
      : '[deploy-history] nothing to roll back',
  )
} else {
  console.error(`unknown command: ${cmd}`)
  process.exit(2)
}
