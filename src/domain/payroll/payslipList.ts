import { PAYSLIP_STATUS_LABELS, type PayslipStatus } from "@/domain/payroll/payroll";
import type { PayslipRow } from "@/schemas/payroll";

/**
 * Pure helpers for the Payslip Register (List) and Payslip Detail (P13 Part 3g, third increment, Step 09
 * §17). Nothing here calls the database: `listPayslips`/`getPayslip` (`src/services/payroll/payroll.ts`,
 * already service-wrapped from P9) already carry everything these functions need. Status vocabulary
 * (`PayslipStatus`, `PAYSLIP_STATUS_LABELS`) stays in `@/domain/payroll/payroll` since it does not depend on
 * either screen's own row shape; this module only adds the List/Detail-specific status badge and filters, the
 * same split `runList.ts`/`employeeList.ts` already draw against `payroll.ts`.
 */

export type PayslipListTone = "neutral" | "progress" | "attention" | "success" | "critical";

export interface PayslipListBadge {
  text: string;
  tone: PayslipListTone;
}

/** `voided` reads as neutral-terminal (a superseded/cancelled document, not a failure) -- the same "void/
 * cancelled reads as neutral" tone `obligationStatusBadge`'s own `void` status already uses. */
export const PAYSLIP_STATUS_TONE: Readonly<Record<PayslipStatus, PayslipListTone>> = {
  issued: "success",
  voided: "neutral",
};

export function payslipStatusBadge(status: PayslipStatus): PayslipListBadge {
  return { text: PAYSLIP_STATUS_LABELS[status], tone: PAYSLIP_STATUS_TONE[status] };
}

export interface PayslipStatusFilterOption {
  value: PayslipStatus | null;
  label: string;
}

/** `payroll_payslip_list` has no status argument at all (only `p_run`/`p_employee`/`p_limit`) -- this filter
 * stays entirely client-side, the same shape Employee Register's own status filter takes against
 * `employee_list`. */
export const PAYSLIP_STATUS_FILTER_OPTIONS: readonly PayslipStatusFilterOption[] = [
  { value: null, label: "Semua Status" },
  ...(Object.entries(PAYSLIP_STATUS_LABELS) as [PayslipStatus, string][]).map(([value, label]) => ({
    value,
    label,
  })),
];

export function parsePayslipStatusFilter(value: string | undefined): PayslipStatus | undefined {
  const option = PAYSLIP_STATUS_FILTER_OPTIONS.find((o) => o.value === value);
  return option?.value ?? undefined;
}

export function matchesPayslipStatus(row: PayslipRow, status: PayslipStatus | null): boolean {
  return status === null || row.status === status;
}

function normalize(text: string): string {
  return text.trim().toLowerCase();
}

/** `?q=` is client-side, matching the payslip number, employee code/name, or the `YYYY-MM` period. */
export function matchesPayslipQuery(row: PayslipRow, query: string): boolean {
  const needle = normalize(query);
  if (needle === "") return true;
  return (
    normalize(row.payslip_number).includes(needle) ||
    normalize(row.employee_code).includes(needle) ||
    normalize(row.employee_name).includes(needle) ||
    normalize(row.period).includes(needle)
  );
}

export function filterPayslipRows(
  rows: readonly PayslipRow[],
  status: PayslipStatus | null,
  query: string,
): PayslipRow[] {
  return rows.filter((row) => matchesPayslipStatus(row, status) && matchesPayslipQuery(row, query));
}
