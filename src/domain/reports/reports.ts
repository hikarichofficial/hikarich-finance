import { Decimal, sumDecimals } from "@/domain/money/decimal";

/**
 * Presentation rules for the canonical financial statements and reporting screens (P12, Step 12 §3-§5,
 * §15, §19). The database never encodes a per-account sign convention into a statement RPC -- every one of
 * them (`profit_and_loss`, `balance_sheet`, `statement_of_changes_in_equity`) returns the account's raw
 * debit/credit movement, exactly like `trial_balance` (Step 13 §25). This module is the single place that
 * turns that pair into the "natural, positive reading" a statement actually displays, applied once instead
 * of duplicated per statement (the P12 migration's own comment: "a presentation rule ... never duplicated
 * per statement here"). Nothing here is authoritative; the database's debit/credit pair always is.
 */

export type AccountClass =
  | "asset"
  | "contra_asset"
  | "liability"
  | "equity"
  | "revenue"
  | "contra_revenue"
  | "expense"
  | "other_income"
  | "other_expense"
  | "other"
  | "tax"
  | "special";

export type NormalBalance = "debit" | "credit";

/** Mirrors the exact case in `app_private.provision_default_coa` (20260919100500_p1_accounting_core.sql)
 * that stamps every account's `normal_balance` at creation time: asset/expense/other_expense/other/tax/
 * special/contra_revenue run debit-normal; everything else (contra_asset/liability/equity/revenue/
 * other_income) runs credit-normal. Kept here (not read off the account row) because the statement RPCs
 * return `account_class`, not `normal_balance` -- duplicating the same case, once, is cheaper than a second
 * round trip and the two can never drift since both read the same locked COA architecture (Step 03). */
export const ACCOUNT_CLASS_NORMAL_BALANCE: Readonly<Record<AccountClass, NormalBalance>> = {
  asset: "debit",
  contra_asset: "credit",
  liability: "credit",
  equity: "credit",
  revenue: "credit",
  contra_revenue: "debit",
  expense: "debit",
  other_income: "credit",
  other_expense: "debit",
  other: "debit",
  tax: "debit",
  special: "debit",
};

export const ACCOUNT_CLASS_LABELS: Readonly<Record<AccountClass, string>> = {
  asset: "Aset",
  contra_asset: "Kontra Aset",
  liability: "Liabilitas",
  equity: "Ekuitas",
  revenue: "Pendapatan",
  contra_revenue: "Kontra Pendapatan",
  expense: "Beban",
  other_income: "Pendapatan Lain-lain",
  other_expense: "Beban Lain-lain",
  other: "Lainnya",
  tax: "Pajak",
  special: "Khusus",
};

/**
 * A debit/credit pair -> the account's natural-direction signed amount: positive when the account carries
 * the balance its class normally does, negative when it runs the "wrong way" (an overdrawn asset, a
 * supplier credit balance on a normally-debit account, and so on -- a real, displayable state, never
 * clamped away). Pure subtraction in the direction `ACCOUNT_CLASS_NORMAL_BALANCE` names; never rounds or
 * reinterprets the underlying figures.
 */
export function naturalAmount(debit: string, credit: string, accountClass: AccountClass): Decimal {
  const d = Decimal.parse(debit);
  const c = Decimal.parse(credit);
  return ACCOUNT_CLASS_NORMAL_BALANCE[accountClass] === "debit" ? d.sub(c) : c.sub(d);
}

export type CashFlowBucket =
  "opening_cash" | "operating" | "investing" | "financing" | "closing_cash";

export const CASH_FLOW_BUCKET_LABELS: Readonly<Record<CashFlowBucket, string>> = {
  opening_cash: "Kas Awal",
  operating: "Operasi",
  investing: "Investasi",
  financing: "Pendanaan",
  closing_cash: "Kas Akhir",
};

/** Display order for the Cash Flow Statement (opening first, the three flow buckets in the conventional
 * order, closing last) -- the RPC's own row order already follows this, this exists for a screen building
 * its own layout from a map keyed by bucket instead of relying on array order. */
export const CASH_FLOW_BUCKET_ORDER: readonly CashFlowBucket[] = [
  "opening_cash",
  "operating",
  "investing",
  "financing",
  "closing_cash",
];

export type ReportDatasetKey = "invoices_by_customer" | "bills_by_vendor" | "expenses_by_payee";

/** Whether a fiscal year closure is still in force (not yet reversed) -- `reversed_at` is the database's
 * own source of truth; this is only a readable name for the same check a screen would otherwise repeat. */
export function isFiscalYearClosureActive(closure: { reversed_at: string | null }): boolean {
  return closure.reversed_at === null;
}

// ================================================================ statement viewer screens (P13 Part 4)

