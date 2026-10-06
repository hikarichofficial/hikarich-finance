import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

/**
 * Decision 308 (OWNER, 6 October 2026): every action announces its result, and re-verification happens in a
 * popup instead of on another page. These guards keep new screens from quietly going back to the old way.
 */
function walk(dir: string, out: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) walk(full, out);
    else if (/\.(ts|tsx)$/.test(name) && !/\.test\./.test(name)) out.push(full);
  }
  return out;
}

const files = walk("src").map((f) => [f.replaceAll("\\", "/"), readFileSync(f, "utf8")] as const);

describe("action feedback", () => {
  it("forms use the notice-aware useActionState, not React's", () => {
    const offenders = files
      .filter(([f]) => !f.endsWith("features/feedback/useActionState.ts"))
      .filter(([f]) => !f.endsWith("features/auth/AuthForms.tsx"))
      .filter(([, text]) =>
        /import\s*\{[^}]*\buseActionState\b[^}]*\}\s*from\s*["']react["']/.test(text),
      )
      .map(([f]) => f);
    expect(offenders).toEqual([]);
  });

  it("no link sends the person to the step-up page; the popup link is used instead", () => {
    const offenders = files
      .filter(([f]) => !f.endsWith("app/auth/step-up/page.tsx"))
      .filter(([f]) => !f.endsWith("features/feedback/StepUp.tsx"))
      .filter(([, text]) => /<Link[^>]*step-up/.test(text) || /<Link\s+href=\{stepUp/.test(text))
      .map(([f]) => f);
    expect(offenders).toEqual([]);
  });

  it("an action that redirects after success leaves a notice for the next page", () => {
    const offenders = files
      .filter(([f]) => /^src\/features\/(?!auth\/).*\.ts$/.test(f))
      .filter(([, text]) => /^\s*"use server"/.test(text))
      .filter(([, text]) => /^\s+(await\s+)?redirect\(/m.test(text))
      .filter(([, text]) => !/\bsetFlash\(/.test(text))
      .map(([f]) => f);
    expect(offenders).toEqual([]);
  });
});
