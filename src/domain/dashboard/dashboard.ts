import { Decimal, sumDecimals } from "@/domain/money/decimal";
import { naturalAmount, type AccountClass } from "@/domain/reports/reports";
import type { EquityChangeRow, ProfitAndLossRow } from "@/schemas/reports";
import type { MoneyControlRow, ReconciliationStatusRow } from "@/schemas/money";
import type { TaxCalendarRow, ReviewQueueRow } from "@/schemas/tax";
import type { MissingEvidenceRow, VendorPaymentRow } from "@/schemas/purchases";
import type { InvoicePosition, PaymentListRow } from "@/schemas/sales";
import type { CashFlowRow } from "@/schemas/reports";

/**
 * Pure Dashboard helpers (Step 09 §8, Step 10 §10-13). Every figure here is derived from rows an existing,
 * already-audited report/service RPC returned -- this module never computes an independent frontend
 * financial truth (DECISIONS #160). It only selects, sums (via the exact `Decimal` type) and orders what
 * the database already produced.
 */

const NAME_NET_RESULT = "Net result for the period";

/**
 * The Profit/Surplus KPI. Reads the synthetic "Net result for the period" row that
 * `statement_of_changes_in_equity` already computes server-side (`code: null`), converting it to a signed
 * figure via `naturalAmount(..., "equity")` (credit-normal, so a profit is positive). Returns `null` when
 * the row is absent (an empty/zero-activity period can still return it, but a defensive caller should not
 * assume it always will) so the UI can show an explicit "no data" state instead of silently defaulting to
 * zero, which would be indistinguishable from a real break-even result.
 */
export function netResultFromEquityRows(rows: readonly EquityChangeRow[]): Decimal | null {
  const row = rows.find((r) => r.code === null && r.name === NAME_NET_RESULT);
  if (!row) return null;
  return naturalAmount(row.period_debit, row.period_credit, "equity");
}

const MONTH_PATTERN = /^(\d{4})-(\d{2})$/;

export interface DashboardPeriod {
  /** "YYYY-MM", the period actually resolved (the requested one when valid, otherwise the reference month). */
  month: string;
  /** First day of the period, "YYYY-MM-DD". */
  start: string;
  /** Last calendar day of the period, "YYYY-MM-DD" -- always the full month, even when it has not
   * finished yet, so the P&L/equity call reflects "this month so far" without the Dashboard needing its
   * own notion of the Entity's local "today" (every RPC it calls already applies that server-side). */
  end: string;
}

function daysInMonth(year: number, month: number): number {
  // `month` is 1-based here; day 0 of the next month is the last day of this one.
  return new Date(Date.UTC(year, month, 0)).getUTCDate();
}

/**
 * Resolves the Dashboard's Hero/KPI period (Step 10 §10 "Header ... + period"). `requested` is the
 * `?month=YYYY-MM` query value, if any; an invalid or missing value falls back to `reference`'s month
 * (defaulting to now). Pure and UTC-based: it only picks a calendar month boundary for the RPC calls'
 * `p_start`/`p_end` arguments, it never decides what counts as "today" for an overdue/due state -- every
 * RPC already computes those server-side against the Entity's own local date.
 */
export function resolveDashboardPeriod(
  requested?: string,
  reference: Date = new Date(),
): DashboardPeriod {
  const match = requested ? MONTH_PATTERN.exec(requested) : null;
  const year = match ? Number(match[1]) : reference.getUTCFullYear();
  const month = match ? Number(match[2]) : reference.getUTCMonth() + 1;
  const monthText = String(month).padStart(2, "0");
  return {
    month: `${year}-${monthText}`,
    start: `${year}-${monthText}-01`,
    end: `${year}-${monthText}-${String(daysInMonth(year, month)).padStart(2, "0")}`,
  };
}

/** The trailing `count` months up to and including `period.month`, oldest first -- the range the Cashflow
 * Trend chart requests one `cash_flow_statement` call per month for (Step 10 §12: a line chart over a
 * short period, not a single wide-range call the database would have to reinterpret into buckets). */
