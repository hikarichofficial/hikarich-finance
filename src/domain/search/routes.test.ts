import { describe, expect, it } from "vitest";
import { searchTargetTypeSchema } from "@/schemas/search";
import { searchResultHref } from "./routes";

const TARGET_ID = "00000000-0000-0000-0000-000000000001";

describe("searchResultHref", () => {
  it("resolves every navigable target kind to its own Detail route", () => {
    expect(searchResultHref({ target_type: "invoice", target_id: TARGET_ID })).toBe(
      `/sales/invoices/${TARGET_ID}`,
    );
    expect(searchResultHref({ target_type: "bill", target_id: TARGET_ID })).toBe(
      `/purchases/bills/${TARGET_ID}`,
    );
    expect(searchResultHref({ target_type: "fixed_asset", target_id: TARGET_ID })).toBe(
      `/assets/${TARGET_ID}`,
    );
    expect(searchResultHref({ target_type: "loan", target_id: TARGET_ID })).toBe(
      `/assets/loans/${TARGET_ID}`,
    );
    expect(searchResultHref({ target_type: "other_obligation", target_id: TARGET_ID })).toBe(
      `/assets/obligations/${TARGET_ID}`,
    );
    expect(searchResultHref({ target_type: "equity_event", target_id: TARGET_ID })).toBe(
      `/assets/equity/${TARGET_ID}`,
    );
    expect(searchResultHref({ target_type: "journal_entry", target_id: TARGET_ID })).toBe(
      `/accounting/journal/${TARGET_ID}`,
    );
    expect(searchResultHref({ target_type: "product", target_id: TARGET_ID })).toBe(
      `/sales/products/${TARGET_ID}`,
    );
  });

  it("returns null for the two kinds with no Detail screen yet, never a guessed route", () => {
    expect(searchResultHref({ target_type: "contact", target_id: TARGET_ID })).toBeNull();
    expect(searchResultHref({ target_type: "expense", target_id: TARGET_ID })).toBeNull();
  });

  it("handles every kind Global Search can actually return (no silent fall-through)", () => {
    for (const kind of searchTargetTypeSchema.options) {
      expect(() => searchResultHref({ target_type: kind, target_id: TARGET_ID })).not.toThrow();
    }
  });
});
