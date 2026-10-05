import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { describe, expect, it } from "vitest";

/**
 * A file that starts with the "use server" directive may export ONLY async functions (and types, which are
 * erased). Next.js checks this when the module is first loaded -- at runtime, not in `tsc`, lint or the
 * build -- so a stray exported constant makes every action in the file fail in production (this is what
 * broke saving a customer on 5 October 2026). This test reads every such file and refuses anything else.
 */

const ROOT = join(process.cwd(), "src");

function sourceFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) return sourceFiles(full);
    return /\.(ts|tsx)$/.test(name) && !/\.test\.tsx?$/.test(name) ? [full] : [];
  });
}

function isUseServer(source: string): boolean {
  const withoutComments = source.replace(/^(\s*(\/\*[\s\S]*?\*\/|\/\/[^\n]*))+/, "").trimStart();
  return /^["']use server["']/.test(withoutComments);
}

const ALLOWED_EXPORT = /^export\s+(async\s+function\b|type\b|interface\b)/;

describe("files with the use server directive", () => {
  const files = sourceFiles(ROOT).filter((file) => isUseServer(readFileSync(file, "utf8")));

  it("finds the server action files", () => {
    expect(files.length).toBeGreaterThan(5);
  });

  for (const file of files) {
    it(`${relative(ROOT, file)} exports only async functions`, () => {
      const offenders = readFileSync(file, "utf8")
        .split("\n")
        .filter((line) => /^export\b/.test(line) && !ALLOWED_EXPORT.test(line));
      expect(offenders).toEqual([]);
    });
  }
});