export function trailingMonths(period: DashboardPeriod, count: number): DashboardPeriod[] {
  const [year, month] = period.month.split("-").map(Number);
  const months: DashboardPeriod[] = [];
  for (let i = count - 1; i >= 0; i -= 1) {
    const d = new Date(Date.UTC(year, month - 1 - i, 1));
    months.push(resolveDashboardPeriod(undefined, d));
  }
  return months;
}

/** The `closing_cash` bucket from one `cash_flow_statement` call, for the Trend chart's per-month point. */
export function closingCashFromCashFlowRows(rows: readonly CashFlowRow[]): Decimal | null {
  const row = rows.find((r) => r.bucket === "closing_cash");
  return row ? Decimal.parse(row.amount) : null;
}

const REVENUE_CLASSES: readonly AccountClass[] = ["revenue", "other_income"];
const EXPENSE_CLASSES: readonly AccountClass[] = ["expense", "other_expense"];

export interface PnlTotals {
  revenue: Decimal;
  expense: Decimal;
}

/** Revenue/Income and Expense KPI totals from a `profit_and_loss` result, each a positive magnitude in its
 * class's own natural direction (never re-derived independently of the account classification the
 * database assigned). */
export function pnlTotals(rows: readonly ProfitAndLossRow[]): PnlTotals {
  const revenue = sumDecimals(
    rows
      .filter((r) => REVENUE_CLASSES.includes(r.account_class))
      .map((r) => naturalAmount(r.debit, r.credit, r.account_class)),
  );
  const expense = sumDecimals(
    rows
      .filter((r) => EXPENSE_CLASSES.includes(r.account_class))
      .map((r) => naturalAmount(r.debit, r.credit, r.account_class)),
  );
  return { revenue, expense };
}

interface AgingLike {
  not_due: string;
  days_1_30: string;
  days_31_60: string;
  days_61_90: string;
  days_over_90: string;
  total: string;
}

export interface AgingSummary {
  total: Decimal;
  overdue: Decimal;
}

/** Total and overdue-only totals from an `ar_aging`/`ap_aging` result (the receivables/payables KPI and
 * the AR/AP drill-down zone share this shape). */
export function agingSummary(rows: readonly AgingLike[]): AgingSummary {
  const total = sumDecimals(rows.map((r) => Decimal.parse(r.total)));
  const overdue = sumDecimals(
    rows.flatMap((r) =>
      [r.days_1_30, r.days_31_60, r.days_61_90, r.days_over_90].map((v) => Decimal.parse(v)),
    ),
  );
  return { total, overdue };
}

/** Sum of active accounts' `movement_base_balance` (the entity's single reporting currency) for the Cash
 * KPI -- summing raw `movement_balance` across accounts of different currencies would silently mix them,
 * which is exactly the kind of independent frontend arithmetic Part 2 must avoid; `movement_base_balance`
 * is already the database's own converted figure. */
export function activeCashBalance(rows: readonly MoneyControlRow[]): Decimal {
  return sumDecimals(
    rows.filter((r) => r.is_active).map((r) => Decimal.parse(r.movement_base_balance)),
  );
}

const DEADLINE_STATES = new Set(["overdue", "due", "upcoming"]);
const URGENCY_ORDER: Readonly<Record<string, number>> = { overdue: 0, due: 1, upcoming: 2 };

/** The nearest not-yet-done tax deadlines for the Tax Snapshot, overdue first, then due, then upcoming,
 * each ordered by due date. `done`/`not_applicable`/`no_rule` rows and rows with no due date are dropped --
 * they are not deadlines to act on. */
export function upcomingTaxDeadlines(rows: readonly TaxCalendarRow[], limit = 5): TaxCalendarRow[] {
  return rows
    .filter((r) => r.due_date !== null && DEADLINE_STATES.has(r.state))
    .slice()
    .sort((a, b) => {
      const byUrgency = URGENCY_ORDER[a.state] - URGENCY_ORDER[b.state];
      if (byUrgency !== 0) return byUrgency;
      return (a.due_date ?? "").localeCompare(b.due_date ?? "");
    })
    .slice(0, limit);
}

/** Accounts whose reconciliation needs attention: an open session not yet completed, or statement lines
 * still unresolved. Feeds both the Cash/Accounts freshness zone and Tasks & Attention. */
export function reconciliationsNeedingAttention(
  rows: readonly ReconciliationStatusRow[],
): ReconciliationStatusRow[] {
  return rows.filter((r) => r.session_in_progress || r.unresolved_lines > 0);
}

