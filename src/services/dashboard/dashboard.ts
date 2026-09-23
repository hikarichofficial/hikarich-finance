import "server-only";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { can } from "@/domain/authz/access";
import type { AccessSnapshot } from "@/schemas/access";
import { entityCurrencyRowSchema } from "@/schemas/dashboard";
import {
  activeCashBalance,
  agingSummary,
  buildAttentionItems,
  closingCashFromCashFlowRows,
  mergeRecentActivity,
  netResultFromEquityRows,
  pnlTotals,
  reconciliationsNeedingAttention,
  resolveDashboardPeriod,
  trailingMonths,
  upcomingTaxDeadlines,
  type AttentionItem,
  type DashboardPeriod,
  type RecentActivityItem,
} from "@/domain/dashboard/dashboard";
import {
  getCashFlowStatement,
  getProfitAndLoss,
  getStatementOfChangesInEquity,
} from "@/services/reports/reports";
import { getArAging, listInvoicePositions, listPayments } from "@/services/sales/sales";
import {
  getApAging,
  listMissingEvidence,
  listVendorPayments,
} from "@/services/purchases/purchases";
import { getMoneyControl, getReconciliationStatus } from "@/services/money/money";
import { getTaxCalendar, getTaxOverview, listTaxReviewQueue } from "@/services/tax/tax";
import type { MoneyControlRow, ReconciliationStatusRow } from "@/schemas/money";
import type { ArAgingRow } from "@/schemas/sales";
import type { ApAgingRow } from "@/schemas/purchases";
import type { TaxCalendarRow, TaxOverview } from "@/schemas/tax";

const TREND_MONTHS = 6;
const RECENT_ACTIVITY_LIMIT = 8;
const ATTENTION_LIMIT = 12;
const TAX_DEADLINE_LIMIT = 5;

export interface DashboardFinanceSection {
  revenue: string;
  expense: string;
  netResult: string | null;
}

export interface DashboardTrendPoint {
  month: string;
  closingCash: string | null;
}

export interface DashboardCashSection {
  balance: string;
  accounts: MoneyControlRow[];
}

export interface DashboardReceivablesSection {
  total: string;
  overdue: string;
  aging: ArAgingRow[];
}

export interface DashboardPayablesSection {
  total: string;
  overdue: string;
  aging: ApAgingRow[];
}

export interface DashboardTaxSection {
  overview: TaxOverview;
  deadlines: TaxCalendarRow[];
}

/**
 * Everything the Dashboard screen (P13 Part 2, Step 09 §8, Step 10 §10-13) renders, gated section by
 * section on the caller's own permissions in the active Entity. A section the person cannot see is `null`
 * rather than fetched-and-hidden: this function never calls an RPC the caller is not permitted to call, so
 * a missing permission produces an absent section, not a caught FORBIDDEN. `reconciliation` carries every
 * account's freshness (Account Snapshot needs a status for every account, not only the stale ones);
 * `attention`/`recentActivity` are assembled from whichever of their own sources were permitted -- an
 * arbitrarily gated intersection has no single owning permission of its own.
 */
export interface DashboardSnapshot {
  currency: string;
  period: DashboardPeriod;
  finance: DashboardFinanceSection | null;
  trend: DashboardTrendPoint[] | null;
  cash: DashboardCashSection | null;
  reconciliation: ReconciliationStatusRow[] | null;
  receivables: DashboardReceivablesSection | null;
  payables: DashboardPayablesSection | null;
  tax: DashboardTaxSection | null;
  attention: AttentionItem[];
  recentActivity: RecentActivityItem[];
}

async function getEntityBaseCurrency(entityId: string): Promise<string> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("entities")
    .select("base_currency")
    .eq("id", entityId)
    .single();
  if (error) throw new Error("Gagal memuat mata uang dasar Entity.");
  const parsed = entityCurrencyRowSchema.safeParse(data);
  if (!parsed.success) throw new Error("Respons mata uang dasar Entity tidak dikenali.");
  return parsed.data.base_currency;
}

