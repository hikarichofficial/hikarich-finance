import { describe, expect, it } from "vitest";
import { AuthzError, describeAuthzError } from "./errors";
import translations from "./reasonTranslations.json";
import { translateReason } from "./translateReason";

describe("translateReason", () => {
  it("translates a fixed reason", () => {
    expect(translateReason("a payment cannot be dated in the future")).toMatch(/masa depan/i);
  });

  it("puts the database's values into the Indonesian text", () => {
    const text = translateReason("4 of the 4 periods in fiscal year 2026 are not closed yet");
    expect(text).toContain("2026");
    expect(text).toContain("4");
    expect(text).not.toMatch(/periods|fiscal year/);
  });

  it("returns null for a reason it does not know", () => {
    expect(translateReason("something nobody wrote a template for")).toBeNull();
  });

  it("keeps every placeholder of every template", () => {
    for (const [english, indonesian] of translations as [string, string][]) {
      const values = english.replace(/%%/g, "").split("%").length - 1;
      const used = new Set(indonesian.match(/\{\d+\}/g) ?? []);
      expect(used.size, english).toBe(values);
    }
  });
});

describe("describeAuthzError", () => {
  it("shows the Indonesian reason alone when it is known", () => {
    const error = new AuthzError("INVALID", "INVALID: a payment cannot be dated in the future");
    expect(describeAuthzError(error)).not.toMatch(/cannot/);
    expect(describeAuthzError(error)).toMatch(/masa depan/i);
  });

  it("falls back to the generic text with the original reason", () => {
    const error = new AuthzError("CONFLICT", "CONFLICT: something nobody wrote a template for");
    expect(describeAuthzError(error)).toContain("(something nobody wrote a template for)");
  });

  it("never shows a reason for other codes", () => {
    expect(describeAuthzError(new AuthzError("FORBIDDEN", "FORBIDDEN: missing tax.view"))).toBe(
      "Anda tidak memiliki izin untuk tindakan ini.",
    );
  });
});
