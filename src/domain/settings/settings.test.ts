import { describe, expect, it } from "vitest";
import { numberingScopeSchema } from "@/schemas/settings";
import {
  NUMBERING_SCOPE_LABELS,
  entitySettingLabel,
  entitySettingValueText,
  monthName,
  numberingExample,
} from "./settings";

describe("numberingExample", () => {
  it("builds prefix, separator, year and padded counter like the database", () => {
    expect(
      numberingExample({ prefix: "INV", separator: "-", include_year: true, padding: 4 }, 2026),
    ).toBe("INV-2026-0001");
  });

  it("omits the year part when the sequence does not include it", () => {
    expect(
      numberingExample({ prefix: "JV", separator: "/", include_year: false, padding: 6 }, 2026),
    ).toBe("JV/000001");
  });

  it("supports an empty separator", () => {
    expect(
      numberingExample({ prefix: "BL", separator: "", include_year: true, padding: 3 }, 2026),
    ).toBe("BL2026001");
  });
});

describe("labels", () => {
  it("labels every numbering scope", () => {
    for (const scope of numberingScopeSchema.options) {
      expect(NUMBERING_SCOPE_LABELS[scope]).toBeTruthy();
    }
  });

  it("names months 1-12 and falls back for anything else", () => {
    expect(monthName(1)).toBe("Januari");
    expect(monthName(12)).toBe("Desember");
    expect(monthName(13)).toBe("13");
  });

  it("labels known setting keys and shows unknown ones raw", () => {
    expect(entitySettingLabel("security.require_mfa")).toContain("MFA");
    expect(entitySettingLabel("custom.key")).toBe("custom.key");
    expect(entitySettingLabel("toString")).toBe("toString");
  });
});

describe("entitySettingValueText", () => {
  it("renders booleans, numbers, strings and JSON", () => {
    expect(entitySettingValueText(true)).toBe("Ya");
    expect(entitySettingValueText(false)).toBe("Tidak");
    expect(entitySettingValueText(3)).toBe("3");
    expect(entitySettingValueText("abc")).toBe("abc");
    expect(entitySettingValueText({ a: 1 })).toBe('{"a":1}');
    expect(entitySettingValueText(undefined)).toBe("—");
  });
});