export async function getDashboardSnapshot(
  entityId: string,
  access: AccessSnapshot,
  options: { month?: string } = {},
): Promise<DashboardSnapshot> {
  const period = resolveDashboardPeriod(options.month);

  const canReports = can(access, entityId, "reports.view");
  const canMoney = can(access, entityId, "money.view");
  const canInvoices = can(access, entityId, "invoices.view");
  const canBills = can(access, entityId, "bills.view");
  const canDocuments = can(access, entityId, "documents.view");
  const canTax = can(access, entityId, "tax.view");
  const canMissingEvidence = canBills && canDocuments;

  const [
    currency,
    financeRows,
    trendRows,
    moneyControlRows,
    reconciliationRows,
    arRows,
    paymentsRows,
    invoicePositionRows,
    apRows,
    vendorPaymentRows,
    missingEvidenceRows,
    taxOverview,
    taxCalendarRows,
    taxReviewRows,
  ] = await Promise.all([
    getEntityBaseCurrency(entityId),
    canReports
      ? Promise.all([
          getProfitAndLoss({ entity_id: entityId, start_date: period.start, end_date: period.end }),
          getStatementOfChangesInEquity({
            entity_id: entityId,
            start_date: period.start,
            end_date: period.end,
          }),
        ])
      : null,
    canReports
      ? Promise.all(
          trailingMonths(period, TREND_MONTHS).map((month) =>
            getCashFlowStatement({
              entity_id: entityId,
              start_date: month.start,
              end_date: month.end,
            }).then((rows) => ({ month: month.month, rows })),
          ),
        )
      : null,
    canMoney ? getMoneyControl(entityId, period.end) : null,
    canMoney ? getReconciliationStatus(entityId) : null,
    canInvoices ? getArAging(entityId, { asOf: period.end }) : null,
    canInvoices ? listPayments(entityId, { limit: 20 }) : null,
    canInvoices ? listInvoicePositions(entityId, { filter: "open", asOf: period.end }) : null,
    canBills ? getApAging(entityId, { asOf: period.end }) : null,
    canBills ? listVendorPayments(entityId, { limit: 20 }) : null,
    canMissingEvidence ? listMissingEvidence(entityId) : null,
    canTax ? getTaxOverview(entityId) : null,
    canTax ? getTaxCalendar({ entity_id: entityId }) : null,
    canTax ? listTaxReviewQueue(entityId) : null,
  ]);

  const finance: DashboardFinanceSection | null = financeRows
    ? (() => {
        const [pnlRows, equityRows] = financeRows;
        const totals = pnlTotals(pnlRows);
        const net = netResultFromEquityRows(equityRows);
        return {
          revenue: totals.revenue.toString(),
          expense: totals.expense.toString(),
          netResult: net ? net.toString() : null,
        };
      })()
    : null;

  const trend: DashboardTrendPoint[] | null = trendRows
    ? trendRows.map(({ month, rows }) => ({
        month,
        closingCash: closingCashFromCashFlowRows(rows)?.toString() ?? null,
      }))
    : null;

  const cash: DashboardCashSection | null = moneyControlRows
    ? { balance: activeCashBalance(moneyControlRows).toString(), accounts: moneyControlRows }
    : null;

  const reconciliationAttention = reconciliationRows
    ? reconciliationsNeedingAttention(reconciliationRows)
    : [];

  const receivables: DashboardReceivablesSection | null = arRows
    ? (() => {
        const summary = agingSummary(arRows);
        return {
          total: summary.total.toString(),
          overdue: summary.overdue.toString(),
          aging: arRows,
        };
      })()
    : null;

  const payables: DashboardPayablesSection | null = apRows
    ? (() => {
        const summary = agingSummary(apRows);
        return {
          total: summary.total.toString(),
          overdue: summary.overdue.toString(),
          aging: apRows,
        };
      })()
    : null;

  const tax: DashboardTaxSection | null =
    taxOverview && taxCalendarRows
      ? {
          overview: taxOverview,
          deadlines: upcomingTaxDeadlines(taxCalendarRows, TAX_DEADLINE_LIMIT),
        }
      : null;

  const attention = buildAttentionItems({
    taxReviewQueue: taxReviewRows ?? [],
    missingEvidence: missingEvidenceRows ?? [],
    staleReconciliations: reconciliationAttention,
  }).slice(0, ATTENTION_LIMIT);

  const recentActivity = mergeRecentActivity(
    {
      customerPayments: paymentsRows ?? [],
      vendorPayments: vendorPaymentRows ?? [],
      issuedInvoices: invoicePositionRows ?? [],
    },
    RECENT_ACTIVITY_LIMIT,
  );

  return {
    currency,
    period,
    finance,
    trend,
    cash,
    reconciliation: reconciliationRows,
    receivables,
    payables,
    tax,
    attention,
    recentActivity,
  };
}
