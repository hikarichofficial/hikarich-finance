import { Decimal, sumDecimals } from "@/domain/money/decimal";
import type { ForecastSource, PlanningForecastRow } from "@/schemas/planning";

/**
 * Forecasts screen (decision 250, OWNER answer to decision 139). The database computes every figure
 * (`get_planning_forecast`: the 3-month average baseline, replaced by the chosen budget where it plans);
 * this module only pivots the rows into a category x month grid and sums them exactly.
 */

export const FORECAST_MONTH_OPTIONS = [3, 6, 12] as const;
export const DEFAULT_FORECAST_MONTHS = 6;

export function parseForecastMonths(value: string | undefined): number {
  const n = Number(value);
  return (FORECAST_MONTH_OPTIONS as readonly number[]).includes(n) ? n : DEFAULT_FORECAST_MONTHS;
}

export const FORECAST_SOURCE_LABELS: Readonly<Record<ForecastSource, string>> = {
  average_3m: "Rata-rata 3 bulan",
  budget: "Anggaran",
};

export interface ForecastCell {
  month: string;
  amount: string;
  source: ForecastSource;
}

export interface ForecastLine {
  categoryId: string;
  name: string;
  cells: ForecastCell[];
  total: string;
}

export interface ForecastGroup {
  kind: "revenue" | "expense";
  label: string;
  lines: ForecastLine[];
  monthTotals: string[];
  total: string;
}

export interface ForecastGrid {
  months: string[];
  groups: ForecastGroup[];
  /** Revenue minus expense per month, and overall. */
  netByMonth: string[];
  netTotal: string;
}

const GROUP_LABELS = { revenue: "Pendapatan", expense: "Beban" } as const;

export function buildForecastGrid(rows: readonly PlanningForecastRow[]): ForecastGrid {
  const months = [...new Set(rows.map((r) => r.period_month))].sort();
  const groups: ForecastGroup[] = (["revenue", "expense"] as const).map((kind) => {
    const byCategory = new Map<string, { name: string; cells: Map<string, ForecastCell> }>();
    for (const r of rows) {
      if (r.category_kind !== kind) continue;
      const entry = byCategory.get(r.category_id) ?? { name: r.category_name, cells: new Map() };
      entry.cells.set(r.period_month, {
        month: r.period_month,
        amount: r.forecast_amount,
        source: r.source,
      });
      byCategory.set(r.category_id, entry);
    }
    const lines: ForecastLine[] = [...byCategory.entries()].map(([categoryId, entry]) => {
      const cells = months.map(
        (month) =>
          entry.cells.get(month) ?? { month, amount: "0", source: "average_3m" as ForecastSource },
      );
      return {
        categoryId,
        name: entry.name,
        cells,
        total: sumDecimals(cells.map((c) => Decimal.parse(c.amount))).toString(),
      };
    });
    const monthTotals = months.map((_, i) =>
      sumDecimals(lines.map((l) => Decimal.parse(l.cells[i].amount))).toString(),
    );
    return {
      kind,
      label: GROUP_LABELS[kind],
      lines,
      monthTotals,
      total: sumDecimals(monthTotals.map((t) => Decimal.parse(t))).toString(),
    };
  });
  const [revenue, expense] = groups;
  const netByMonth = months.map((_, i) =>
    Decimal.parse(revenue.monthTotals[i]).sub(Decimal.parse(expense.monthTotals[i])).toString(),
  );
  return {
    months,
    groups,
    netByMonth,
    netTotal: Decimal.parse(revenue.total).sub(Decimal.parse(expense.total)).toString(),
  };
}
