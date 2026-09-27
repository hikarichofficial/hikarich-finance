import { PLAN_STATUS_LABELS, type PlanStatus } from "@/domain/planning/planning";
import type { BudgetRow, RevenueTargetRow } from "@/schemas/planning";

/**
 * Budget and Revenue Target Register/Detail list/detail support (P13 Part 3h, second and third increments,
 * Step 09 §18: "Budget/Target screens use period-based editable planning tables with Actual vs Budget/Target
 * comparisons"). Mirrors the same Standard List Screen Pattern already used across Part 3: `list_budgets`/
 * `list_revenue_targets` already filter status server-side (their own `p_status`), so only a free-text name
 * search is client-side here. `BudgetRow` and `RevenueTargetRow` share the identical `PlanStatus`/
 * `PlanPeriodType` shape (decision 184), so the badge/filter-option/status-parse helpers below are genuinely
 * shared, not just similarly shaped -- kept in this one file rather than duplicated for Revenue Targets.
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

/** Whether a Budget or Revenue Target may currently be activated or closed, for disabling screen actions
 * before a command round-trip. Both share `PlanStatus` (decision 184) and both pairs of RPCs enforce the
 * identical draft-only-activate / active-only-close rule (`activate_budget`/`close_budget`,
 * `activate_revenue_target`/`close_revenue_target`), so one helper covers both -- the same "genuinely shared,
 * not just similarly shaped" reasoning as the badge/filter helpers above. The database re-checks this itself;
 * this is presentation only. */
export function budgetActions(status: PlanStatus): { canActivate: boolean; canClose: boolean } {
  return {
    canActivate: status === "draft",
    canClose: status === "active",
  };
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

/** Same free-text name search as `matchesBudgetQuery`/`filterBudgetRows`, kept as its own named pair (rather
 * than one function typed over both rows) since `BudgetRow` and `RevenueTargetRow` are separate schema types
 * even though their shape matches. */
export function matchesRevenueTargetQuery(row: RevenueTargetRow, query: string): boolean {
  const q = query.trim().toLowerCase();
  if (!q) return true;
  return row.name.toLowerCase().includes(q);
}
export function filterRevenueTargetRows(
  rows: readonly RevenueTargetRow[],
  query: string,
): RevenueTargetRow[] {
  return rows.filter((row) => matchesRevenueTargetQuery(row, query));
}
