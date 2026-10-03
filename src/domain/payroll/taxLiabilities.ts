/**
 * Pure helpers for the Payroll Tax & Liabilities screen (P13 Part 3g, fourth increment, Step 09 §17).
 * Nothing here calls the database: `getPayrollLiabilities`/`getAnnualReconciliation`/`getEmployeeTaxLedger`
 * (`src/services/payroll/payroll.ts`, already service-wrapped from P9) already carry everything this module
 * needs. This screen ships three of the five payroll report RPCs (`payroll_liability_report`,
 * `payroll_annual_reconciliation`, `payroll_employee_tax_ledger`) -- the two that most directly match the
 * nav label's own "Tax" and "Liabilities" halves; `payroll_summary_report` and `payroll_control_report` are
 * deferred to the broader Reports Architecture slice (Step 09 §19, P13 Part 5), the same "reports catalogue
 * item belongs with Part 5, not this module's own screen" precedent decision 178 already set for the Loans
 * Due/Loan Summary reports.
 */

const ISO_DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/;

function toIsoDate(date: Date): string {
  return date.toISOString().slice(0, 10);
}

/** `payroll_liability_report`'s own `p_as_of` defaults to "today" when omitted -- this mirrors that default
 * rather than picking a different one, so an empty filter and an explicit `?as_of=` of today's date behave
 * identically. */
export function resolveAsOfDate(
  requested: string | undefined,
  reference: Date = new Date(),
): string {
  if (requested && ISO_DATE_PATTERN.test(requested)) return requested;
  return toIsoDate(reference);
}

const MIN_TAX_YEAR = 2000;
const MAX_TAX_YEAR = 2100;

/** `payroll_annual_reconciliation`/`payroll_employee_tax_ledger` both require `p_year` between 2000 and 2100
 * (the RPC's own `INVALID` check) -- an out-of-range or unparseable `?year=` falls back to the current year
 * rather than being sent through and rejected. */
export function resolveTaxYear(
  requested: string | undefined,
  reference: Date = new Date(),
): number {
  const parsed = requested ? Number.parseInt(requested, 10) : NaN;
  if (Number.isInteger(parsed) && parsed >= MIN_TAX_YEAR && parsed <= MAX_TAX_YEAR) return parsed;
  return reference.getUTCFullYear();
}

export type AnnualReconciliationStatus =
  "reconciled" | "under_withheld" | "over_withheld" | "incomplete";

export const ANNUAL_RECONCILIATION_STATUS_LABELS: Readonly<
  Record<AnnualReconciliationStatus, string>
> = {
  reconciled: "Sesuai",
  under_withheld: "Kurang Potong",
  over_withheld: "Lebih Potong",
  incomplete: "Data Tidak Lengkap",
};

export type TaxLiabilitiesTone = "neutral" | "progress" | "attention" | "success" | "critical";

export interface TaxLiabilitiesBadge {
  text: string;
  tone: TaxLiabilitiesTone;
}

/** `reconciled` is the clean outcome (success); `under_withheld`/`over_withheld` both need the tax adviser's
 * attention (attention, not failure -- neither is wrongdoing, just a gap the last tax month's own computation
 * should close); `incomplete` means the rule or the employee's own tax facts are missing, a data gap rather
 * than a tax outcome (neutral). */
const ANNUAL_RECONCILIATION_STATUS_TONE: Readonly<
  Record<AnnualReconciliationStatus, TaxLiabilitiesTone>
> = {
  reconciled: "success",
  under_withheld: "attention",
  over_withheld: "attention",
  incomplete: "neutral",
};

export function annualReconciliationStatusBadge(
  status: AnnualReconciliationStatus,
): TaxLiabilitiesBadge {
  return {
    text: ANNUAL_RECONCILIATION_STATUS_LABELS[status],
    tone: ANNUAL_RECONCILIATION_STATUS_TONE[status],
  };
}

export const TAX_LEDGER_SOURCE_LABELS: Readonly<Record<"run" | "opening", string>> = {
  run: "Proses Penggajian",
  opening: "Saldo Awal",
};
