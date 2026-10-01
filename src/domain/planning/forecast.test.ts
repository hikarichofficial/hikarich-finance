import { describe, expect, it } from "vitest";
import type { PlanningForecastRow } from "@/schemas/planning";
import { buildForecastGrid, parseForecastMonths } from "./forecast";

function row(
  category: string,
  kind: "revenue" | "expense",
  month: string,
  amount: string,
  source: "average_3m" | "budget" = "average_3m",
): PlanningForecastRow {
  return {
    category_id: `00000000-0000-4000-8000-00000000000${category}`,
    category_name: `Cat ${category}`,
    category_kind: kind,
    period_month: month,
    baseline_amount: amount,
    budget_amount: source === "budget" ? amount : null,
    forecast_amount: amount,
    source,
  };
}

describe("parseForecastMonths", () => {
  it("accepts 3, 6 or 12 and defaults to 6", () => {
    expect(parseForecastMonths("3")).toBe(3);
    expect(parseForecastMonths("12")).toBe(12);
    expect(parseForecastMonths("7")).toBe(6);
    expect(parseForecastMonths(undefined)).toBe(6);
  });
});

describe("buildForecastGrid", () => {
  const rows = [
    row("1", "revenue", "2026-10-01", "300000.00"),
    row("1", "revenue", "2026-11-01", "450000.00", "budget"),
    row("2", "expense", "2026-10-01", "50000.00"),
    row("2", "expense", "2026-11-01", "50000.00"),
  ];

  it("pivots rows into months and groups with exact totals", () => {
    const grid = buildForecastGrid(rows);
    expect(grid.months).toEqual(["2026-10-01", "2026-11-01"]);
    const [revenue, expense] = grid.groups;
    expect(revenue.lines[0].cells.map((c) => c.source)).toEqual(["average_3m", "budget"]);
    expect(revenue.monthTotals).toEqual(["300000.00", "450000.00"]);
    expect(revenue.total).toBe("750000.00");
    expect(expense.total).toBe("100000.00");
    expect(grid.netByMonth).toEqual(["250000.00", "400000.00"]);
    expect(grid.netTotal).toBe("650000.00");
  });

  it("is empty-safe", () => {
    const grid = buildForecastGrid([]);
    expect(grid.months).toEqual([]);
    expect(grid.groups.map((g) => g.lines.length)).toEqual([0, 0]);
    expect(grid.netTotal).toBe("0");
  });
});
