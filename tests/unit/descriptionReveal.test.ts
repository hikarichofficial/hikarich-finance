import { describe, expect, it } from "vitest";
import { needsReveal, REVEAL_CHARACTER_LIMIT } from "@/domain/products/descriptionReveal";

describe("needsReveal (task 95)", () => {
  it("shows no reveal for empty or short descriptions", () => {
    expect(needsReveal(null)).toBe(false);
    expect(needsReveal(undefined)).toBe(false);
    expect(needsReveal("")).toBe(false);
    expect(needsReveal("   ")).toBe(false);
    expect(needsReveal("Lisensi software untuk satu akun.")).toBe(false);
    expect(needsReveal("a".repeat(REVEAL_CHARACTER_LIMIT))).toBe(false);
  });

  it("offers the reveal once the text is longer than the limit", () => {
    expect(needsReveal("a".repeat(REVEAL_CHARACTER_LIMIT + 1))).toBe(true);
    expect(needsReveal("a".repeat(221), 220)).toBe(true);
    expect(needsReveal("a".repeat(220), 220)).toBe(false);
  });

  it("offers the reveal for a short text spread over many lines", () => {
    expect(needsReveal("satu\ndua\ntiga")).toBe(true);
    expect(needsReveal("satu\ndua")).toBe(false);
  });
});
