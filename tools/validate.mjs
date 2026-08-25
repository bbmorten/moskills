#!/usr/bin/env node
/**
 * validate.mjs — check every skill in this repo against the contract the
 * skills service applies when it installs from a tap.
 *
 * WHY THIS EXISTS. This repo is consumed as a *tapped* registry, which the
 * service installs at trust level "community". In that row of the policy
 * matrix ANY finding blocks — a caution is as fatal as a dangerous. So the
 * bar for a skill here is not "nothing malicious", it is "zero findings",
 * and that is a bar you can trip by writing `cat .env` in a README. Running
 * this before pushing is how you find that out in a second instead of after
 * a confusing refusal in the dashboard.
 *
 * The scanner is tools/guard.mjs, vendored verbatim from the service image,
 * so a pass here is the same verdict the server will reach. The path and
 * size rules below are transcribed from the same image's store.mjs; keep
 * them in step with tools/sync-guard.sh.
 *
 * Usage:  node tools/validate.mjs [skill-name ...]     (default: all)
 * Exit:   0 = every skill installs at community trust, 1 = at least one blocks
 */

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { decideInstall, formatScanReport, scanSkill } from "./guard.mjs";

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const TRUST = "community"; // what a tapped repo gets; not negotiable from here

// ── transcribed from deploy-skills/image/store.mjs ────────────────────────
const NAME_RE = /^[a-z0-9][a-z0-9-]{0,63}$/;
const SEGMENT_RE = /^[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$/;
const MAX_PATH_SEGMENTS = 8;
const LIMITS = {
  MAX_FILES_PER_SKILL: 200,
  MAX_FILE_BYTES: 2 * 1024 * 1024,
  MAX_SKILL_BYTES: 8 * 1024 * 1024,
};

/** Returns the normalized path, or throws — the reason a file gets dropped. */
function validateRelPath(input) {
  const raw = String(input).trim().replace(/\\/g, "/");
  if (!raw) throw new Error("empty path");
  if (raw.startsWith("/")) throw new Error(`absolute path not allowed: ${raw}`);
  if (/^[A-Za-z]:/.test(raw)) throw new Error(`drive-qualified path not allowed: ${raw}`);
  const segments = raw.split("/");
  if (segments.length > MAX_PATH_SEGMENTS) {
    throw new Error(`path too deep (max ${MAX_PATH_SEGMENTS} segments): ${raw}`);
  }
  for (const segment of segments) {
    if (!segment || segment === "." || segment === "..") throw new Error(`traversal or empty segment: ${raw}`);
    if (segment.startsWith(".")) throw new Error(`hidden path segment not allowed: ${raw}`);
    if (!SEGMENT_RE.test(segment)) throw new Error(`unsupported characters in path: ${raw}`);
  }
  return segments.join("/");
}

function parseFrontmatter(content) {
  const m = content.match(/^---\n([\s\S]*?)\n---/);
  if (!m) return {};
  const out = {};
  for (const line of m[1].split("\n")) {
    const kv = line.match(/^([A-Za-z0-9_-]+):\s*(.*)$/);
    if (kv) out[kv[1]] = kv[2].trim().replace(/^["']|["']$/g, "");
  }
  return out;
}

// ── discovery ─────────────────────────────────────────────────────────────

/**
 * A skill is ANY directory holding a SKILL.md — the indexer keys on the path
 * suffix, not on skills/, so a stray SKILL.md under templates/ would publish
 * itself as a skill. Walking the whole repo (minus dot-dirs, which the
 * indexer skips too) is what surfaces that.
 */
function findSkillDirs(dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name.startsWith(".") || entry.name === "node_modules") continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) findSkillDirs(full, out);
    else if (entry.name === "SKILL.md" && full !== path.join(REPO, "SKILL.md")) out.push(dir);
  }
  return out;
}

function walkFiles(dir, base = dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walkFiles(full, base, out);
    else if (entry.isFile()) out.push(path.relative(base, full).split(path.sep).join("/"));
  }
  return out;
}

/**
 * The executable bit the server sees is the git mode, not the working-tree
 * mode — GitHub's tree API reports what is committed. Read it from the index
 * where the file is tracked, and fall back to stat for anything not yet added.
 */