const ISO_DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/;

function toIsoDate(date: Date): string {
  return date.toISOString().slice(0, 10);
}

export interface ReportDateRange {
  from: string;
  to: string;
}

/** P&L/Equity/Cash Flow's own date-range filter, same fallback shape as `resolveActivityRange` (money) and
 * `resolveDashboardPeriod` (dashboard): an invalid, missing or inverted pair falls back to a default rather
 * than erroring, since these are read-only report filters, not a form the person must correct. The default
 * here is year-to-date (Jan 1 of `reference`'s UTC year through `reference`'s own UTC date) rather than a
 * trailing window -- the reading a person actually wants when they first open a financial statement. */
export function resolveReportRange(
  requestedFrom: string | undefined,
  requestedTo: string | undefined,
  reference: Date = new Date(),
): ReportDateRange {
  const validFrom =
    requestedFrom && ISO_DATE_PATTERN.test(requestedFrom) ? requestedFrom : undefined;
  const validTo = requestedTo && ISO_DATE_PATTERN.test(requestedTo) ? requestedTo : undefined;
  if (validFrom && validTo && validFrom <= validTo) {
    return { from: validFrom, to: validTo };
  }
  const to = toIsoDate(reference);
  const from = `${reference.getUTCFullYear()}-01-01`;
  return { from, to };
}

/** Balance Sheet's `as_of` filter: an invalid or missing value falls back to `reference`'s own UTC date,
 * matching the RPC's own `coalesce(p_as_of, current_date)` default. */
export function resolveAsOfDate(
  requested: string | undefined,
  reference: Date = new Date(),
): string {
  return requested && ISO_DATE_PATTERN.test(requested) ? requested : toIsoDate(reference);
}

interface StatementRow {
  account_id: string;
  code: string;
  name: string;
  account_class: AccountClass;
  debit: string;
  credit: string;
}

export interface StatementSectionRow<T extends StatementRow> {
  row: T;
  amount: Decimal;
}

export interface StatementSection<T extends StatementRow> {
  accountClass: AccountClass;
  label: string;
  rows: readonly StatementSectionRow<T>[];
  subtotal: Decimal;
}

/** Groups a canonical statement's rows (Profit & Loss or Balance Sheet -- both return one row per posting
 * account with a `debit`/`credit` pair) into one section per `account_class`, in the fixed order the caller
 * names, each row's natural-direction amount computed once via `naturalAmount`. A class with no rows in this
 * result is left out entirely rather than shown as an empty section. */
export function groupByAccountClass<T extends StatementRow>(
  rows: readonly T[],
  order: readonly AccountClass[],
): StatementSection<T>[] {
  const sections: StatementSection<T>[] = [];
  for (const accountClass of order) {
    const classRows = rows.filter((r) => r.account_class === accountClass);
    if (classRows.length === 0) continue;
    const sectionRows = classRows.map((row) => ({
      row,
      amount: naturalAmount(row.debit, row.credit, row.account_class),
    }));
    sections.push({
      accountClass,
      label: ACCOUNT_CLASS_LABELS[accountClass],
      rows: sectionRows,
      subtotal: sumDecimals(sectionRows.map((r) => r.amount)),
    });
  }
  return sections;
}

/** Section order for the Profit & Loss statement (Step 12 §3, Table 2): income-side classes first, then
 * cost-side classes, in the same class list the `profit_and_loss` RPC itself selects on. */
export const PNL_SECTION_ORDER: readonly AccountClass[] = [
  "revenue",
  "contra_revenue",
  "other_income",
  "expense",
  "other_expense",
  "other",
  "tax",
];

/** The credit-normal classes a Profit & Loss can return (Step 12 §3): their natural amount is genuine
 * income, added toward net income. Every other P&L class (`contra_revenue`, `expense`, `other_expense`,
 * `other`, `tax`) is debit-normal and subtracted -- exactly the `v_pl_net := v_pl_credit - v_pl_debit`
 * derivation `balance_sheet`'s and `statement_of_changes_in_equity`'s own "Current Year Earnings"/"Net
 * result for the period" computed rows already use (20260930200100_p12_financial_statements.sql), kept in
 * step with those here rather than re-summing raw debit/credit independently. */
const PNL_INCOME_CLASSES: readonly AccountClass[] = ["revenue", "other_income"];

/** Net income/loss for a Profit & Loss result: the sum of every credit-normal class's natural amount minus
 * every debit-normal class's natural amount -- algebraically identical to the database's own
 * `sum(credit) - sum(debit)` across every P&L-class row (see `PNL_INCOME_CLASSES`'s comment), so this figure
 * always reconciles to the Balance Sheet's "Current Year Earnings" and the Equity Statement's "Net result
 * for the period" for the same period. */
