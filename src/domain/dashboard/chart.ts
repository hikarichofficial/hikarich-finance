import { Decimal } from "@/domain/money/decimal";
import { naturalAmount, type AccountClass } from "@/domain/reports/reports";
import type { ProfitAndLossRow } from "@/schemas/reports";

/**
 * Presentation helpers for the Dashboard / Tax charts. A chart only positions pixels: the exact figures
 * shown to the person are always the decimal text the database produced, formatted by `formatMoney`.
 * `Number(...)` below is used for heights, shares and compact axis labels only, never for a financial result.
 */

/** "12,5 jt", "1,2 M", "850 rb": a short axis label. Display only. */
export function compactNumber(value: number): string {
  const abs = Math.abs(value);
  const sign = value < 0 ? "-" : "";
  const fmt = (n: number, unit: string) =>
    `${sign}${(Math.round(n * 10) / 10).toString().replace(".", ",")} ${unit}`;
  if (abs >= 1e12) return fmt(abs / 1e12, "T");
  if (abs >= 1e9) return fmt(abs / 1e9, "M");
  if (abs >= 1e6) return fmt(abs / 1e6, "jt");
  if (abs >= 1e3) return fmt(abs / 1e3, "rb");
  return `${sign}${Math.round(abs)}`;
}

/** Percent change from one month to the next, `null` when there is no meaningful base. */
export function percentChange(previous: string | null, current: string | null): number | null {
  if (previous === null || current === null) return null;
  const p = Number(previous);
  const c = Number(current);
  if (!Number.isFinite(p) || !Number.isFinite(c) || p === 0) return null;
  return ((c - p) / Math.abs(p)) * 100;
}

export function formatPercent(value: number): string {
  const rounded = Math.round(value);
  return `${rounded > 0 ? "+" : ""}${rounded}%`;
}

export interface BreakdownItem {
  name: string;
  amount: string;
  /** 0..100, the item's share of the shown total. */
  share: number;
}

const REVENUE_CLASSES: readonly AccountClass[] = ["revenue", "other_income"];
const EXPENSE_CLASSES: readonly AccountClass[] = ["expense", "other_expense"];

/**
 * The biggest accounts of one side of a profit-and-loss result (largest first), the rest folded into
 * "Lainnya". Zero and negative accounts are left out of the bars; the total stays the report's own.
 */
export function pnlBreakdown(
  rows: readonly ProfitAndLossRow[],
  side: "revenue" | "expense",
  top = 5,
): BreakdownItem[] {
  const classes = side === "revenue" ? REVENUE_CLASSES : EXPENSE_CLASSES;
  const items = rows
    .filter((r) => classes.includes(r.account_class))
    .map((r) => ({ name: r.name, amount: naturalAmount(r.debit, r.credit, r.account_class) }))
    .filter((r) => r.amount.isPositive())
    .sort((a, b) => b.amount.cmp(a.amount));
  if (items.length === 0) return [];
  const total = items.reduce((sum, r) => sum.add(r.amount), Decimal.zero());
  const totalNumber = Number(total.toString());
  const shown = items.slice(0, top);
  const rest = items.slice(top);
  if (rest.length > 0) {
    shown.push({
      name: "Lainnya",
      amount: rest.reduce((sum, r) => sum.add(r.amount), Decimal.zero()),
    });
  }
  return shown.map((r) => ({
    name: r.name,
    amount: r.amount.toString(),
    share: totalNumber > 0 ? (Number(r.amount.toString()) / totalNumber) * 100 : 0,
  }));
}