function gitModes() {
  try {
    const out = execFileSync("git", ["ls-files", "-s"], { cwd: REPO, encoding: "utf-8" });
    const map = new Map();
    for (const line of out.split("\n")) {
      const m = line.match(/^(\d{6}) [0-9a-f]+ \d\t(.+)$/);
      if (m) map.set(m[2], m[1]);
    }
    return map;
  } catch {
    return new Map();
  }
}

// ── per-skill check ───────────────────────────────────────────────────────

function checkSkill(skillDir, modes) {
  const rel = path.relative(REPO, skillDir).split(path.sep).join("/");
  const errors = [];
  const warnings = [];

  const included = [];
  for (const filePath of walkFiles(skillDir)) {
    const abs = path.join(skillDir, filePath);
    try {
      const norm = validateRelPath(filePath);
      const mode = modes.get(`${rel}/${filePath}`);
      const executable = mode ? mode === "100755" : (fs.statSync(abs).mode & 0o111) !== 0;
      included.push({ path: norm, bytes: fs.readFileSync(abs), executable });
    } catch (error) {
      warnings.push(`dropped on install — ${error.message}`);
    }
  }

  if (!included.some((f) => f.path === "SKILL.md")) errors.push("no SKILL.md at the skill root");
  if (included.length > LIMITS.MAX_FILES_PER_SKILL) {
    errors.push(`${included.length} files, over the ${LIMITS.MAX_FILES_PER_SKILL}-file cap`);
  }
  for (const f of included) {
    if (f.bytes.length > LIMITS.MAX_FILE_BYTES) {
      errors.push(`${f.path} is ${f.bytes.length} bytes, over the ${LIMITS.MAX_FILE_BYTES}-byte per-file cap`);
    }
  }
  const total = included.reduce((sum, f) => sum + f.bytes.length, 0);
  if (total > LIMITS.MAX_SKILL_BYTES) {
    errors.push(`${total} bytes total, over the ${LIMITS.MAX_SKILL_BYTES}-byte per-skill cap`);
  }

  const md = included.find((f) => f.path === "SKILL.md");
  const frontmatter = md ? parseFrontmatter(md.bytes.toString("utf-8")) : {};
  const installName = frontmatter.name || path.basename(skillDir);
  if (!NAME_RE.test(installName)) {
    errors.push(`install name ${JSON.stringify(installName)} is not kebab-case (a-z, 0-9, hyphen; max 64)`);
  }
  if (!frontmatter.name) warnings.push("SKILL.md has no `name:` — the directory name is used instead");
  if (!frontmatter.description) warnings.push("SKILL.md has no `description:` — consumers cannot tell when to load it");

  const scan = scanSkill(included);
  const decision = decideInstall(TRUST, scan);

  return { rel, installName, files: included.length, total, scan, decision, errors, warnings };
}

// ── report ────────────────────────────────────────────────────────────────

const filter = process.argv.slice(2);
const modes = gitModes();
const dirs = findSkillDirs(REPO).sort();
const selected = filter.length ? dirs.filter((d) => filter.includes(path.basename(d))) : dirs;

if (!selected.length) {
  console.error(filter.length ? `no skill matching ${filter.join(", ")}` : "no skills found");
  process.exit(1);
}

let blocked = 0;
for (const dir of selected) {
  const r = checkSkill(dir, modes);
  const fatal = r.errors.length || !r.decision.allowed;
  if (fatal) blocked++;
  const kb = (r.total / 1024).toFixed(1);
  console.log(`\n${fatal ? "BLOCKED " : "ok      "} ${r.rel}  →  installs as "${r.installName}"  (${r.files} files, ${kb} KB, verdict: ${r.scan.verdict})`);
  for (const e of r.errors) console.log(`   error:   ${e}`);
  for (const w of r.warnings) console.log(`   warn:    ${w}`);
  if (r.scan.findings.length) {
    console.log(formatScanReport(r.rel, TRUST, r.scan).split("\n").slice(2).map((l) => `   ${l}`).join("\n"));
    if (!r.decision.allowed) console.log(`   → ${r.decision.reason}`);
  }
}

console.log(
  `\n${selected.length} skill(s) checked at trust "${TRUST}" — ${selected.length - blocked} installable, ${blocked} blocked.`
);
if (blocked) {
  console.log("A tapped repo installs at community trust, where ANY finding blocks. Fix the findings above.");
}
process.exit(blocked ? 1 : 0);
