import { describe, expect, it } from "vitest";
import {
  PLAN_STATUS_FILTER_OPTIONS,
  budgetActions,
  filterBudgetRows,
  filterRevenueTargetRows,
  matchesBudgetQuery,
  matchesRevenueTargetQuery,
  parsePlanStatusFilter,
  planStatusBadge,
} from "./budgetList";
import type { BudgetRow, RevenueTargetRow } from "@/schemas/planning";

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

function targetRow(overrides: Partial<RevenueTargetRow> = {}): RevenueTargetRow {
  return {
    id: "33333333-3333-3333-3333-333333333333",
    entity_id: "22222222-2222-2222-2222-222222222222",
    name: "Target Pendapatan 2025",
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

describe("matchesRevenueTargetQuery", () => {
  it("matches the revenue target's own name, case-insensitively", () => {
    expect(matchesRevenueTargetQuery(targetRow(), "target pendapatan")).toBe(true);
    expect(matchesRevenueTargetQuery(targetRow(), "PENDAPATAN")).toBe(true);
    expect(matchesRevenueTargetQuery(targetRow(), "pemasaran")).toBe(false);
  });

  it("treats an empty query as matching everything", () => {
    expect(matchesRevenueTargetQuery(targetRow(), "  ")).toBe(true);
  });
});

describe("filterRevenueTargetRows", () => {
  it("filters by the free-text name query", () => {
    const rows = [
      targetRow({ id: "1", name: "Target Pendapatan Nasional 2025" }),
      targetRow({ id: "2", name: "Target Pendapatan Regional 2025" }),
    ];
    expect(filterRevenueTargetRows(rows, "regional").map((r) => r.id)).toEqual(["2"]);
    expect(filterRevenueTargetRows(rows, "").map((r) => r.id)).toEqual(["1", "2"]);
  });
});

describe("budgetActions", () => {
  it("a draft may be activated but not closed", () => {
    expect(budgetActions("draft")).toEqual({ canActivate: true, canClose: false });
  });

  it("an active plan may be closed but not activated again", () => {
    expect(budgetActions("active")).toEqual({ canActivate: false, canClose: true });
  });

  it("a closed plan may neither be activated nor closed again", () => {
    expect(budgetActions("closed")).toEqual({ canActivate: false, canClose: false });
  });
});
