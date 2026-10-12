import { Decimal } from "@/domain/money/decimal";
import type { TaxLedgerRow, TaxScopeRow } from "@/schemas/tax";
import { monthNameId, resolveTaxYear } from "./tax";

/**
 * Income tax recorded in the tax ledger per month of one year (every tax type except PPN), for the bars on the
 * Ringkasan Pajak. Accruals add, reversals subtract (the ledger already signs them). Returns twelve decimal
 * texts, January first; a month with nothing is "0".
 */
export function incomeTaxByMonth(rows: readonly TaxLedgerRow[], year: number): string[] {
  const totals = Array.from({ length: 12 }, () => Decimal.zero());
  for (const row of rows) {
    if (row.tax_type === "vat" || row.direction !== "payable") continue;
    const [y, m] = row.tax_period.split("-").map(Number);
    if (y !== year || m < 1 || m > 12) continue;
    totals[m - 1] = totals[m - 1].add(Decimal.parse(row.amount));
  }
  return totals.map((t) => t.toString());
}

/** Sum of the outstanding balances (a positive amount is owed). */
export function totalOutstanding(outstanding: Readonly<Record<string, string>>): string {
  return Object.values(outstanding)
    .reduce((sum, v) => sum.add(Decimal.parse(v)), Decimal.zero())
    .toString();
}

/** What the Ringkasan Pajak recap is filtered by: one month, one year or everything since the start. */
export interface TaxScope {
  kind: "month" | "year" | "all";
  /** "YYYY-MM" when `kind` is "month", else null. */
  month: string | null;
  /** The year the bars and the yearly cards show (the month's year for a month). */
  year: number;
  /** First and last tax period (first day of a month) of the range; null = no limit. */
  from: string | null;
  to: string | null;
  label: string;
}

/**
 * Reads `?scope=month|year|all`, `?month=YYYY-MM` and `?year=YYYY` of the Ringkasan Pajak. Anything missing or
 * invalid falls back to the whole current year (what the page showed before the filter existed).
 * `today` is the entity's local date as "YYYY-MM-DD".
 */
export function resolveTaxScope(
  input: { scope?: string; month?: string; year?: string },
  today: string,
): TaxScope {
  const currentYear = Number(today.slice(0, 4));
  const currentMonth = today.slice(0, 7);
  if (input.scope === "all") {
    return {
      kind: "all",
      month: null,
      year: resolveTaxYear(input.year, currentYear),
      from: null,
      to: null,
      label: "Seluruhnya sejak awal",
    };
  }
  if (input.scope === "month") {
    const m = /^(\d{4})-(\d{2})$/.exec(input.month ?? "");
    const valid =
      m !== null &&
      Number(m[1]) >= 2000 &&
      Number(m[2]) >= 1 &&
      Number(m[2]) <= 12 &&
      (input.month as string) <= currentMonth;
    const month = valid ? (input.month as string) : currentMonth;
    const [y, mo] = month.split("-").map(Number);
    return {
      kind: "month",
      month,
      year: y,
      from: `${month}-01`,
      to: `${month}-01`,
      label: `${monthNameId(mo)} ${y}`,
    };
  }
  const year = resolveTaxYear(input.year, currentYear);
  return {
    kind: "year",
    month: null,
    year,
    from: `${year}-01-01`,
    to: `${year}-12-31`,
    label: `Tahun ${year}`,
  };
}

/** Totals of the recap rows: counted, paid and what is left (a decimal text each). */
export function scopeTotals(rows: readonly TaxScopeRow[]): {
  accrued: string;
  paid: string;
  outstanding: string;
} {
  let accrued = Decimal.zero();
  let paid = Decimal.zero();
  for (const row of rows) {
    accrued = accrued.add(Decimal.parse(row.accrued));
    paid = paid.add(Decimal.parse(row.paid));
  }
  return {
    accrued: accrued.toString(),
    paid: paid.toString(),
    outstanding: accrued.sub(paid).toString(),
  };
}
