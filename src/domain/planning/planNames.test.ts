import { describe, expect, it } from "vitest";
import { planNameSuggestions } from "./planNames";

describe("planNameSuggestions", () => {
  it("offers the names used before ahead of the generated ones", () => {
    const names = planNameSuggestions("budget", 2026, ["Anggaran Operasional 2025"]);
    expect(names[0]).toBe("Anggaran Operasional 2025");
    expect(names).toContain("Anggaran Tahunan 2026");
  });

  it("leads with the shape that matches the chosen period type", () => {
    expect(planNameSuggestions("budget", 2026, [], "monthly")[0]).toBe("Anggaran Bulanan 2026");
    expect(planNameSuggestions("budget", 2026, [], "annual")[0]).toBe("Anggaran Tahunan 2026");
    expect(planNameSuggestions("budget", 2026, [], "custom")[0]).toBe("Anggaran Kuartal I 2026");
  });

  it("names a revenue target after itself, not after a budget", () => {
    const names = planNameSuggestions("revenue_target", 2026);
    expect(names).toContain("Target Pendapatan Tahunan 2026");
    expect(names.some((name) => name.startsWith("Anggaran"))).toBe(false);
  });

  it("never repeats a name, whatever its casing or spacing", () => {
    const names = planNameSuggestions("budget", 2026, ["  anggaran tahunan 2026  ", ""]);
    const seen = names.map((name) => name.toLowerCase());
    expect(new Set(seen).size).toBe(seen.length);
    expect(names).not.toContain("");
  });
});
