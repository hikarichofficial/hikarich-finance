import { describe, expect, it } from "vitest";
import {
  PLAN_STATUS_FILTER_OPTIONS,
  filterBudgetRows,
  matchesBudgetQuery,
  parsePlanStatusFilter,
  planStatusBadge,
} from "./budgetList";
import type { BudgetRow } from "@/schemas/planning";

function row(overrides: Partial<BudgetRow> = {}): BudgetRow {
  return {
    id: "11111111-1111-1111-1111-111111111111",
    entity_id: "22222222-2222-2222-2222-222222222222",
    name: "Anggaran Operasional 2025",
    fiscal_year: 2025,
    period_type: "annual",
    start_date: "2025-01-01",
    end_date: "2025-12-31",
    status: "active",
    note: null,
    version: 1,
    ...overrides,
  };
}

describe("planStatusBadge", () => {
  it("returns the Indonesian label and tone for each status", () => {
    expect(planStatusBadge("draft")).toEqual({ text: "Draf", tone: "neutral" });
    expect(planStatusBadge("active")).toEqual({ text: "Aktif", tone: "success" });
    expect(planStatusBadge("closed")).toEqual({ text: "Ditutup", tone: "neutral" });
  });
});

describe("PLAN_STATUS_FILTER_OPTIONS", () => {
  it("starts with the all-status option and lists all three statuses", () => {
    expect(PLAN_STATUS_FILTER_OPTIONS[0]).toEqual({ value: null, label: "Semua Status" });
    expect(PLAN_STATUS_FILTER_OPTIONS).toHaveLength(4);
  });
});

describe("parsePlanStatusFilter", () => {
  it("parses a known status and treats anything else as no filter", () => {
    expect(parsePlanStatusFilter("closed")).toBe("closed");
    expect(parsePlanStatusFilter(undefined)).toBeUndefined();
    expect(parsePlanStatusFilter("bogus")).toBeUndefined();
  });
});

describe("matchesBudgetQuery", () => {
  it("matches the budget's own name, case-insensitively", () => {
    expect(matchesBudgetQuery(row(), "anggaran operasional")).toBe(true);
    expect(matchesBudgetQuery(row(), "OPERASIONAL")).toBe(true);
    expect(matchesBudgetQuery(row(), "pemasaran")).toBe(false);
  });

  it("treats an empty query as matching everything", () => {
    expect(matchesBudgetQuery(row(), "  ")).toBe(true);
  });
});

describe("filterBudgetRows", () => {
  it("filters by the free-text name query", () => {
    const rows = [
      row({ id: "1", name: "Anggaran Operasional 2025" }),
      row({ id: "2", name: "Anggaran Pemasaran 2025" }),
    ];
    expect(filterBudgetRows(rows, "pemasaran").map((r) => r.id)).toEqual(["2"]);
    expect(filterBudgetRows(rows, "").map((r) => r.id)).toEqual(["1", "2"]);
  });
});
