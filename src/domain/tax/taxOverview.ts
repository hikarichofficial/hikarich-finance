import { Decimal } from "@/domain/money/decimal";
import type { TaxLedgerRow } from "@/schemas/tax";

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
