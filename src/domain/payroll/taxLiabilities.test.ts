import { describe, expect, it } from "vitest";
import {
  ANNUAL_RECONCILIATION_STATUS_LABELS,
  annualReconciliationStatusBadge,
  resolveAsOfDate,
  resolveTaxYear,
} from "./taxLiabilities";

describe("resolveAsOfDate", () => {
  it("keeps a valid ISO date", () => {
    expect(resolveAsOfDate("2025-07-15", new Date("2026-01-01T00:00:00Z"))).toBe("2025-07-15");
  });

  it("falls back to today for a missing or malformed date", () => {
    expect(resolveAsOfDate(undefined, new Date("2026-01-01T00:00:00Z"))).toBe("2026-01-01");
    expect(resolveAsOfDate("not-a-date", new Date("2026-01-01T00:00:00Z"))).toBe("2026-01-01");
  });
});

describe("resolveTaxYear", () => {
  it("keeps a valid in-range year", () => {
    expect(resolveTaxYear("2024", new Date("2026-01-01T00:00:00Z"))).toBe(2024);
  });

  it("falls back to the current year for missing, unparseable or out-of-range input", () => {
    expect(resolveTaxYear(undefined, new Date("2026-01-01T00:00:00Z"))).toBe(2026);
    expect(resolveTaxYear("bogus", new Date("2026-01-01T00:00:00Z"))).toBe(2026);
    expect(resolveTaxYear("1999", new Date("2026-01-01T00:00:00Z"))).toBe(2026);
    expect(resolveTaxYear("2101", new Date("2026-01-01T00:00:00Z"))).toBe(2026);
  });
});

describe("annualReconciliationStatusBadge", () => {
  it("returns the Indonesian label and tone for each status", () => {
    expect(annualReconciliationStatusBadge("reconciled")).toEqual({
      text: ANNUAL_RECONCILIATION_STATUS_LABELS.reconciled,
      tone: "success",
    });
    expect(annualReconciliationStatusBadge("under_withheld").tone).toBe("attention");
    expect(annualReconciliationStatusBadge("over_withheld").tone).toBe("attention");
    expect(annualReconciliationStatusBadge("incomplete").tone).toBe("neutral");
  });
});
