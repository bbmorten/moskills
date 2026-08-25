// VENDORED VERBATIM from ai-resource-sched/deploy-skills/image/guard.mjs
// Do not edit here. Refresh with tools/sync-guard.sh so local validation
// stays byte-identical to the screening the skills service actually runs.
/**
 * guard.mjs — screening for skill content, and the trust × verdict install policy.
 *
 * WHY THIS EXISTS SEPARATELY FROM OPA. Content arriving via `save_skill` is
 * already OPA-scanned by the gateway relay, because it rides in the tool-call
 * ARGUMENTS. Content arriving via `hub_install` is not: the arguments are just
 * an identifier ("anthropics/skills/pdf") and the bytes are fetched by this pod
 * afterwards, so they never pass through the relay's scan. This module is the
 * screening for that path — and it runs on both paths, so a bundle is judged
 * the same way however it arrived.
 *
 * WHAT IT IS NOT. This is regex static analysis. It raises the cost of shipping
 * something hostile; it is not a sandbox and it does not prove a script safe.
 * The controls that actually bound damage are elsewhere: skills are executed by
 * the CONSUMER (dsh sandbox, Claude Code, the aimo interpreter pod), never by
 * this pod, and the trust matrix below refuses to install unreviewed community
 * content that trips any rule at all.
 */

export const TRUST_LEVELS = Object.freeze(["builtin", "trusted", "community", "agent-created"]);

// verdict → decision, per trust level. Mirrors hermes-agent's INSTALL_POLICY.
// "agent-created" blocks on dangerous rather than asking: this server has no
// interactive channel, and a blocked save returns the findings to the agent,
// which can retry without the flagged content — the same outcome as an "ask".
export const INSTALL_POLICY = Object.freeze({
  builtin: { safe: "allow", caution: "allow", dangerous: "allow" },
  trusted: { safe: "allow", caution: "allow", dangerous: "block" },
  community: { safe: "allow", caution: "block", dangerous: "block" },
  "agent-created": { safe: "allow", caution: "allow", dangerous: "block" },
});

export const SCANNER_VERSION = "skills-guard-v1";

// ---------------------------------------------------------------------------
// patterns

