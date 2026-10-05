import { describe, expect, it } from "vitest";
import {
  dedupeSuggestions,
  exactSuggestion,
  matchSuggestions,
  type LineSuggestion,
} from "@/domain/sales/lineSuggestions";

const s = (description: string, unit_price = "1000"): LineSuggestion => ({
  description,
  unit_price,
  category_id: null,
});

describe("dedupeSuggestions", () => {
  it("keeps the most recent entry of a repeated description, ignoring case and spacing", () => {
    const result = dedupeSuggestions([
      s("Jasa Desain", "500000"),
      s("  jasa   desain ", "400000"),
      s("E-book"),
    ]);
    expect(result.map((r) => r.description)).toEqual(["Jasa Desain", "E-book"]);
    expect(result[0].unit_price).toBe("500000");
  });
  it("drops blank descriptions", () => {
    expect(dedupeSuggestions([s("  ")])).toEqual([]);
  });
});

describe("matchSuggestions", () => {
  const all = [s("Penjualan E-book"), s("E-book Panduan"), s("Jasa Desain"), s("Ebook Lama")];
  it("needs two characters", () => {
    expect(matchSuggestions("e", all)).toEqual([]);
  });
  it("lists names that start with the text before names that only contain it", () => {
    expect(matchSuggestions("e-b", all).map((r) => r.description)).toEqual([
      "E-book Panduan",
      "Penjualan E-book",
    ]);
  });
  it("is not case sensitive and respects the limit", () => {
    expect(matchSuggestions("JASA", all).map((r) => r.description)).toEqual(["Jasa Desain"]);
    expect(matchSuggestions("e", [], 1)).toEqual([]);
    const many = Array.from({ length: 10 }, (_, i) => s(`Barang ${i}`));
    expect(matchSuggestions("barang", many, 3)).toHaveLength(3);
  });
});

describe("exactSuggestion", () => {
  it("finds the same name regardless of case", () => {
    expect(exactSuggestion("jasa desain", [s("Jasa Desain", "7")])?.unit_price).toBe("7");
    expect(exactSuggestion("jasa", [s("Jasa Desain")])).toBeUndefined();
    expect(exactSuggestion("", [s("Jasa Desain")])).toBeUndefined();
  });
});