export function pnlNetIncome(
  rows: readonly { debit: string; credit: string; account_class: AccountClass }[],
): Decimal {
  const income = sumDecimals(
    rows
      .filter((r) => PNL_INCOME_CLASSES.includes(r.account_class))
      .map((r) => naturalAmount(r.debit, r.credit, r.account_class)),
  );
  const cost = sumDecimals(
    rows
      .filter((r) => !PNL_INCOME_CLASSES.includes(r.account_class))
      .map((r) => naturalAmount(r.debit, r.credit, r.account_class)),
  );
  return income.sub(cost);
}

/** Section order for the Balance Sheet (Step 12 §4, Table 2): assets first (asset net of its contra-asset
 * class), then liabilities and equity. */
export const BALANCE_SHEET_SECTION_ORDER: readonly AccountClass[] = [
  "asset",
  "contra_asset",
  "liability",
  "equity",
];

const BALANCE_SHEET_ASSET_CLASSES: readonly AccountClass[] = ["asset", "contra_asset"];

export interface BalanceSheetTotals {
  assets: Decimal;
  liabilitiesAndEquity: Decimal;
  balanced: boolean;
}

/** Total Assets vs. Total Liabilities & Equity, and whether they agree -- a Balance Sheet built from posted,
 * balanced double-entry journals always reconciles; this is a display-only check, never a correction. */
export function balanceSheetTotals(
  rows: readonly { debit: string; credit: string; account_class: AccountClass }[],
): BalanceSheetTotals {
  const assets = sumDecimals(
    rows
      .filter((r) => BALANCE_SHEET_ASSET_CLASSES.includes(r.account_class))
      .map((r) => naturalAmount(r.debit, r.credit, r.account_class)),
  );
  const liabilitiesAndEquity = sumDecimals(
    rows
      .filter((r) => !BALANCE_SHEET_ASSET_CLASSES.includes(r.account_class))
      .map((r) => naturalAmount(r.debit, r.credit, r.account_class)),
  );
  return { assets, liabilitiesAndEquity, balanced: assets.eq(liabilitiesAndEquity) };
}

/** Statement of Changes in Equity: every row (including the computed "Net result for the period" row,
 * `account_id: null`) is equity-normal (credit-normal) by construction (Step 12 §4's schema comment), so its
 * natural opening/period/closing amounts are always `credit - debit` -- there is no `account_class` on this
 * row shape to look up (`@/schemas/reports`'s `equityChangeRowSchema`). */
export function equityRowAmounts(row: {
  opening_debit: string;
  opening_credit: string;
  period_debit: string;
  period_credit: string;
  closing_debit: string;
  closing_credit: string;
}): { opening: Decimal; period: Decimal; closing: Decimal } {
  return {
    opening: Decimal.parse(row.opening_credit).sub(Decimal.parse(row.opening_debit)),
    period: Decimal.parse(row.period_credit).sub(Decimal.parse(row.period_debit)),
    closing: Decimal.parse(row.closing_credit).sub(Decimal.parse(row.closing_debit)),
  };
}

/** Total closing equity across every row -- reconciles to the Balance Sheet's own Total Equity as of the
 * same date (both derive from the same posted ledger, never a second computation of the same fact). */
export function equityClosingTotal(
  rows: readonly Parameters<typeof equityRowAmounts>[0][],
): Decimal {
  return sumDecimals(rows.map((r) => equityRowAmounts(r).closing));
}

export interface CashFlowTotals {
  opening: Decimal;
  operating: Decimal;
  investing: Decimal;
  financing: Decimal;
  closing: Decimal;
  reconciled: boolean;
}

/** Reads the fixed five buckets out of a `cash_flow_statement` result (a bucket absent from the RPC's
 * result, because nothing posted to it in range, reads as zero) and checks that opening + the three flow
 * buckets equal closing -- true by construction of the RPC's own direct-method sums, shown here only as a
 * display-only reconciliation, same spirit as `balanceSheetTotals`. */
export function cashFlowTotals(
  rows: readonly { bucket: CashFlowBucket; amount: string }[],
): CashFlowTotals {
  const byBucket = new Map(rows.map((r) => [r.bucket, Decimal.parse(r.amount)]));
  const at = (bucket: CashFlowBucket) => byBucket.get(bucket) ?? Decimal.zero();
  const opening = at("opening_cash");
  const operating = at("operating");
  const investing = at("investing");
  const financing = at("financing");
  const closing = at("closing_cash");
  const expectedClosing = opening.add(operating).add(investing).add(financing);
  return {
    opening,
    operating,
    investing,
    financing,
    closing,
    reconciled: expectedClosing.eq(closing),
  };
}
