import { describe, expect, it } from "vitest";
import {
  depreciationDuePostable,
  depreciationTotals,
  filterDepreciationRows,
  matchesDepreciationQuery,
  resolveDepreciationRange,
} from "./depreciationReport";
import type { DepreciationDueRow, DepreciationLineRow } from "@/schemas/assets";

function line(overrides: Partial<DepreciationLineRow> = {}): DepreciationLineRow {
  return {
    asset_id: "11111111-1111-1111-1111-111111111111",
    asset_code: "AST-0001",
    asset_name: "Laptop Kantor",
    period_month: "2026-09-01",
    amount: "500000",
    status: "posted",
    plan_version: 1,
    journal_id: "22222222-2222-2222-2222-222222222222",
    ...overrides,
  };
}

function due(overrides: Partial<DepreciationDueRow> = {}): DepreciationDueRow {
  return {
    asset_id: "11111111-1111-1111-1111-111111111111",
    asset_code: "AST-0001",
    period_month: "2026-09-01",
    amount: "500000",
    journal_date: "2026-09-30",
    postable: true,
    ...overrides,
  };
}

describe("resolveDepreciationRange", () => {
  it("keeps a valid, non-inverted requested range", () => {
    expect(resolveDepreciationRange("2026-01-01", "2026-06-30")).toEqual({
      from: "2026-01-01",
      to: "2026-06-30",
    });
  });

  it("falls back to the trailing 12 months when either bound is missing", () => {
    const reference = new Date("2026-09-22T00:00:00Z");
    expect(resolveDepreciationRange(undefined, undefined, reference)).toEqual({
      from: "2025-09-23",
      to: "2026-09-22",
    });
    expect(resolveDepreciationRange("2026-01-01", undefined, reference)).toEqual({
      from: "2025-09-23",
      to: "2026-09-22",
    });
  });

  it("falls back to the trailing 12 months when the range is inverted", () => {
    const reference = new Date("2026-09-22T00:00:00Z");
    expect(resolveDepreciationRange("2026-06-30", "2026-01-01", reference)).toEqual({
      from: "2025-09-23",
      to: "2026-09-22",
    });
  });

  it("falls back to the trailing 12 months when a bound is not a valid ISO date", () => {
    const reference = new Date("2026-09-22T00:00:00Z");
    expect(resolveDepreciationRange("not-a-date", "2026-09-22", reference)).toEqual({
      from: "2025-09-23",
      to: "2026-09-22",
    });
  });
});

describe("matchesDepreciationQuery / filterDepreciationRows", () => {
  it("matches on asset code or name, case-insensitively", () => {
    const row = line({ asset_code: "AST-0042", asset_name: "Mesin Cetak" });
    expect(matchesDepreciationQuery(row, "")).toBe(true);
    expect(matchesDepreciationQuery(row, "ast-0042")).toBe(true);
    expect(matchesDepreciationQuery(row, "cetak")).toBe(true);
    expect(matchesDepreciationQuery(row, "tidak ada")).toBe(false);
  });

  it("filters a row set to only the matching rows", () => {
    const rows = [
      line({ asset_id: "1", asset_code: "AST-0001", asset_name: "Laptop" }),
      line({ asset_id: "2", asset_code: "AST-0002", asset_name: "Printer" }),
    ];
    expect(filterDepreciationRows(rows, "printer").map((r) => r.asset_id)).toEqual(["2"]);
    expect(filterDepreciationRows(rows, "").map((r) => r.asset_id)).toEqual(["1", "2"]);
  });
});

describe("depreciationTotals", () => {
  it("sums posted and scheduled amounts separately, ignoring reversed and cancelled lines", () => {
    const rows: DepreciationLineRow[] = [
      line({ status: "posted", amount: "500000" }),
      line({ status: "posted", amount: "250000" }),
      line({ status: "scheduled", amount: "100000" }),
      line({ status: "reversed", amount: "999999" }),
      line({ status: "cancelled", amount: "888888" }),
    ];
    const totals = depreciationTotals(rows);
    expect(totals.posted.toString()).toBe("750000");
    expect(totals.scheduled.toString()).toBe("100000");
  });

  it("returns zero totals for an empty row set", () => {
    const totals = depreciationTotals([]);
    expect(totals.posted.toString()).toBe("0");
    expect(totals.scheduled.toString()).toBe("0");
  });
});

describe("depreciationDuePostable", () => {
  it("keeps only rows the accounting period still accepts a posting for", () => {
    const rows: DepreciationDueRow[] = [
      due({ asset_id: "1", postable: true }),
      due({ asset_id: "2", postable: false }),
    ];
    expect(depreciationDuePostable(rows).map((r) => r.asset_id)).toEqual(["1"]);
  });
});
