import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

/**
 * A module marked "use client" turns every export into a client reference when a SERVER file imports it.
 * A component is fine (it renders on the client), but a plain constant such as a label map becomes unusable
 * there: `LABELS[key]` is undefined, so the screen falls back to the raw stored word (finding #104:
 * "expense" in the Kategori table). This guard fails when a server file imports an ALL_CAPS constant from a
 * "use client" module; such constants belong in a plain module.
 */
function walk(dir: string, out: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) walk(full, out);
    else if (/\.(ts|tsx)$/.test(name) && !/\.test\./.test(name)) out.push(full);
  }
  return out;
}

const isClient = (text: string) => /^\s*(["'])use client\1/.test(text);

describe("client module boundary", () => {
  it("no server file imports a constant from a 'use client' module", () => {
    const files = walk("src");
    const texts = new Map(files.map((f) => [f, readFileSync(f, "utf8")]));
    const clientConstants = new Map<string, string[]>();
    for (const [file, text] of texts) {
      if (!isClient(text)) continue;
      const names = [...text.matchAll(/^export const ([A-Z][A-Z0-9_]+)\b/gm)].map((m) => m[1]!);
      if (names.length) clientConstants.set(file.replace(/\.tsx?$/, ""), names);
    }
    const offenders: string[] = [];
    for (const [file, text] of texts) {
      if (isClient(text)) continue;
      for (const m of text.matchAll(/import\s*\{([^}]*)\}\s*from\s*["']([^"']+)["']/g)) {
        const spec = m[2]!;
        const target = spec.startsWith("@/")
          ? join("src", spec.slice(2))
          : spec.startsWith(".")
            ? join(file, "..", spec)
            : null;
        const names = target ? clientConstants.get(target) : undefined;
        if (!names) continue;
        for (const n of names) {
          if (new RegExp(`\\b${n}\\b`).test(m[1]!))
            offenders.push(`${file} imports ${n} from ${spec}`);
        }
      }
    }
    expect(offenders).toEqual([]);
  });
});
