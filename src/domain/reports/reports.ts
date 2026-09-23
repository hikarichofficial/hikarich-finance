import { Decimal } from "@/domain/money/decimal";

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
