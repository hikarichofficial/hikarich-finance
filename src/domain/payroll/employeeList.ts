import {
  EMPLOYEE_STATUS_LABELS,
  EMPLOYMENT_TYPE_LABELS,
  type EmployeeStatus,
  type EmploymentType,
} from "@/domain/payroll/payroll";
import type { EmployeeRow } from "@/schemas/payroll";

/**
 * Pure helpers for the Employee Register (List) and Employee Detail (P13 Part 3g, first increment, Step 09
 * §9-§10, §17). Nothing here calls the database: `listEmployees`/`getEmploymentHistory`/`getCompensation`/
 * `getBpjsEnrolment`/`getTaxProfile` (`src/services/payroll/payroll.ts`) already carry everything these
 * functions need. Payroll vocabulary that does not depend on either screen's own row shape stays in
 * `@/domain/payroll/payroll` (P9, Step 05 §15, Step 12); this module only adds the List/Detail-specific status
 * badge and filters on top of it. Step 09 §17's "Employee list shows only appropriate operational fields;
 * compensation is permission-gated" is enforced by the RPC surface itself (`employee_list` never returns a
 * compensation figure, `employee_compensation_get`/`employee_bpjs_get` check the separate `payroll.compensation_view`
 * permission) -- this module adds no gating of its own, it only formats what each RPC already decided to return.
 */

export type EmployeeListTone = "neutral" | "progress" | "attention" | "success" | "critical";

export interface EmployeeListBadge {
  text: string;
  tone: EmployeeListTone;
}

export const EMPLOYEE_STATUS_TONE: Readonly<Record<EmployeeStatus, EmployeeListTone>> = {
  active: "success",
  ended: "neutral",
};

export function employeeStatusBadge(status: EmployeeStatus): EmployeeListBadge {
  return { text: EMPLOYEE_STATUS_LABELS[status], tone: EMPLOYEE_STATUS_TONE[status] };
}

export interface EmployeeStatusFilterOption {
  value: EmployeeStatus | null;
  label: string;
}

/** `employee_list`'s own filter is `p_include_ended` (a boolean, not a status enum) -- this option list is a
 * client-side refinement on top of whatever the server already included, not a second server round-trip. */
export const EMPLOYEE_STATUS_FILTER_OPTIONS: readonly EmployeeStatusFilterOption[] = [
  { value: null, label: "Semua Status" },
  ...(Object.entries(EMPLOYEE_STATUS_LABELS) as [EmployeeStatus, string][]).map(
    ([value, label]) => ({ value, label }),
  ),
];

export function parseEmployeeStatusFilter(value: string | undefined): EmployeeStatus | undefined {
  const option = EMPLOYEE_STATUS_FILTER_OPTIONS.find((o) => o.value === value);
  return option?.value ?? undefined;
}

export function matchesEmployeeStatus(row: EmployeeRow, status: EmployeeStatus | null): boolean {
  return status === null || row.status === status;
}

export interface EmploymentTypeFilterOption {
  value: EmploymentType | null;
  label: string;
}

export const EMPLOYMENT_TYPE_FILTER_OPTIONS: readonly EmploymentTypeFilterOption[] = [
  { value: null, label: "Semua Jenis" },
  ...(Object.entries(EMPLOYMENT_TYPE_LABELS) as [EmploymentType, string][]).map(
    ([value, label]) => ({ value, label }),
  ),
];

export function parseEmploymentTypeFilter(value: string | undefined): EmploymentType | undefined {
  const option = EMPLOYMENT_TYPE_FILTER_OPTIONS.find((o) => o.value === value);
  return option?.value ?? undefined;
}

export function matchesEmploymentType(
  row: EmployeeRow,
  employmentType: EmploymentType | null,
): boolean {
  return employmentType === null || row.employment_type === employmentType;
}

function normalize(text: string): string {
  return text.trim().toLowerCase();
}

/** `status` and `employmentType` are both client-side filters (decision above); only the free-text search on
 * code/name/position/department has no RPC parameter to send it to either, the same shape every other List
 * screen's own query takes. */
export function matchesEmployeeQuery(row: EmployeeRow, query: string): boolean {
  const needle = normalize(query);
  if (needle === "") return true;
  return (
    normalize(row.employee_code).includes(needle) ||
    normalize(row.full_name).includes(needle) ||
    normalize(row.position_title).includes(needle) ||
    (row.department !== null && normalize(row.department).includes(needle))
  );
}

export function filterEmployeeRows(
  rows: readonly EmployeeRow[],
  status: EmployeeStatus | null,
  employmentType: EmploymentType | null,
  query: string,
): EmployeeRow[] {
  return rows.filter(
    (row) =>
      matchesEmployeeStatus(row, status) &&
      matchesEmploymentType(row, employmentType) &&
      matchesEmployeeQuery(row, query),
  );
}
