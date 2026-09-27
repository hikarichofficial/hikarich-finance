import {
  RECURRING_OCCURRENCE_STATUS_LABELS,
  RECURRING_STATUS_LABELS,
  type RecurringOccurrenceStatus,
  type RecurringStatus,
} from "@/domain/planning/planning";
import type { RecurringRuleRow } from "@/schemas/planning";

/**
 * Recurring Rules Register/Detail list/detail support (P13 Part 3h, first increment, Step 09 §18: "Recurring
 * Rules list shows next run, status, frequency and generated history"). Mirrors the "Standard List Screen
 * Pattern" already used for Loans (decision 175) and Payroll Runs (decision 180): `list_recurring_rules`
 * already filters status server-side (its own `p_status`), so only a free-text label search is client-side
 * here, the same split those screens use.
 */

export type RecurringListTone = "neutral" | "progress" | "attention" | "success" | "critical";
export interface RecurringListBadge {
  text: string;
  tone: RecurringListTone;
}

/** `active` is the running state (success); `paused` is a deliberate hold that still needs the planner's
 * attention (attention, not failure -- nothing is wrong, it just will not generate until resumed); `ended` is
 * terminal and no longer actionable (neutral, like a closed loan). */
const RECURRING_STATUS_TONE: Readonly<Record<RecurringStatus, RecurringListTone>> = {
  active: "success",
  paused: "attention",
  ended: "neutral",
};
export function recurringStatusBadge(status: RecurringStatus): RecurringListBadge {
  return { text: RECURRING_STATUS_LABELS[status], tone: RECURRING_STATUS_TONE[status] };
}

export interface RecurringStatusFilterOption {
  value: RecurringStatus | null;
  label: string;
}
export const RECURRING_STATUS_FILTER_OPTIONS: readonly RecurringStatusFilterOption[] = [
  { value: null, label: "Semua Status" },
  ...(Object.entries(RECURRING_STATUS_LABELS) as [RecurringStatus, string][]).map(
    ([value, label]) => ({ value, label }),
  ),
];
export function parseRecurringStatusFilter(value: string | undefined): RecurringStatus | undefined {
  const known = Object.keys(RECURRING_STATUS_LABELS) as RecurringStatus[];
  return value !== undefined && (known as string[]).includes(value)
    ? (value as RecurringStatus)
    : undefined;
}

export function matchesRecurringQuery(row: RecurringRuleRow, query: string): boolean {
  const q = query.trim().toLowerCase();
  if (!q) return true;
  return row.label.toLowerCase().includes(q);
}
export function filterRecurringRows(
  rows: readonly RecurringRuleRow[],
  query: string,
): RecurringRuleRow[] {
  return rows.filter((row) => matchesRecurringQuery(row, query));
}

const RECURRING_OCCURRENCE_STATUS_TONE: Readonly<
  Record<RecurringOccurrenceStatus, RecurringListTone>
> = {
  generated: "success",
  failed: "critical",
};
export function recurringOccurrenceStatusBadge(
  status: RecurringOccurrenceStatus,
): RecurringListBadge {
  return {
    text: RECURRING_OCCURRENCE_STATUS_LABELS[status],
    tone: RECURRING_OCCURRENCE_STATUS_TONE[status],
  };
}