export type AttentionKind = "tax_review" | "missing_evidence" | "reconciliation";

export interface AttentionItem {
  kind: AttentionKind;
  id: string;
  title: string;
  detail: string;
  date: string | null;
}

/**
 * Tasks & Attention (Step 09 §8): a single prioritized list merged from the tax review queue, purchase
 * documents missing required evidence, and reconciliations left open or with unresolved lines.
 *
 * Scope-trim (DECISIONS #163): pending invoice/bill *approvals* are deliberately NOT included here in
 * Part 2 -- that queue belongs to the Sales/Purchases approval workflows themselves (Step 09 §8 lists
 * "confirmation, approval, reconciliation, missing evidence or review" as the category, not a mandate that
 * every one of those sources ships in the very first Dashboard slice); it is deferred to Part 3 alongside
 * the rest of the approvals surface so Part 2 stays scoped to sources this Dashboard already has services
 * for. Sorted newest-event-first; a `null` date sorts last.
 */
export function buildAttentionItems(input: {
  taxReviewQueue: readonly ReviewQueueRow[];
  missingEvidence: readonly MissingEvidenceRow[];
  staleReconciliations: readonly ReconciliationStatusRow[];
}): AttentionItem[] {
  const items: AttentionItem[] = [
    ...input.taxReviewQueue.map((r) => ({
      kind: "tax_review" as const,
      id: `${r.source_type}:${r.source_id}`,
      title: r.reference ?? r.source_type,
      detail: r.reasons.join(", "),
      date: r.event_date,
    })),
    ...input.missingEvidence.map((r) => ({
      kind: "missing_evidence" as const,
      id: r.doc_id,
      title: r.doc_number ?? r.doc_kind,
      detail: r.party_name ?? "-",
      date: r.doc_date,
    })),
    ...input.staleReconciliations.map((r) => ({
      kind: "reconciliation" as const,
      id: r.financial_account_id,
      title: r.name,
      detail: r.session_in_progress
        ? "Sesi rekonsiliasi belum diselesaikan"
        : `${r.unresolved_lines} baris belum terselesaikan`,
      date: r.last_reconciled_until,
    })),
  ];
  return items.sort((a, b) => (b.date ?? "").localeCompare(a.date ?? ""));
}

export type RecentActivityKind = "customer_payment" | "vendor_payment" | "invoice_issued";

export interface RecentActivityItem {
  kind: RecentActivityKind;
  id: string;
  date: string;
  title: string;
  counterparty: string;
  amount: string;
  currency: string;
}

/** Recent Activity (Step 09 §8): a short, meaningful-events-only feed merged from confirmed customer
 * payments, confirmed vendor payments and issued invoices -- never a raw audit log. Newest first. */
export function mergeRecentActivity(
  input: {
    customerPayments: readonly PaymentListRow[];
    vendorPayments: readonly VendorPaymentRow[];
    issuedInvoices: readonly InvoicePosition[];
  },
  limit = 8,
): RecentActivityItem[] {
  const items: RecentActivityItem[] = [
    ...input.customerPayments
      .filter((p) => p.status === "confirmed")
      .map((p) => ({
        kind: "customer_payment" as const,
        id: p.payment_id,
        date: p.payment_date,
        title: `Pembayaran ${p.payment_number}`,
        counterparty: p.customer_name,
        amount: p.amount,
        currency: p.currency,
      })),
    ...input.vendorPayments
      .filter((p) => p.status === "confirmed")
      .map((p) => ({
        kind: "vendor_payment" as const,
        id: p.payment_id,
        date: p.payment_date,
        title: `Pembayaran ${p.payment_number}`,
        counterparty: p.vendor_name,
        amount: p.amount,
        currency: p.currency,
      })),
    ...input.issuedInvoices
      .filter((i) => i.status === "issued")
      .map((i) => ({
        kind: "invoice_issued" as const,
        id: i.invoice_id,
        date: i.issue_date,
        title: `Faktur ${i.invoice_number ?? "-"}`,
        counterparty: i.customer_name,
        amount: i.total,
        currency: i.currency,
      })),
  ];
  return items.sort((a, b) => b.date.localeCompare(a.date)).slice(0, limit);
}
