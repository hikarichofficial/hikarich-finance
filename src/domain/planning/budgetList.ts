import { PLAN_STATUS_LABELS, type PlanStatus } from "@/domain/planning/planning";
import type { BudgetRow } from "@/schemas/planning";

/**
 * Budget Register/Detail list/detail support (P13 Part 3h, second increment, Step 09 §18: "Budget/Target
 * screens use period-based editable planning tables with Actual vs Budget/Target comparisons"). Mirrors the
 * same Standard List Screen Pattern already used across Part 3: `list_budgets` already filters status
 * server-side (its own `p_status`), so only a free-text name search is client-side here.
 */

export type BudgetListTone = "neutral" | "progress" | "attention" | "success" | "critical";
export interface BudgetListBadge {
  text: string;
  tone: BudgetListTone;
}

/** `draft` is still being shaped (neutral); `active` is the one a screen compares Actual against (success);
 * `closed` is terminal (neutral), the same three-tone shape as Loan/Recurring-rule statuses. */
const PLAN_STATUS_TONE: Readonly<Record<PlanStatus, BudgetListTone>> = {
  draft: "neutral",
  active: "success",
  closed: "neutral",
};
export function planStatusBadge(status: PlanStatus): BudgetListBadge {
  return { text: PLAN_STATUS_LABELS[status], tone: PLAN_STATUS_TONE[status] };
}

export interface PlanStatusFilterOption {
  value: PlanStatus | null;
  label: string;
}
export const PLAN_STATUS_FILTER_OPTIONS: readonly PlanStatusFilterOption[] = [
  { value: null, label: "Semua Status" },
  ...(Object.entries(PLAN_STATUS_LABELS) as [PlanStatus, string][]).map(([value, label]) => ({
    value,
    label,
  })),
];
export function parsePlanStatusFilter(value: string | undefined): PlanStatus | undefined {
  const known = Object.keys(PLAN_STATUS_LABELS) as PlanStatus[];
  return value !== undefined && (known as string[]).includes(value)
    ? (value as PlanStatus)
    : undefined;
}

export function matchesBudgetQuery(row: BudgetRow, query: string): boolean {
  const q = query.trim().toLowerCase();
  if (!q) return true;
  return row.name.toLowerCase().includes(q);
}
export function filterBudgetRows(rows: readonly BudgetRow[], query: string): BudgetRow[] {
  return rows.filter((row) => matchesBudgetQuery(row, query));
}
