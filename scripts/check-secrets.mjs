#!/usr/bin/env node
// Lightweight committed-secret scan (Step 14 §22: never commit secrets).
// Complements (does not replace) GitHub secret scanning. Prints file:line and the
// rule name only — never the matched value.
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
const SKIP_DIRS = new Set(["node_modules", ".next", ".git", ".vercel", "coverage", "out", "build"]);
const SKIP_FILES = new Set(["pnpm-lock.yaml"]);
const BINARY_EXT = /\.(png|jpe?g|webp|gif|ico|pdf|woff2?|ttf|otf|zip|gz)$/i;

const RULES = [
  { name: "private key block", re: /-----BEGIN (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----/ },
  {
    name: "JWT-like token",
    re: /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/,
  },
  { name: "Supabase secret key", re: /\bsb_secret_[A-Za-z0-9_-]{16,}\b/ },
  {
    name: "Supabase publishable key (real value)",
    re: /\bsb_publishable_(?!placeholder)[A-Za-z0-9_-]{16,}\b/,
  },
  { name: "GitHub token", re: /\b(?:ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{20,}\b/ },
  { name: "AWS access key id", re: /\bAKIA[0-9A-Z]{16}\b/ },
  { name: "Vercel token", re: /\bvercel_[A-Za-z0-9]{20,}\b/i },
  {
    name: "database URL with embedded password",
    re: /\bpostgres(?:ql)?:\/\/[^\s:/@<>]+:(?!<)[^\s@<>]{3,}@(?!localhost|127\.0\.0\.1)[^\s/]+/i,
  },
];

function* walk(dir) {
  for (const entry of readdirSync(dir)) {
    if (SKIP_DIRS.has(entry)) continue;
    const full = join(dir, entry);
    const info = statSync(full);
    if (info.isDirectory()) yield* walk(full);
    else if (info.isFile()) yield full;
  }
}

const findings = [];
let scanned = 0;
for (const file of walk(root)) {
  const rel = relative(root, file).split(sep).join("/");
  if (SKIP_FILES.has(rel) || BINARY_EXT.test(rel)) continue;
  // Local, git-ignored env files are not committed; the scan targets what would be pushed.
  if (/^\.env(\.|$)/.test(rel) && rel !== ".env.example") continue;
  const text = readFileSync(file, "utf8");
  scanned += 1;
  text.split(/\r?\n/).forEach((line, index) => {
    for (const rule of RULES) {
      if (rule.re.test(line)) findings.push(`${rel}:${index + 1}  ${rule.name}`);
    }
  });
}

if (findings.length > 0) {
  console.error("Possible secrets found (values intentionally not printed):");
  for (const f of findings) console.error("  " + f);
  console.error(
    "If a real secret was committed: rotate/revoke it, then clean history (Step 14 §22).",
  );
  process.exit(1);
}
console.log(`Secret scan OK (${scanned} files, ${RULES.length} rules).`);
