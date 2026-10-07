import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

// Decision 329: `overflow-x: hidden` on <body> breaks `position: sticky` (the left menu scrolled away).
const css = readFileSync("src/app/globals.css", "utf8");

describe("sticky application shell", () => {
  it("does not put overflow-x: hidden on html/body", () => {
    const block = /(?:^|\n)html,\s*body\s*\{[^}]*\}/.exec(css)?.[0] ?? "";
    expect(block).not.toMatch(/overflow/);
  });

  it("clips horizontal overflow on body without making it a scroll container", () => {
    expect(css).toMatch(/\nbody\s*\{\s*overflow-x:\s*clip;/);
  });

  it("keeps the sidebar and the top bar sticky", () => {
    expect(/\.app-sidebar\s*\{[^}]*position:\s*sticky/.test(css)).toBe(true);
    expect(/\.app-topbar\s*\{[^}]*position:\s*sticky/.test(css)).toBe(true);
  });
});
