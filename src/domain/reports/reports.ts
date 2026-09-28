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

/** The Profit & Loss comparison-period filter (Step 12 §3, `profit_and_loss`'s own `p_compare_start`/
 * `p_compare_end`, decision 189's own deferred item). Unlike `resolveReportRange`, there is no sensible
 * default comparison period to fall back to -- a P&L with no comparison requested is a completely normal,
 * common case, not a filter someone forgot to fill in -- so a missing, partial, invalid, or inverted pair
 * simply means "no comparison", returned as `undefined` rather than guessing a period. Mirrors
 * `profitAndLossInputSchema`'s own `superRefine` (`@/schemas/reports`): both dates are required together,
 * and the end must not precede the start. */
export function resolveCompareRange(
  requestedFrom: string | undefined,
  requestedTo: string | undefined,
): ReportDateRange | undefined {
  if (!requestedFrom || !requestedTo) return undefined;
  if (!ISO_DATE_PATTERN.test(requestedFrom) || !ISO_DATE_PATTERN.test(requestedTo)) {
    return undefined;
  }
  if (requestedTo < requestedFrom) return undefined;
  return { from: requestedFrom, to: requestedTo };
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

interface ComparablePnlRow {
  compare_debit: string | null;
  compare_credit: string | null;
  account_class: AccountClass;
}

/** Whether a Profit & Loss result carries a comparison period at all -- `profit_and_loss` returns
 * `compare_debit`/`compare_credit` either both `null` (no `p_compare_start` given) or both a decimal text
 * together, never one without the other (see the RPC's own `case when p_compare_start is null then null ...`
 * pair), so checking one row's `compare_debit` is enough to know the whole result. Empty `rows` (nothing
 * posted in either period) reads as "no comparison", matching `pnlCompareAmount`'s own `null`-when-absent
 * shape rather than guessing from a result with nothing to check. */
export function hasPnlComparison(rows: readonly { compare_debit: string | null }[]): boolean {
  return rows.some((r) => r.compare_debit !== null);
}

/** A P&L row's comparison-period natural amount, `null` when the row's own comparison figures are absent
 * (no comparison period was requested). Uses the same `naturalAmount` direction as the row's primary-period
 * amount, so the two are directly comparable and a variance is a plain subtraction, never a sign flip. */
export function pnlCompareAmount(row: ComparablePnlRow): Decimal | null {
  if (row.compare_debit === null || row.compare_credit === null) return null;
  return naturalAmount(row.compare_debit, row.compare_credit, row.account_class);
}

/** Comparison-period subtotal across a homogeneous set of rows (one P&L section's own rows, all sharing one
 * `account_class`, exactly how `groupByAccountClass` already sums `section.subtotal`) -- `null` when the
 * rows carry no comparison period at all, otherwise the plain sum of each row's own `pnlCompareAmount`. Only
 * safe to sum straight across rows that share one class (or are otherwise already sign-uniform); net income
 * across every P&L class needs `pnlCompareNetIncome`'s own income-minus-cost split instead. */
export function pnlCompareSubtotal(rows: readonly ComparablePnlRow[]): Decimal | null {
  if (!hasPnlComparison(rows)) return null;
  return sumDecimals(rows.map((r) => pnlCompareAmount(r) ?? Decimal.zero()));
}

/** Net income/loss for the comparison period alone, `null` when the result carries none -- mirrors
 * `pnlNetIncome` exactly (same `PNL_INCOME_CLASSES` income-minus-cost split), applied to each row's
 * `pnlCompareAmount` instead of its primary-period `naturalAmount`. */
export function pnlCompareNetIncome(rows: readonly ComparablePnlRow[]): Decimal | null {
  if (!hasPnlComparison(rows)) return null;
  const income = sumDecimals(
    rows
      .filter((r) => PNL_INCOME_CLASSES.includes(r.account_class))
      .map((r) => pnlCompareAmount(r) ?? Decimal.zero()),
  );
  const cost = sumDecimals(
    rows
      .filter((r) => !PNL_INCOME_CLASSES.includes(r.account_class))
      .map((r) => pnlCompareAmount(r) ?? Decimal.zero()),
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

// ================================================================ General Ledger drill-down (P13 Part 4, second increment)

/** The account a General Ledger card resolves to (Step 12 §3, `general_ledger`'s own comment: a specific
 * account carries a running balance; omitting it returns every posting account's lines instead, a
 * materially different shape this screen doesn't render). A missing, unknown, or group account falls back
 * to the first posting account, mirroring `resolveReportRange`/`resolveAsOfDate`'s own "always resolve to
 * something sensible, never block on a missing filter" shape -- never `null` unless the Entity genuinely
 * has no posting account yet. `accounts` is expected pre-sorted by code, `listLedgerAccounts`'s own order. */
export function resolveGeneralLedgerAccount(
  accounts: readonly { id: string; is_group: boolean }[],
  requested: string | undefined,
): string | null {
  const posting = accounts.filter((a) => !a.is_group);
  if (posting.length === 0) return null;
  if (requested && posting.some((a) => a.id === requested)) return requested;
  return posting[0].id;
}

export interface GeneralLedgerTotals {
  debit: Decimal;
  credit: Decimal;
  closingBalance: Decimal;
}

/** Period debit/credit sums plus the closing balance -- the sums are a display-only total of exactly the
 * figures already in each row, and the closing balance is simply the last row's own `running_balance`
 * (the RPC's own windowed sum, ordered `entry_date, created_at, line_no`), never a second computation. Note
 * this is the balance *within the requested range*, not a true carried-forward opening-adjusted balance --
 * `general_ledger` has no opening-balance parameter, so a `start_date` filter genuinely restarts the running
 * sum from zero at that date; this function reflects that faithfully rather than papering over it. */
export function generalLedgerTotals(
  rows: readonly { debit: string; credit: string; running_balance: string }[],
): GeneralLedgerTotals {
  const debit = sumDecimals(rows.map((r) => Decimal.parse(r.debit)));
  const credit = sumDecimals(rows.map((r) => Decimal.parse(r.credit)));
  const closingBalance =
    rows.length > 0 ? Decimal.parse(rows[rows.length - 1].running_balance) : Decimal.zero();
  return { debit, credit, closingBalance };
}

// ================================================================ Custom Report Builder (P13 Part 4, fourth increment)

/** The dataset a Custom Report Builder screen resolves to (Step 12 §19). `datasets` is expected already
 * filtered to what the caller may actually run -- the page checks each dataset's own `required_permission`
 * against the active membership (via `can`, `@/domain/authz/access`) before this ever sees them, so this
 * function never re-derives authorization, it only picks a default, mirroring
 * `resolveGeneralLedgerAccount`'s own "always resolve to something sensible" shape. A missing or unknown
 * key falls back to the first available dataset; an empty list (no dataset the caller may run) returns
 * `null`, exactly like `resolveGeneralLedgerAccount` returns `null` for an Entity with no posting account. */
export function resolveCustomReportDataset(
  datasets: readonly { dataset_key: string }[],
  requested: string | undefined,
): string | null {
  if (datasets.length === 0) return null;
  if (requested && datasets.some((d) => d.dataset_key === requested)) return requested;
  return datasets[0].dataset_key;
}

export interface CustomReportTotals {
  rowCount: number;
  totalAmount: Decimal;
}

/** The grand total row under a Custom Report Builder table -- a display-only sum of exactly the
 * per-dimension `row_count`/`total_amount` figures `run_custom_report` already returned, never a second
 * aggregation of source data (Step 12 §19's own "constrained to safe curated datasets" applies to the RPC,
 * not to a frontend recomputation of it). */
export function customReportTotals(
  rows: readonly { row_count: number; total_amount: string }[],
): CustomReportTotals {
  const rowCount = rows.reduce((sum, r) => sum + r.row_count, 0);
  const totalAmount = sumDecimals(rows.map((r) => Decimal.parse(r.total_amount)));
  return { rowCount, totalAmount };
}

// ================================================================ Consolidated Analysis (P13 Part 4, fifth increment)

/** The Entity selection a Consolidated Analysis screen resolves to (Step 12 §15). `eligible` is expected
 * already filtered to what the caller actually holds `reports.cross_entity` for (checked in the page via
 * `can`, `@/domain/authz/access`) -- this function never re-derives authorization, it only picks which of
 * those authorized Entities are in view. Any requested id that is not in `eligible` is silently dropped
 * (never sent to `consolidated_cash_position`, which would otherwise fail the whole call closed per its
 * own per-Entity check) rather than surfaced as an error -- a stale or tampered id just falls out of the
 * selection. When nothing requested survives that filter (first load, or every requested id was dropped),
 * this defaults to every eligible Entity -- a cross-Entity view starting from "show everything I may see"
 * is the sensible default, mirroring `resolveGeneralLedgerAccount`/`resolveCustomReportDataset`'s own
 * "always resolve to something sensible" shape. An empty `eligible` list (no cross-Entity permission
 * anywhere) returns an empty selection -- there is nothing sensible to fall back to. */
export function resolveConsolidatedEntityIds(
  eligible: readonly { entity_id: string }[],
  requested: readonly string[],
): string[] {
  if (eligible.length === 0) return [];
  const eligibleIds = new Set(eligible.map((e) => e.entity_id));
  const filtered = requested.filter((id) => eligibleIds.has(id));
  return filtered.length > 0 ? filtered : eligible.map((e) => e.entity_id);
}

export interface ConsolidatedCashPositionTotals {
  entityCount: number;
  totalCashBalance: Decimal | null;
}

/** The grand total row under a Consolidated Analysis table -- a display-only sum of exactly the
 * per-Entity `cash_balance` figures `consolidated_cash_position` already returned, never a merge of the
 * underlying books (the RPC's own comment: "Company and Personal books are never merged"; this only adds
 * up the already-computed display figures). Each Entity's own base currency is looked up separately (the
 * RPC returns no currency of its own), so `totalCashBalance` is `null` -- not a silently wrong number --
 * whenever the selected Entities do not all share one base currency; summing IDR and, say, USD balances
 * into one figure would be exactly the "invented second financial truth" this app's reports never do. */
export function consolidatedCashPositionTotals(
  rows: readonly { entity_id: string; cash_balance: string }[],
  currencyByEntity: Readonly<Record<string, string>>,
): ConsolidatedCashPositionTotals {
  const entityCount = rows.length;
  if (entityCount === 0) return { entityCount, totalCashBalance: Decimal.zero() };
  const currencies = new Set(rows.map((r) => currencyByEntity[r.entity_id]));
  if (currencies.size !== 1) return { entityCount, totalCashBalance: null };
  const totalCashBalance = sumDecimals(rows.map((r) => Decimal.parse(r.cash_balance)));
  return { entityCount, totalCashBalance };
}
