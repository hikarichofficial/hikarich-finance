import {
  PAYROLL_PAYMENT_STATUS_LABELS,
  PAYROLL_STATUS_LABELS,
  payrollPeriodName,
  type PayrollPaymentStatus,
  type PayrollStatus,
} from "@/domain/payroll/payroll";
import type { PayrollRunRow } from "@/schemas/payroll";

/**
 * Pure helpers for the Payroll Run Register (List) and Payroll Run Detail (P13 Part 3g, second increment,
 * Step 09 §17's own period -> employees -> calculation -> review -> approval -> post/pay -> close wizard).
 * This increment ships the List+Detail read surface only, the same "List+Detail before secondary/action
 * screens" precedent decision 164 set for every other Part 3 family: `calculatePayrollRun`/`submitPayrollRun`/
 * `approvePayrollRun`/`postPayrollRun`/`recordPayrollPayment`/`closePayrollRun`/etc. (`src/services/payroll/
 * payroll.ts`, all already service-wrapped from P9) get no UI here, the same boundary every other Part 3
 * Register screen's first increment drew for its own create/edit/approve forms. Nothing here calls the
 * database: `listPayrollRuns`/`getPayrollRun`/`getPayrollLines`/`listPayrollAdjustments`/`listPayrollPayments`
 * already carry everything these functions need. Status vocabulary itself (`PayrollStatus`,
 * `PAYROLL_STATUS_LABELS`, `payrollPeriodName`) stays in `@/domain/payroll/payroll` since it does not depend on
 * either screen's own row shape; this module only adds the List/Detail-specific status badge and filters on
 * top of it, the same split `employeeList.ts` draws against `payroll.ts` for Employee Register/Detail.
 */

export type PayrollRunListTone = "neutral" | "progress" | "attention" | "success" | "critical";

export interface PayrollRunListBadge {
  text: string;
  tone: PayrollRunListTone;
}

/** `draft`/`calculated`/`submitted`/`approved`/`partially_paid` are all still in motion (progress); `posted`/
 * `paid`/`closed` are settled outcomes (success); `corrected` flags that a later run reversed this one
 * (attention, not failure -- the correction itself is a normal, recorded workflow step); `discarded` is the
 * only status nothing further happens to (critical), the same "cancelled/void reads as neutral-terminal,
 * discarded reads as critical-terminal" split `obligationStatusBadge`'s own `void`/`open`-overdue tones draw. */
export const PAYROLL_RUN_STATUS_TONE: Readonly<Record<PayrollStatus, PayrollRunListTone>> = {
  draft: "neutral",
  calculated: "progress",
  submitted: "progress",
  approved: "progress",
  posted: "success",
  partially_paid: "progress",
  paid: "success",
  closed: "success",
  corrected: "attention",
  discarded: "critical",
};

export function payrollRunStatusBadge(status: PayrollStatus): PayrollRunListBadge {
  return { text: PAYROLL_STATUS_LABELS[status], tone: PAYROLL_RUN_STATUS_TONE[status] };
}

export interface PayrollRunStatusFilterOption {
  value: PayrollStatus | null;
  label: string;
}

/** `payroll_run_list`'s own filter is `p_status` -- sent straight through (server-side filtering, the same
 * shape every other Part 3 Register screen's own status filter takes), unlike Employee Register's status
 * filter which stayed client-side because `employee_list` has no status argument at all. */
export const PAYROLL_RUN_STATUS_FILTER_OPTIONS: readonly PayrollRunStatusFilterOption[] = [
  { value: null, label: "Semua Status" },
  ...(Object.entries(PAYROLL_STATUS_LABELS) as [PayrollStatus, string][]).map(([value, label]) => ({
    value,
    label,
  })),
];

export function parsePayrollRunStatusFilter(value: string | undefined): PayrollStatus | undefined {
  const option = PAYROLL_RUN_STATUS_FILTER_OPTIONS.find((o) => o.value === value);
  return option?.value ?? undefined;
}

function normalize(text: string): string {
  return text.trim().toLowerCase();
}

/** `?q=` is client-side, the same shape every other Part 3 List screen's own free-text filter takes: there is
 * no server argument for it on `payroll_run_list`. Matches the run number or the Indonesian period name
 * (`payrollPeriodName`, e.g. "Juli 2025"), since a payroll run carries no counterparty or code of its own. */
export function matchesPayrollRunQuery(row: PayrollRunRow, query: string): boolean {
  const needle = normalize(query);
  if (needle === "") return true;
  return (
    normalize(row.run_number).includes(needle) ||
    normalize(payrollPeriodName(row.period_start)).includes(needle)
  );
}

/** `active`/`confirmed` reads as settled (success), `reversed` flags that a later entry undid it (attention,
 * not failure) -- the exact tone split `loanPaymentStatusBadge`/`equityPaymentStatusBadge` already use for
 * their own payment status. */
const PAYROLL_PAYMENT_STATUS_TONE: Readonly<Record<PayrollPaymentStatus, PayrollRunListTone>> = {
  confirmed: "success",
  reversed: "attention",
};

export function payrollRunPaymentStatusBadge(status: PayrollPaymentStatus): PayrollRunListBadge {
  return { text: PAYROLL_PAYMENT_STATUS_LABELS[status], tone: PAYROLL_PAYMENT_STATUS_TONE[status] };
}

export function filterPayrollRunRows(
  rows: readonly PayrollRunRow[],
  query: string,
): PayrollRunRow[] {
  return rows.filter((row) => matchesPayrollRunQuery(row, query));
}