const THREAT_PATTERNS = [
  // ── exfiltration / remote execution ───────────────────────────────────
  { id: "curl-pipe-shell", severity: "dangerous", re: /(?:curl|wget)[^\n|]{0,200}\|\s*(?:sudo\s+)?(?:ba|z|k)?sh\b/i,
    note: "downloads and executes a remote script in one step" },
  { id: "base64-pipe-shell", severity: "dangerous", re: /base64\s+(?:-d|--decode)[^\n|]{0,80}\|\s*(?:ba|z|k)?sh\b/i,
    note: "decodes and executes obfuscated shell" },
  { id: "remote-exec-eval", severity: "dangerous", re: /\b(?:eval|exec)\s*\(\s*(?:atob|base64\.b64decode|bytes\.fromhex)\s*\(/i,
    note: "evaluates decoded/obfuscated code at runtime" },
  { id: "reverse-shell", severity: "dangerous", re: /(?:nc|ncat|netcat)\s+(?:-[a-z]*e[a-z]*\s|.*\s-e\s)|bash\s+-i\s*>&\s*\/dev\/tcp/i,
    note: "reverse shell" },
  { id: "raw-ip-post", severity: "caution", re: /(?:curl|wget|requests\.post|fetch)\s*\(?[^\n]{0,80}https?:\/\/\d{1,3}(?:\.\d{1,3}){3}/i,
    note: "sends data to a hardcoded IP address" },
  { id: "pastebin-egress", severity: "caution", re: /https?:\/\/(?:pastebin\.com|paste\.ee|transfer\.sh|0x0\.st|termbin\.com|webhook\.site|requestbin)/i,
    note: "references a known drop/exfiltration host" },

  // ── credential and secret access ──────────────────────────────────────
  { id: "ssh-private-key", severity: "dangerous", re: /(?:~|\$HOME|\/root|\/home\/[^\s/]+)\/\.ssh\/(?:id_[a-z0-9]+|identity)\b/i,
    note: "reads SSH private keys" },
  { id: "cloud-credentials", severity: "dangerous", re: /(?:~|\$HOME)\/\.(?:aws\/credentials|kube\/config|docker\/config\.json|netrc)\b/i,
    note: "reads stored cloud/cluster credentials" },
  { id: "k8s-serviceaccount", severity: "dangerous", re: /\/var\/run\/secrets\/kubernetes\.io\/serviceaccount/,
    note: "reads the pod's Kubernetes service-account token" },
  { id: "env-file-harvest", severity: "caution", re: /\b(?:cat|read|open|load_dotenv)\b[^\n]{0,40}\.env\b/i,
    note: "reads .env files" },
  { id: "credential-sweep", severity: "caution", re: /\b(?:grep|rg|ag)\b[^\n]{0,80}(?:api[_-]?key|secret|password|token)[^\n]{0,40}(?:-r|--recursive|\/)/i,
    note: "sweeps the filesystem for credentials" },
  { id: "env-dump-egress", severity: "dangerous", re: /(?:printenv|env)\b[^\n|]{0,40}\|[^\n]{0,80}(?:curl|wget|nc)\b/i,
    note: "pipes the environment to the network" },

  // ── destructive ───────────────────────────────────────────────────────
  { id: "rm-rf-root", severity: "dangerous", re: /\brm\s+(?:-[a-zA-Z]*\s+)*-[a-zA-Z]*[rR][a-zA-Z]*f?[a-zA-Z]*\s+(?:\/|\$HOME\s*$|~\s*$|\/\*)/,
    note: "recursive delete of a root or home path" },
  { id: "disk-overwrite", severity: "dangerous", re: /\b(?:dd\s+[^\n]{0,60}of=\/dev\/|mkfs(?:\.[a-z0-9]+)?\s+\/dev\/)/i,
    note: "overwrites a block device" },
  { id: "fork-bomb", severity: "dangerous", re: /:\(\)\s*\{\s*:\|:&\s*\}\s*;\s*:/,
    note: "fork bomb" },
  { id: "history-wipe", severity: "caution", re: /\b(?:history\s+-c|>\s*~\/\.bash_history|unset\s+HISTFILE)\b/,
    note: "clears shell history (anti-forensics)" },
  { id: "git-force-push", severity: "caution", re: /\bgit\s+push\b[^\n]{0,60}(?:--force(?!-with-lease)|-f)\b/,
    note: "force-pushes, which can destroy remote history" },

  // ── persistence ───────────────────────────────────────────────────────
  { id: "crontab-install", severity: "dangerous", re: /\b(?:crontab\s+-|>\s*\/etc\/cron|\/etc\/cron\.[a-z]+\/)/,
    note: "installs a cron job" },
  { id: "systemd-unit", severity: "dangerous", re: /(?:\/etc\/systemd\/system\/|systemctl\s+enable\b)/,
    note: "installs or enables a systemd unit" },
  { id: "shell-rc-append", severity: "caution", re: />>\s*(?:~|\$HOME)\/\.(?:bashrc|zshrc|profile|bash_profile)\b/,
    note: "appends to a shell startup file" },
  { id: "launch-agent", severity: "dangerous", re: /(?:~|\$HOME)?\/Library\/LaunchAgents\/|launchctl\s+load\b/,
    note: "installs a macOS LaunchAgent" },
  { id: "ssh-authorized-keys", severity: "dangerous", re: />>?\s*(?:~|\$HOME|\/root)\/\.ssh\/authorized_keys/,
    note: "writes an SSH authorized key" },

  // ── agent-directed / prompt injection ─────────────────────────────────
  { id: "prompt-injection", severity: "dangerous",
    re: /\b(?:ignore|disregard|forget)\s+(?:all\s+)?(?:your\s+)?(?:previous|prior|earlier|above|system)\s+(?:instructions|prompts?|rules|directives)\b/i,
    note: "attempts to override the agent's instructions" },
  { id: "instruction-suppression", severity: "dangerous",
    re: /\b(?:do\s+not|don't|never)\s+(?:tell|inform|mention|report|show)\s+(?:the\s+)?(?:user|human|operator)\b/i,
    note: "instructs the agent to conceal its actions from the user" },
  { id: "approval-bypass", severity: "dangerous",
    re: /\b(?:skip|bypass|suppress|auto[- ]?approve)\b[^\n]{0,40}\b(?:confirmation|approval|permission|safety)\b/i,
    note: "instructs the agent to bypass approval gates" },
  // Narrowed and downgraded after calibration: the original form ("send…
  // conversation|credentials") fired on ORDINARY API DOCUMENTATION in
  // anthropics/skills — "send the full conversation" in a Messages-API README
  // and a reference table row `POST | /v1/vaults/{id}/credentials` — blocking
  // official skills. Separating "instructs the agent to exfiltrate" from
  // "documents an API that posts data" is semantic, not lexical, so this now
  // requires a possessive pointing at the USER'S data and only warns. The
  // precise members of this family (prompt-injection, instruction-suppression,
  // approval-bypass) had zero false positives across the same 20 skills.
  { id: "tool-exfil-directive", severity: "caution",
    re: /\b(?:send|upload|post|exfiltrate|forward)\b[^\n]{0,40}\b(?:the user's|your|this)\s+(?:conversation|chat history|system prompt|credentials|api key|secrets?)\b/i,
    note: "phrasing that reads as directing the agent to send the user's own context somewhere" },

  // ── obfuscation ───────────────────────────────────────────────────────
  { id: "long-base64-blob", severity: "caution", re: /[A-Za-z0-9+/]{512,}={0,2}/,
    note: "contains a long encoded blob" },
  { id: "long-hex-blob", severity: "caution", re: /(?:\\x[0-9a-fA-F]{2}){64,}/,
    note: "contains a long hex-escaped blob" },
  { id: "python-marshal-loads", severity: "dangerous", re: /\b(?:marshal|pickle)\.loads?\s*\(/,
    note: "deserializes arbitrary objects (code execution)" },
];

// Unicode that renders invisibly or reverses display order — the classic way to
// hide an instruction from a human reviewer while the model still reads it.
//
// Split by severity after calibration. Bidi controls have no legitimate place in
// a skill and stay dangerous. The zero-width family does: ZWJ/ZWNJ are REQUIRED
// for emoji sequences and for Persian/Arabic/Indic text, and U+FEFF is the UTF-8
// BOM — which is why 9 ECMA OOXML .xsd schemas in anthropics/skills were flagged
// as smuggling on their first byte. Those are caution, and a BOM at offset 0 is
// not a finding at all.
const BIDI_CHARS = new Map([
  ["‪", "left-to-right embedding"],
  ["‫", "right-to-left embedding"],
  ["‭", "left-to-right override"],
  ["‮", "right-to-left override"],
  ["⁦", "left-to-right isolate"],
  ["⁧", "right-to-left isolate"],
  ["⁨", "first-strong isolate"],
]);
const ZERO_WIDTH_CHARS = new Map([
  ["​", "zero-width space"],
  ["‌", "zero-width non-joiner"],
  ["‍", "zero-width joiner"],
  ["⁠", "word joiner"],
  ["﻿", "zero-width no-break space"],
]);
const BOM = "﻿";
// Unicode tag block — invisible, and the documented ASCII-smuggling channel.
const TAG_CHAR_RE = /[\u{E0000}-\u{E007F}]/u;

const SCANNABLE_EXT = new Set([
  ".md", ".txt", ".py", ".sh", ".bash", ".zsh", ".js", ".mjs", ".cjs", ".ts",
  ".json", ".yaml", ".yml", ".toml", ".rb", ".pl", ".ps1", ".rs", ".go", ".sql",
  ".html", ".css", ".xml", ".ini", ".cfg", ".env", ".tex", ".r",
]);
const BINARY_EXT_BLOCKED = new Set([
  ".exe", ".dll", ".so", ".dylib", ".bin", ".msi", ".app", ".deb", ".rpm",
  ".jar", ".class", ".pyc", ".pyo", ".wasm", ".scpt", ".apk",
]);
// Binary formats a skill legitimately ships: fonts, images, documents, archives.
// Real bundles carry these outside assets/ (anthropics/skills keeps fonts in
// canvas-fonts/ and a PDF in themes/), so the check keys on the FORMAT, not on
// which directory the file happens to live in.
const KNOWN_ASSET_EXT = new Set([
  ".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp", ".ico", ".bmp", ".pdf",
  ".ttf", ".otf", ".woff", ".woff2", ".eot",
  ".mp3", ".mp4", ".wav", ".ogg", ".webm",
  ".zip", ".gz", ".tar", ".xlsx", ".docx", ".pptx",
]);

function extOf(rel) {
  const i = rel.lastIndexOf(".");
  return i < 0 ? "" : rel.slice(i).toLowerCase();
}

function looksBinary(bytes) {
  const window = bytes.subarray(0, 8000);
  for (const byte of window) if (byte === 0) return true;
  return false;
}

// ---------------------------------------------------------------------------
// scanning

/**
 * Scan a normalized files[] array ([{path, bytes, executable}]).
 * Returns {verdict, findings, stats}. Never throws.
 */
export function scanSkill(files) {
  const findings = [];
  let totalBytes = 0;

  for (const file of files) {
    totalBytes += file.bytes.length;
    const ext = extOf(file.path);

    if (BINARY_EXT_BLOCKED.has(ext)) {
      findings.push({
        rule: "binary-executable", severity: "dangerous", file: file.path,
        note: `bundled ${ext} binary — skills must ship source, not compiled artifacts`,
      });
      continue;
    }
    if (looksBinary(file.bytes)) {
      if (!KNOWN_ASSET_EXT.has(ext)) {
        findings.push({
          rule: "unexpected-binary", severity: "caution", file: file.path,
          note: `binary content with an unrecognized extension (${ext || "none"})`,
        });
      }
      continue; // no text scan on binary
    }
    // An unreadable format is only worth flagging when it is also EXECUTABLE:
    // that is a script the scanner cannot read. A .tex or .bib the scanner
    // skips is inert, and flagging it would block most community skills for
    // shipping documentation.
    if (file.executable && ext && !SCANNABLE_EXT.has(ext)) {
      findings.push({
        rule: "unscannable-executable", severity: "caution", file: file.path,
        note: `executable ${ext} file that the scanner cannot read`,
      });
    }

    const text = file.bytes.toString("utf-8");

    const bidi = [...BIDI_CHARS.keys()].filter((c) => text.includes(c));
    if (bidi.length) {
      findings.push({
        rule: "bidi-override", severity: "dangerous", file: file.path,
        note: `display-reordering controls: ${bidi.map((c) => BIDI_CHARS.get(c)).join(", ")}`,
      });
    }
    // A BOM is legitimate at offset 0 only; the same codepoint mid-document is
    // the hiding trick. Everything else in the zero-width family is checked
    // anywhere but is only a caution — emoji and Indic scripts need it.
    const body = text.startsWith(BOM) ? text.slice(1) : text;
    const zeroWidth = [...ZERO_WIDTH_CHARS.keys()].filter((c) => body.includes(c));
    if (zeroWidth.length) {
      findings.push({
        rule: "zero-width-characters", severity: "caution", file: file.path,
        note: `invisible characters: ${zeroWidth.map((c) => ZERO_WIDTH_CHARS.get(c)).join(", ")}`,
      });
    }
    if (TAG_CHAR_RE.test(text)) {
      findings.push({
        rule: "unicode-tag-smuggling", severity: "dangerous", file: file.path,
        note: "Unicode tag characters (invisible instruction smuggling)",
      });
    }

    for (const pattern of THREAT_PATTERNS) {
      const match = pattern.re.exec(text);
      if (!match) continue;
      const line = text.slice(0, match.index).split("\n").length;
      findings.push({
        rule: pattern.id,
        severity: pattern.severity,
        file: file.path,
        line,
        note: pattern.note,
        excerpt: match[0].slice(0, 120),
      });
    }
  }

  const verdict = findings.some((f) => f.severity === "dangerous")
    ? "dangerous"
    : findings.length
      ? "caution"
      : "safe";

  return {
    verdict,
    findings,
    scanner: SCANNER_VERSION,
    scannedAt: new Date().toISOString(),
    stats: { fileCount: files.length, totalBytes },
  };
}

/** Apply the trust × verdict matrix. Returns {allowed, reason}. */
export function decideInstall(trustLevel, scan) {
  const row = INSTALL_POLICY[trustLevel];
  if (!row) return { allowed: false, reason: `unknown trust level ${JSON.stringify(trustLevel)}` };
  const decision = row[scan.verdict];
  if (decision === "allow") {
    return {
      allowed: true,
      reason:
        scan.verdict === "safe"
          ? "no findings"
          : `${scan.verdict} findings allowed for trust level "${trustLevel}"`,
    };
  }
  return {
    allowed: false,
    reason: `screening verdict "${scan.verdict}" is blocked for trust level "${trustLevel}"`,
  };
}

/** Human-readable report, used verbatim in blocked-install tool errors. */
export function formatScanReport(name, trustLevel, scan) {
  const lines = [
    `screening report for "${name}" (trust: ${trustLevel}, verdict: ${scan.verdict})`,
    `${scan.stats.fileCount} file(s), ${scan.stats.totalBytes} bytes, scanner ${scan.scanner}`,
  ];
  if (!scan.findings.length) {
    lines.push("no findings.");
    return lines.join("\n");
  }
  lines.push("findings:");
  for (const f of scan.findings.slice(0, 25)) {
    const where = f.line ? `${f.file}:${f.line}` : f.file;
    lines.push(`- [${f.severity}] ${f.rule} at ${where} — ${f.note}`);
    if (f.excerpt) lines.push(`    ${f.excerpt.replace(/\s+/g, " ")}`);
  }
  if (scan.findings.length > 25) lines.push(`… and ${scan.findings.length - 25} more`);
  return lines.join("\n");
}
