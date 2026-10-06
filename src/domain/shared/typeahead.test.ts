import { describe, expect, it } from "vitest";
import {
  dedupeNames,
  exactTypeahead,
  hasTyped,
  matchTypeahead,
  normalizeTypeahead,
} from "@/domain/shared/typeahead";

const name = (text: string) => text;

describe("hasTyped", () => {
  it("is false for nothing and for spaces alone, true once there is a character", () => {
    expect(hasTyped("")).toBe(false);
    expect(hasTyped("   ")).toBe(false);
    expect(hasTyped(" a")).toBe(true);
  });
});

describe("matchTypeahead", () => {
  const all = ["Toko Bangunan Jaya", "Bangunan Sejahtera", "Jaya Abadi", "CV Maju"];

  it("offers nothing until something is typed, so clicking into a field never opens the list", () => {
    expect(matchTypeahead("", all, name)).toEqual([]);
    expect(matchTypeahead("   ", all, name)).toEqual([]);
  });

  it("matches only the start of a name for one character", () => {
    expect(matchTypeahead("j", all, name)).toEqual(["Jaya Abadi"]);
    expect(matchTypeahead("b", all, name)).toEqual(["Bangunan Sejahtera"]);
  });

  it("lists names that start with the text first, then names that contain it, from two characters", () => {
    expect(matchTypeahead("ba", all, name)).toEqual([
      "Bangunan Sejahtera",
      "Toko Bangunan Jaya",
      "Jaya Abadi",
    ]);
  });

  it("narrows as the text gets longer", () => {
    expect(matchTypeahead("ja", all, name)).toEqual([
      "Jaya Abadi",
      "Toko Bangunan Jaya",
      "Bangunan Sejahtera",
    ]);
    expect(matchTypeahead("jaya a", all, name)).toEqual(["Jaya Abadi"]);
    expect(matchTypeahead("jaya abadi x", all, name)).toEqual([]);
  });

  it("ignores case and extra spacing, and respects the limit", () => {
    expect(matchTypeahead("  TOKO   bang ", all, name)).toEqual(["Toko Bangunan Jaya"]);
    const many = Array.from({ length: 10 }, (_, i) => `Barang ${i}`);
    expect(matchTypeahead("barang", many, name, 3)).toHaveLength(3);
  });
});

describe("exactTypeahead", () => {
  it("finds the same name regardless of case and spacing, and nothing for an empty text", () => {
    expect(exactTypeahead(" jaya  abadi", ["Jaya Abadi"], name)).toBe("Jaya Abadi");
    expect(exactTypeahead("jaya", ["Jaya Abadi"], name)).toBeUndefined();
    expect(exactTypeahead("", ["Jaya Abadi"], name)).toBeUndefined();
  });
});

describe("dedupeNames", () => {
  it("keeps the first spelling of a repeated name and drops blanks and non-text", () => {
    expect(dedupeNames(["Toko Jaya", "  toko   jaya ", null, undefined, "  ", "CV Maju"])).toEqual([
      "Toko Jaya",
      "CV Maju",
    ]);
  });
});

describe("normalizeTypeahead", () => {
  it("trims, collapses spaces and lowercases", () => {
    expect(normalizeTypeahead("  Toko   JAYA ")).toBe("toko jaya");
  });
});
