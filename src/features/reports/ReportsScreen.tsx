import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import type { Decimal } from "@/domain/money/decimal";
import { ENTRY_TYPE_LABELS } from "@/domain/accounting/journalList";
import { entityLabel } from "@/domain/authz/access";
import { LOAN_DIRECTION_LABELS } from "@/domain/financing/financing";
import { loanScheduleStateBadge } from "@/domain/financing/loanList";
import { payrollPeriodName } from "@/domain/payroll/payroll";
import { payrollRunStatusBadge } from "@/domain/payroll/runList";
import {
  BALANCE_SHEET_SECTION_ORDER,
  CASH_FLOW_BUCKET_LABELS,
  CASH_FLOW_BUCKET_ORDER,
  PNL_SECTION_ORDER,
  assetControlAccountLabel,
  assetControlRowBalanced,
  assetControlSummary,
  balanceSheetTotals,
  cashFlowTotals,
  consolidatedCashPositionTotals,
  customReportTotals,
  equityClosingTotal,
  equityRowAmounts,
  fiscalScheduleTotalDepreciation,
  generalLedgerTotals,
  groupByAccountClass,
  hasPnlComparison,
  loanDueTotals,
  loanSummaryTotals,
  payrollControlAccountLabel,
  payrollControlRowBalanced,
  payrollControlSummary,
  payrollSummaryTotals,
  pnlCompareAmount,
  pnlCompareNetIncome,
  pnlCompareSubtotal,
  pnlNetIncome,
  type CashFlowBucket,
  type CashFlowTotals,
  type ReportDateRange,
} from "@/domain/reports/reports";
import type {
  BalanceSheetRow,
  CashFlowRow,
  ConsolidatedCashPositionRow,
  CustomReportRow,
  EquityChangeRow,
  GeneralLedgerRow,
  ProfitAndLossRow,
  ReportDatasetCatalogRow,
} from "@/schemas/reports";
import type { LoanDueRow, LoanSummaryRow } from "@/schemas/financing";
import type { PayrollControlRow, PayrollSummaryRow } from "@/schemas/payroll";
import type { AssetControlRow, AssetRow, FiscalScheduleRow } from "@/schemas/assets";
import type { LedgerAccountRow } from "@/schemas/accounting";
import type { Membership } from "@/schemas/access";
import { formatShortDate } from "./format";

export type ReportStatement =
  | "pnl"
  | "balance_sheet"
  | "equity"
  | "cashflow"
  | "gl"
  | "custom"
  | "consolidated"
  | "loans_due"
  | "loan_summary"
  | "payroll_summary"
  | "payroll_control"
  | "fiscal_schedule"
  | "asset_control";

export const REPORT_STATEMENT_TABS: readonly { value: ReportStatement; label: string }[] = [
  { value: "pnl", label: "Laba Rugi" },
  { value: "balance_sheet", label: "Neraca" },
  { value: "equity", label: "Perubahan Ekuitas" },
  { value: "cashflow", label: "Arus Kas" },
  { value: "gl", label: "Buku Besar" },
  { value: "custom", label: "Laporan Kustom" },
  { value: "consolidated", label: "Analisis Konsolidasi" },
  { value: "loans_due", label: "Pinjaman Jatuh Tempo" },
  { value: "loan_summary", label: "Ringkasan Pinjaman" },
  { value: "payroll_summary", label: "Ringkasan Payroll" },
  { value: "payroll_control", label: "Kontrol Payroll" },
  { value: "fiscal_schedule", label: "Jadwal Penyusutan Fiskal" },
  { value: "asset_control", label: "Kontrol Aset Tetap" },
];

export type ReportsData =
  | {
      statement: "pnl";
      range: ReportDateRange;
      compareRange: ReportDateRange | undefined;
      rows: readonly ProfitAndLossRow[];
    }
  | { statement: "balance_sheet"; asOf: string; rows: readonly BalanceSheetRow[] }
  | { statement: "equity"; range: ReportDateRange; rows: readonly EquityChangeRow[] }
  | { statement: "cashflow"; range: ReportDateRange; rows: readonly CashFlowRow[] }
  | {
      statement: "gl";
      range: ReportDateRange;
      accountId: string | null;
      accounts: readonly LedgerAccountRow[];
      rows: readonly GeneralLedgerRow[];
    }
  | {
      statement: "custom";
      range: ReportDateRange;
      datasets: readonly ReportDatasetCatalogRow[];
      datasetKey: string | null;
      rows: readonly CustomReportRow[];
    }
  | {
      statement: "consolidated";
      asOf: string;
      eligible: readonly Membership[];
      entityIds: readonly string[];
      rows: readonly ConsolidatedCashPositionRow[];
      currencyByEntity: Readonly<Record<string, string>>;
    }
  | { statement: "loans_due"; through: string; canView: boolean; rows: readonly LoanDueRow[] }
  | {
      statement: "loan_summary";
      range: ReportDateRange;
      canView: boolean;
      rows: readonly LoanSummaryRow[];
    }
  | {
      statement: "payroll_summary";
      range: ReportDateRange;
      canView: boolean;
      rows: readonly PayrollSummaryRow[];
    }
  | {
      statement: "payroll_control";
      asOf: string;
      canView: boolean;
      rows: readonly PayrollControlRow[];
    }
  | {
      statement: "fiscal_schedule";
      assets: readonly AssetRow[];
      assetId: string | null;
      canView: boolean;
      rows: readonly FiscalScheduleRow[];
    }
  | {
      statement: "asset_control";
      asOf: string;
      canView: boolean;
      rows: readonly AssetControlRow[];
    };

function buildTabHref(entity: string | undefined, statement: ReportStatement): string {
  const params = new URLSearchParams();
  if (entity) params.set("entity", entity);
  params.set("statement", statement);
  return `/reports?${params.toString()}`;
}

/**
 * Financial Reports (P13 Part 4, Step 12 §3-§5, nav's "Financial Reports" -> `/reports`, decision 155). The
 * four canonical statements P12 already computes -- Profit & Loss, Balance Sheet, Statement of Changes in
 * Equity, Cash Flow Statement -- plus the General Ledger drill-down (decision 190, second increment),
 * switched by `?statement=`, each with its own filter form (Standard List Screen Pattern, Step 09 §9, with
 * the usual status-filter tabs standing in for a statement switcher instead). The P&L tab additionally
 * accepts an optional comparison period (decision 191, third increment) -- when set, the table grows a
 * "Periode Pembanding" and "Selisih" column, computed entirely from the RPC's own `compare_debit`/
 * `compare_credit` pair, never a second frontend computation. The Custom Report Builder tab (decision 192,
 * fourth increment) runs one of the curated, permission-gated datasets `run_custom_report` exposes
 * (Step 12 §19) -- the dataset picker only ever lists what the active membership may run (filtered
 * server-side in the route, never client-side), and every row's dimension/count/total is exactly what the
 * RPC returned, grouped and summed once, in the database. The Consolidated Analysis tab (decision 193,
 * fifth increment) is the one statement not scoped to a single active Entity: its checkboxes only ever
 * list Entities the caller holds `reports.cross_entity` for, and its per-row cash balance is formatted with
 * that Entity's own base currency (looked up in the route, `currencyByEntity`) rather than the active
 * Entity's -- Company and Personal books are never merged, and a grand total is only ever shown when every
 * selected Entity happens to share one base currency. The Loans Due and Loan Summary tabs (decision 195,
 * seventh increment) wire the already-built `loan_due`/`loan_summary` RPCs (P8, unused in a screen until
 * now) straight in, following the same "no new RPC, schema or service wrapper" shape every Part 4 increment
 * has used -- `LoanDueRow`/`LoanSummaryRow` and the `loansDue`/`loanSummary` service wrappers are imported
 * directly from `@/schemas/financing`/`@/services/financing/financing` rather than duplicated into the
 * reports module, exactly like the General Ledger tab already imports `listLedgerAccounts`/`LedgerAccountRow`
 * from the accounting module. Loans Due reuses `loanScheduleStateBadge`/`LOAN_DIRECTION_LABELS` unchanged
 * from Loan Detail/Register (decisions 172/174) so the same installment can never show a different state or
 * direction label depending on which screen it is viewed from; each row links to the existing Loan Detail
 * screen. The Payroll Summary and Payroll Control tabs (decision 196, eighth increment) wire the already-built
 * `payroll_summary_report`/`payroll_control_report` RPCs (P9, unused in a screen until now) in the same shape,
 * via the existing `getPayrollSummary`/`getPayrollControl` wrappers (`@/services/payroll/payroll`). Both share
 * the compound "base payroll" gate already established for Payroll Runs/Payslips/Tax (decision 180:
 * `payroll.compensation_view` AND at least one of `payroll.run`/`payroll.approve`/`payroll.pay`), and Payroll
 * Control additionally hard-requires `accounting.view` (the RPC itself raises `FORBIDDEN` without it) -- no
 * role in the seed catalog holds the full payroll-run set together with `reports.view`, but the OWNER role
 * holds every permission unconditionally (confirmed directly against `app_authz.has_permission`'s own
 * special-case for `role_key = 'owner'`), so these tabs are reachable exactly like every other Reports tab,
 * the same "filter-before-calling, plain permission message instead of an error" pattern as Loans Due/Summary.
 * Payroll Summary's masked columns (`tax_allowance`/`pph21`/`pph21_period_outstanding`, gated by
 * `payroll.tax_view` inside the RPC itself) render "—" per row and are omitted from the totals row entirely
 * when every row in view has them masked, via `payrollSummaryTotals`'s null-when-all-null rule -- the same
 * "has*-or-null" idiom as `hasPnlComparison`/`pnlCompareSubtotal`, never a misleading zero. Payroll Control
 * always returns exactly two rows (Payroll Liability, BPJS Liability) with no cross-account grand total, since
 * summing two unrelated liability accounts would not be a meaningful figure -- `payrollControlSummary` reports
 * only a mismatch count. The Fiscal Depreciation Schedule and Asset GL Reconciliation tabs (decision 197,
 * ninth increment) wire the already-built `asset_fiscal_schedule`/`asset_control_report` RPCs (P8, unused in
 * a screen until now, `fiscalSchedule`/`assetControl` -- `@/services/assets/assets.ts`) in, closing out every
 * P12 report catalogue item decision 178 pushed here except Asset Movement/Disposal (no dedicated RPC yet).
 * Both are gated by `assets.view` plus a second permission (`tax.view` for the schedule, `accounting.view`
 * for the reconciliation, both hard `FORBIDDEN`s inside the RPC, not a mask) -- unlike Payroll Summary/
 * Control, the `accountant` and `viewer_auditor` seed roles already hold every permission either tab needs
 * together with `reports.view`, so no OWNER-reachability question arose here. Unlike every other tab,
 * `asset_fiscal_schedule` takes one asset (`p_asset`), not the active Entity, so Fiscal Depreciation Schedule
 * needs its own record picker -- the exact same shape the General Ledger tab's account picker already uses
 * (`resolveGeneralLedgerAccount`/`resolveFiscalScheduleAsset` share one "always resolve to something
 * sensible" contract). An asset with no fiscal class or in `draft`/`cancelled` status legitimately has an
 * empty schedule (the RPC itself returns no rows, not an error), so the picker is never filtered down to
 * only depreciable assets. Asset GL Reconciliation mirrors Payroll Control's own shape exactly (two fixed,
 * unrelated account keys, a mismatch count with no cross-account grand total) via its own
 * `assetControlAccountLabel`/`assetControlSummary`/`assetControlRowBalanced` -- a second, asset-specific copy
 * of the same three small helpers rather than repurposing the payroll-named ones across an unrelated module,
 * the same per-module duplication precedent used throughout Part 3/4. The other Reports nav sub-items
 * (Sales/Purchase, a standalone Cashflow view, Tax, Saved Reports) have no P12/P9 RPC behind them yet and
 * fall through to the `[...slug]` "coming soon" placeholder (decision 157's precedent) until one exists.
 * Every figure here is the database's own debit/credit, re-signed once via `naturalAmount`
 * (`@/domain/reports`) -- never a second computation of the same fact.
 */
export function ReportsScreen({
  data,
  entity,
  currency,
}: {
  data: ReportsData;
  entity: string | undefined;
  currency: string;
}) {
  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Laporan Keuangan</h1>
          <p className="list-screen-summary">Laporan resmi dari data yang telah diposting.</p>
        </div>
      </header>

      <div className="list-screen-toolbar">
        <nav className="list-filter-tabs" aria-label="Pilih laporan">
          {REPORT_STATEMENT_TABS.map((tab) => (
            <Link
              key={tab.value}
              href={buildTabHref(entity, tab.value)}
              className={
                tab.value === data.statement
                  ? "list-filter-tab list-filter-tab-active"
                  : "list-filter-tab"
              }
            >
              {tab.label}
            </Link>
          ))}
        </nav>
        <RangeForm data={data} entity={entity} />
      </div>

      {data.statement === "pnl" ? (
        <ProfitAndLossTable rows={data.rows} currency={currency} />
      ) : null}
      {data.statement === "balance_sheet" ? (
        <BalanceSheetTable rows={data.rows} currency={currency} />
      ) : null}
      {data.statement === "equity" ? <EquityTable rows={data.rows} currency={currency} /> : null}
      {data.statement === "cashflow" ? (
        <CashFlowTable rows={data.rows} currency={currency} />
      ) : null}
      {data.statement === "gl" ? (
        <GeneralLedgerTable
          rows={data.rows}
          accounts={data.accounts}
          accountId={data.accountId}
          currency={currency}
          entity={entity}
        />
      ) : null}
      {data.statement === "custom" ? (
        <CustomReportTable
          datasets={data.datasets}
          datasetKey={data.datasetKey}
          rows={data.rows}
          currency={currency}
        />
      ) : null}
      {data.statement === "consolidated" ? (
        <ConsolidatedAnalysisTable
          eligible={data.eligible}
          rows={data.rows}
          currencyByEntity={data.currencyByEntity}
        />
      ) : null}
      {data.statement === "loans_due" ? (
        <LoansDueTable
          rows={data.rows}
          canView={data.canView}
          currency={currency}
          entity={entity}
        />
      ) : null}
      {data.statement === "loan_summary" ? (
        <LoanSummaryTable
          rows={data.rows}
          canView={data.canView}
          currency={currency}
          entity={entity}
        />
      ) : null}
      {data.statement === "payroll_summary" ? (
        <PayrollSummaryTable
          rows={data.rows}
          canView={data.canView}
          currency={currency}
          entity={entity}
        />
      ) : null}
      {data.statement === "payroll_control" ? (
        <PayrollControlTable rows={data.rows} canView={data.canView} currency={currency} />
      ) : null}
      {data.statement === "fiscal_schedule" ? (
        <FiscalScheduleTable
          rows={data.rows}
          assets={data.assets}
          assetId={data.assetId}
          canView={data.canView}
          currency={currency}
        />
      ) : null}
      {data.statement === "asset_control" ? (
        <AssetControlTable rows={data.rows} canView={data.canView} currency={currency} />
      ) : null}
    </div>
  );
}

function RangeForm({ data, entity }: { data: ReportsData; entity: string | undefined }) {
  return (
    <form method="get" className="list-search-form">
      {entity ? <input type="hidden" name="entity" value={entity} /> : null}
      <input type="hidden" name="statement" value={data.statement} />
      {data.statement === "gl" ? (
        <label>
          Akun
          <select name="account" defaultValue={data.accountId ?? ""}>
            {data.accounts.length === 0 ? <option value="">Tidak ada akun</option> : null}
            {data.accounts.map((account) => (
              <option key={account.id} value={account.id}>
                {account.code} · {account.name}
              </option>
            ))}
          </select>
        </label>
      ) : null}
      {data.statement === "custom" ? (
        <label>
          Dataset
          <select name="dataset" defaultValue={data.datasetKey ?? ""}>
            {data.datasets.length === 0 ? <option value="">Tidak ada dataset</option> : null}
            {data.datasets.map((dataset) => (
              <option key={dataset.dataset_key} value={dataset.dataset_key}>
                {dataset.name}
              </option>
            ))}
          </select>
        </label>
      ) : null}
      {data.statement === "consolidated" ? (
        <fieldset>
          <legend>Entity</legend>
          {data.eligible.length === 0 ? <p>Anda tidak memiliki izin lintas-Entity.</p> : null}
          {data.eligible.map((membership) => (
            <label key={membership.entity_id}>
              <input
                type="checkbox"
                name="entities"
                value={membership.entity_id}
                defaultChecked={data.entityIds.includes(membership.entity_id)}
              />
              {membership.entity_name} ({entityLabel(membership)})
            </label>
          ))}
        </fieldset>
      ) : null}
      {data.statement === "fiscal_schedule" ? (
        <label>
          Aset
          <select name="asset" defaultValue={data.assetId ?? ""}>
            {data.assets.length === 0 ? <option value="">Tidak ada aset</option> : null}
            {data.assets.map((asset) => (
              <option key={asset.asset_id} value={asset.asset_id}>
                {asset.asset_code} · {asset.name}
              </option>
            ))}
          </select>
        </label>
      ) : null}
      {data.statement === "balance_sheet" ||
      data.statement === "consolidated" ||
      data.statement === "payroll_control" ||
      data.statement === "asset_control" ? (
        <label>
          Per tanggal
          <input type="date" name="as_of" defaultValue={data.asOf} />
        </label>
      ) : data.statement === "loans_due" ? (
        <label>
          Sampai Tanggal
          <input type="date" name="through" defaultValue={data.through} />
        </label>
      ) : data.statement === "fiscal_schedule" ? null : (
        <>
          <label>
            Dari
            <input type="date" name="from" defaultValue={data.range.from} />
          </label>
          <label>
            Sampai
            <input type="date" name="to" defaultValue={data.range.to} />
          </label>
        </>
      )}
      {data.statement === "pnl" ? (
        <>
          <label>
            Pembanding dari
            <input type="date" name="compare_from" defaultValue={data.compareRange?.from ?? ""} />
          </label>
          <label>
            Pembanding sampai
            <input type="date" name="compare_to" defaultValue={data.compareRange?.to ?? ""} />
          </label>
        </>
      ) : null}
      <button type="submit" className="btn-secondary">
        Terapkan
      </button>
    </form>
  );
}

function ProfitAndLossTable({
  rows,
  currency,
}: {
  rows: readonly ProfitAndLossRow[];
  currency: string;
}) {
  const sections = groupByAccountClass(rows, PNL_SECTION_ORDER);
  if (sections.length === 0) {
    return (
      <div className="list-empty">
        <p>Tidak ada transaksi terposting pada periode ini.</p>
      </div>
    );
  }
  const net = pnlNetIncome(rows);
  const showCompare = hasPnlComparison(rows);
  const compareNet = pnlCompareNetIncome(rows);
  const colSpan = showCompare ? 5 : 3;
  return (
    <table className="record-table">
      <thead>
        <tr>
          <th scope="col">Kode</th>
          <th scope="col">Akun</th>
          <th scope="col" className="num">
            Jumlah
          </th>
          {showCompare ? (
            <>
              <th scope="col" className="num">
                Periode Pembanding
              </th>
              <th scope="col" className="num">
                Selisih
              </th>
            </>
          ) : null}
        </tr>
      </thead>
      {sections.map((section) => {
        const sectionCompareSubtotal = pnlCompareSubtotal(section.rows.map((r) => r.row));
        return (
          <tbody key={section.accountClass}>
            <tr className="statement-section-row">
              <th scope="colgroup" colSpan={colSpan}>
                {section.label}
              </th>
            </tr>
            {section.rows.map(({ row, amount }) => {
              const compareAmount = pnlCompareAmount(row);
              return (
                <tr key={row.account_id}>
                  <td>{row.code}</td>
                  <td>{row.name}</td>
                  <td className="num">{formatMoney(amount.toString(), currency)}</td>
                  {showCompare ? (
                    <>
                      <td className="num">
                        {compareAmount ? formatMoney(compareAmount.toString(), currency) : "—"}
                      </td>
                      <td className="num">
                        {compareAmount
                          ? formatMoney(amount.sub(compareAmount).toString(), currency)
                          : "—"}
                      </td>
                    </>
                  ) : null}
                </tr>
              );
            })}
            <tr className="statement-subtotal-row">
              <th scope="row" colSpan={2}>
                Total {section.label}
              </th>
              <td className="num">{formatMoney(section.subtotal.toString(), currency)}</td>
              {showCompare ? (
                <>
                  <td className="num">
                    {sectionCompareSubtotal
                      ? formatMoney(sectionCompareSubtotal.toString(), currency)
                      : "—"}
                  </td>
                  <td className="num">
                    {sectionCompareSubtotal
                      ? formatMoney(
                          section.subtotal.sub(sectionCompareSubtotal).toString(),
                          currency,
                        )
                      : "—"}
                  </td>
                </>
              ) : null}
            </tr>
          </tbody>
        );
      })}
      <tfoot>
        <tr>
          <th scope="row" colSpan={2}>
            {net.isNegative() ? "Rugi Bersih" : "Laba Bersih"}
          </th>
          <td className="num">{formatMoney(net.toString(), currency)}</td>
          {showCompare ? (
            <>
              <td className="num">
                {compareNet ? formatMoney(compareNet.toString(), currency) : "—"}
              </td>
              <td className="num">
                {compareNet ? formatMoney(net.sub(compareNet).toString(), currency) : "—"}
              </td>
            </>
          ) : null}
        </tr>
      </tfoot>
    </table>
  );
}

function BalanceSheetTable({
  rows,
  currency,
}: {
  rows: readonly BalanceSheetRow[];
  currency: string;
}) {
  const sections = groupByAccountClass(rows, BALANCE_SHEET_SECTION_ORDER);
  if (sections.length === 0) {
    return (
      <div className="list-empty">
        <p>Tidak ada saldo pada tanggal ini.</p>
      </div>
    );
  }
  const totals = balanceSheetTotals(rows);
  return (
    <table className="record-table">
      <thead>
        <tr>
          <th scope="col">Kode</th>
          <th scope="col">Akun</th>
          <th scope="col" className="num">
            Saldo
          </th>
        </tr>
      </thead>
      {sections.map((section) => (
        <tbody key={section.accountClass}>
          <tr className="statement-section-row">
            <th scope="colgroup" colSpan={3}>
              {section.label}
            </th>
          </tr>
          {section.rows.map(({ row, amount }) => (
            <tr key={row.account_id}>
              <td>{row.code}</td>
              <td>{row.name}</td>
              <td className="num">{formatMoney(amount.toString(), currency)}</td>
            </tr>
          ))}
          <tr className="statement-subtotal-row">
            <th scope="row" colSpan={2}>
              Total {section.label}
            </th>
            <td className="num">{formatMoney(section.subtotal.toString(), currency)}</td>
          </tr>
        </tbody>
      ))}
      <tfoot>
        <tr>
          <th scope="row" colSpan={2}>
            Total Aset
          </th>
          <td className="num">{formatMoney(totals.assets.toString(), currency)}</td>
        </tr>
        <tr>
          <th scope="row" colSpan={2}>
            Total Liabilitas &amp; Ekuitas
          </th>
          <td className="num">{formatMoney(totals.liabilitiesAndEquity.toString(), currency)}</td>
        </tr>
        <tr>
          <th scope="row" colSpan={2}>
            Status
          </th>
          <td className="num">
            <span
              className={`status-badge status-badge-${totals.balanced ? "success" : "critical"}`}
            >
              {totals.balanced ? "Seimbang" : "Tidak seimbang"}
            </span>
          </td>
        </tr>
      </tfoot>
    </table>
  );
}

function EquityTable({ rows, currency }: { rows: readonly EquityChangeRow[]; currency: string }) {
  if (rows.length === 0) {
    return (
      <div className="list-empty">
        <p>Tidak ada akun ekuitas pada Entity ini.</p>
      </div>
    );
  }
  const total = equityClosingTotal(rows);
  return (
    <table className="record-table">
      <thead>
        <tr>
          <th scope="col">Kode</th>
          <th scope="col">Akun</th>
          <th scope="col" className="num">
            Saldo Awal
          </th>
          <th scope="col" className="num">
            Perubahan Periode
          </th>
          <th scope="col" className="num">
            Saldo Akhir
          </th>
        </tr>
      </thead>
      <tbody>
        {rows.map((row) => {
          const amounts = equityRowAmounts(row);
          return (
            <tr key={row.account_id ?? "net-result"}>
              <td>{row.code ?? "—"}</td>
              <td>{row.name}</td>
              <td className="num">{formatMoney(amounts.opening.toString(), currency)}</td>
              <td className="num">{formatMoney(amounts.period.toString(), currency)}</td>
              <td className="num">{formatMoney(amounts.closing.toString(), currency)}</td>
            </tr>
          );
        })}
      </tbody>
      <tfoot>
        <tr>
          <th scope="row" colSpan={4}>
            Total Ekuitas Akhir
          </th>
          <td className="num">{formatMoney(total.toString(), currency)}</td>
        </tr>
      </tfoot>
    </table>
  );
}

function cashFlowBucketValue(totals: CashFlowTotals, bucket: CashFlowBucket): Decimal {
  switch (bucket) {
    case "opening_cash":
      return totals.opening;
    case "operating":
      return totals.operating;
    case "investing":
      return totals.investing;
    case "financing":
      return totals.financing;
    case "closing_cash":
      return totals.closing;
  }
}

function CashFlowTable({ rows, currency }: { rows: readonly CashFlowRow[]; currency: string }) {
  const totals = cashFlowTotals(rows);
  return (
    <table className="record-table">
      <thead>
        <tr>
          <th scope="col">Kategori</th>
          <th scope="col" className="num">
            Jumlah
          </th>
        </tr>
      </thead>
      <tbody>
        {CASH_FLOW_BUCKET_ORDER.map((bucket) => (
          <tr key={bucket}>
            <td>{CASH_FLOW_BUCKET_LABELS[bucket]}</td>
            <td className="num">
              {formatMoney(cashFlowBucketValue(totals, bucket).toString(), currency)}
            </td>
          </tr>
        ))}
      </tbody>
      <tfoot>
        <tr>
          <th scope="row">Status</th>
          <td className="num">
            <span
              className={`status-badge status-badge-${totals.reconciled ? "success" : "critical"}`}
            >
              {totals.reconciled ? "Rekonsiliasi cocok" : "Tidak cocok"}
            </span>
          </td>
        </tr>
      </tfoot>
    </table>
  );
}

function generalLedgerEntryTypeLabel(entryType: string): string {
  return (ENTRY_TYPE_LABELS as Record<string, string>)[entryType] ?? entryType;
}

function GeneralLedgerTable({
  rows,
  accounts,
  accountId,
  currency,
  entity,
}: {
  rows: readonly GeneralLedgerRow[];
  accounts: readonly LedgerAccountRow[];
  accountId: string | null;
  currency: string;
  entity: string | undefined;
}) {
  if (accounts.length === 0) {
    return (
      <div className="list-empty">
        <p>Tidak ada akun yang dapat dipilih.</p>
      </div>
    );
  }
  const account = accounts.find((a) => a.id === accountId);
  if (rows.length === 0) {
    return (
      <div className="list-empty">
        <p>Tidak ada transaksi terposting untuk akun ini pada periode ini.</p>
      </div>
    );
  }
  const totals = generalLedgerTotals(rows);
  return (
    <table className="record-table">
      <thead>
        <tr>
          <th scope="col" colSpan={6}>
            {account ? `${account.code} · ${account.name}` : "Akun"}
          </th>
        </tr>
        <tr>
          <th scope="col">Tanggal</th>
          <th scope="col">No. Jurnal</th>
          <th scope="col">Tipe</th>
          <th scope="col">Deskripsi</th>
          <th scope="col" className="num">
            Debit
          </th>
          <th scope="col" className="num">
            Kredit
          </th>
          <th scope="col" className="num">
            Saldo Berjalan
          </th>
        </tr>
      </thead>
      <tbody>
        {rows.map((row, index) => {
          const journalHref = entity
            ? `/accounting/journal/${row.journal_id}?entity=${encodeURIComponent(entity)}`
            : `/accounting/journal/${row.journal_id}`;
          return (
            <tr key={`${row.journal_id}-${index}`}>
              <td>{formatShortDate(row.entry_date)}</td>
              <td>
                <Link href={journalHref}>{row.journal_number}</Link>
              </td>
              <td>{generalLedgerEntryTypeLabel(row.entry_type)}</td>
              <td>{row.description ?? "—"}</td>
              <td className="num">
                {Number(row.debit) > 0 ? formatMoney(row.debit, currency) : "—"}
              </td>
              <td className="num">
                {Number(row.credit) > 0 ? formatMoney(row.credit, currency) : "—"}
              </td>
              <td className="num">{formatMoney(row.running_balance, currency)}</td>
            </tr>
          );
        })}
      </tbody>
      <tfoot>
        <tr>
          <th scope="row" colSpan={4}>
            Total Periode
          </th>
          <td className="num">{formatMoney(totals.debit.toString(), currency)}</td>
          <td className="num">{formatMoney(totals.credit.toString(), currency)}</td>
          <td className="num">{formatMoney(totals.closingBalance.toString(), currency)}</td>
        </tr>
      </tfoot>
    </table>
  );
}

function CustomReportTable({
  datasets,
  datasetKey,
  rows,
  currency,
}: {
  datasets: readonly ReportDatasetCatalogRow[];
  datasetKey: string | null;
  rows: readonly CustomReportRow[];
  currency: string;
}) {
  if (datasets.length === 0) {
    return (
      <div className="list-empty">
        <p>Tidak ada dataset laporan yang dapat Anda akses.</p>
      </div>
    );
  }
  const dataset = datasets.find((d) => d.dataset_key === datasetKey);
  if (rows.length === 0) {
    return (
      <div className="list-empty">
        <p>Tidak ada data pada periode ini.</p>
      </div>
    );
  }
  const totals = customReportTotals(rows);
  return (
    <table className="record-table">
      <thead>
        <tr>
          <th scope="col" colSpan={3}>
            {dataset?.description ?? dataset?.name ?? "Laporan"}
          </th>
        </tr>
        <tr>
          <th scope="col">{dataset?.dimension_label ?? "Dimensi"}</th>
          <th scope="col" className="num">
            Jumlah Transaksi
          </th>
          <th scope="col" className="num">
            {dataset?.measure_label ?? "Total"}
          </th>
        </tr>
      </thead>
      <tbody>
        {rows.map((row) => (
          <tr key={row.dimension}>
            <td>{row.dimension}</td>
            <td className="num">{row.row_count}</td>
            <td className="num">{formatMoney(row.total_amount, currency)}</td>
          </tr>
        ))}
      </tbody>
      <tfoot>
        <tr>
          <th scope="row">Total</th>
          <td className="num">{totals.rowCount}</td>
          <td className="num">{formatMoney(totals.totalAmount.toString(), currency)}</td>
        </tr>
      </tfoot>
    </table>
  );
}

function consolidatedEntityTypeLabel(entityType: string): string {
  if (entityType === "company") return "Usaha";
  if (entityType === "personal") return "Rumah Tangga";
  return entityType;
}

function ConsolidatedAnalysisTable({
  eligible,
  rows,
  currencyByEntity,
}: {
  eligible: readonly Membership[];
  rows: readonly ConsolidatedCashPositionRow[];
  currencyByEntity: Readonly<Record<string, string>>;
}) {
  if (eligible.length === 0) {
    return (
      <div className="list-empty">
        <p>Anda tidak memiliki izin lintas-Entity untuk laporan ini.</p>
      </div>
    );
  }
  if (rows.length === 0) {
    return (
      <div className="list-empty">
        <p>Pilih minimal satu Entity untuk melihat posisi kas konsolidasi.</p>
      </div>
    );
  }
  const totals = consolidatedCashPositionTotals(rows, currencyByEntity);
  return (
    <table className="record-table">
      <thead>
        <tr>
          <th scope="col">Kode</th>
          <th scope="col">Entity</th>
          <th scope="col">Tipe</th>
          <th scope="col">Mata Uang</th>
          <th scope="col" className="num">
            Saldo Kas
          </th>
        </tr>
      </thead>
      <tbody>
        {rows.map((row) => (
          <tr key={row.entity_id}>
            <td>{row.entity_code}</td>
            <td>{row.entity_name}</td>
            <td>{consolidatedEntityTypeLabel(row.entity_type)}</td>
            <td>{currencyByEntity[row.entity_id] ?? "—"}</td>
            <td className="num">
              {formatMoney(row.cash_balance, currencyByEntity[row.entity_id] ?? "IDR")}
            </td>
          </tr>
        ))}
      </tbody>
      <tfoot>
        <tr>
          <th scope="row" colSpan={4}>
            Total ({totals.entityCount} Entity)
          </th>
          <td className="num">
            {totals.totalCashBalance
              ? formatMoney(totals.totalCashBalance.toString(), currencyByEntity[rows[0].entity_id])
              : "— (mata uang berbeda)"}
          </td>
        </tr>
      </tfoot>
    </table>
  );
}

function loanHref(entity: string | undefined, loanId: string): string {
  return entity
    ? `/assets/loans/${loanId}?entity=${encodeURIComponent(entity)}`
    : `/assets/loans/${loanId}`;
}

function LoansDueTable({
  rows,
  canView,
  currency,
  entity,
}: {
  rows: readonly LoanDueRow[];
  canView: boolean;
  currency: string;
  entity: string | undefined;
}) {
  if (!canView) {
    return (
      <div className="list-empty">
        <p>Anda tidak memiliki izin untuk melihat laporan pinjaman.</p>
      </div>
    );
  }
  if (rows.length === 0) {
    return (
      <div className="list-empty">
        <p>Tidak ada cicilan yang jatuh tempo pada rentang ini.</p>
      </div>
    );
  }
  const totals = loanDueTotals(rows);
  return (
    <table className="record-table">
      <thead>
        <tr>
          <th scope="col">No. Pinjaman</th>
          <th scope="col">Arah</th>
          <th scope="col">Pihak</th>
          <th scope="col">Cicilan Ke</th>
          <th scope="col">Jatuh Tempo</th>
          <th scope="col" className="num">
            Pokok Tertunggak
          </th>
          <th scope="col" className="num">
            Bunga Tertunggak
          </th>
          <th scope="col" className="num">
            Biaya Tertunggak
          </th>
          <th scope="col">Status</th>
        </tr>
      </thead>
      <tbody>
        {rows.map((row) => {
          const badge = loanScheduleStateBadge(row.state, row.overdue);
          return (
            <tr key={`${row.loan_id}-${row.seq}`}>
              <td>
                <Link href={loanHref(entity, row.loan_id)}>{row.loan_number}</Link>
              </td>
              <td>{LOAN_DIRECTION_LABELS[row.direction]}</td>
              <td>{row.counterparty_name}</td>
              <td>{row.seq}</td>
              <td>
                {formatShortDate(row.due_date)}
                {row.overdue ? ` (${row.days_overdue} hari)` : null}
              </td>
              <td className="num">{formatMoney(row.principal_outstanding, currency)}</td>
              <td className="num">{formatMoney(row.interest_outstanding, currency)}</td>
              <td className="num">{formatMoney(row.fee_outstanding, currency)}</td>
              <td>
                <span className={`status-badge status-badge-${badge.tone}`}>{badge.text}</span>
              </td>
            </tr>
          );
        })}
      </tbody>
      <tfoot>
        <tr>
          <th scope="row" colSpan={5}>
            Total ({totals.overdueCount} terlambat)
          </th>
          <td className="num">{formatMoney(totals.principalOutstanding.toString(), currency)}</td>
          <td className="num">{formatMoney(totals.interestOutstanding.toString(), currency)}</td>
          <td className="num">{formatMoney(totals.feeOutstanding.toString(), currency)}</td>
          <td />
        </tr>
      </tfoot>
    </table>
  );
}

function LoanSummaryTable({
  rows,
  canView,
  currency,
  entity,
}: {
  rows: readonly LoanSummaryRow[];
  canView: boolean;
  currency: string;
  entity: string | undefined;
}) {
  if (!canView) {
    return (
      <div className="list-empty">
        <p>Anda tidak memiliki izin untuk melihat laporan pinjaman.</p>
      </div>
    );
  }
  if (rows.length === 0) {
    return (
      <div className="list-empty">
        <p>Tidak ada pinjaman pada periode ini.</p>
      </div>
    );
  }
  const totals = loanSummaryTotals(rows);
  return (
    <table className="record-table">
      <thead>
        <tr>
          <th scope="col">No. Pinjaman</th>
          <th scope="col">Arah</th>
          <th scope="col">Pihak</th>
          <th scope="col" className="num">
            Pokok Awal
          </th>
          <th scope="col" className="num">
            Pencairan
          </th>
          <th scope="col" className="num">
            Pokok Dibayar
          </th>
          <th scope="col" className="num">
            Pokok Dihapusbukukan
          </th>
          <th scope="col" className="num">
            Pokok Akhir
          </th>
          <th scope="col" className="num">
            Bunga Dibayar
          </th>
          <th scope="col" className="num">
            Biaya Dibayar
          </th>
        </tr>
      </thead>
      <tbody>
        {rows.map((row) => (
          <tr key={row.loan_id}>
            <td>
              <Link href={loanHref(entity, row.loan_id)}>{row.loan_number}</Link>
            </td>
            <td>{LOAN_DIRECTION_LABELS[row.direction]}</td>
            <td>{row.counterparty_name}</td>
            <td className="num">{formatMoney(row.opening_principal, currency)}</td>
            <td className="num">{formatMoney(row.proceeds, currency)}</td>
            <td className="num">{formatMoney(row.principal_repaid, currency)}</td>
            <td className="num">{formatMoney(row.principal_written_off, currency)}</td>
            <td className="num">{formatMoney(row.closing_principal, currency)}</td>
            <td className="num">{formatMoney(row.interest_paid, currency)}</td>
            <td className="num">{formatMoney(row.fees_paid, currency)}</td>
          </tr>
        ))}
      </tbody>
      <tfoot>
        <tr>
          <th scope="row" colSpan={3}>
            Total
          </th>
          <td className="num">{formatMoney(totals.openingPrincipal.toString(), currency)}</td>
          <td className="num">{formatMoney(totals.proceeds.toString(), currency)}</td>
          <td className="num">{formatMoney(totals.principalRepaid.toString(), currency)}</td>
          <td className="num">{formatMoney(totals.principalWrittenOff.toString(), currency)}</td>
          <td className="num">{formatMoney(totals.closingPrincipal.toString(), currency)}</td>
          <td className="num">{formatMoney(totals.interestPaid.toString(), currency)}</td>
          <td className="num">{formatMoney(totals.feesPaid.toString(), currency)}</td>
        </tr>
      </tfoot>
    </table>
  );
}

function payrollRunHref(entity: string | undefined, runId: string): string {
  return entity
    ? `/payroll/runs/${runId}?entity=${encodeURIComponent(entity)}`
    : `/payroll/runs/${runId}`;
}

function PayrollSummaryTable({
  rows,
  canView,
  currency,
  entity,
}: {
  rows: readonly PayrollSummaryRow[];
  canView: boolean;
  currency: string;
  entity: string | undefined;
}) {
  if (!canView) {
    return (
      <div className="list-empty">
        <p>Anda tidak memiliki izin untuk melihat laporan payroll.</p>
      </div>
    );
  }
  if (rows.length === 0) {
    return (
      <div className="list-empty">
        <p>Tidak ada payroll run pada periode ini.</p>
      </div>
    );
  }
  const totals = payrollSummaryTotals(rows);
  return (
    <table className="record-table">
      <thead>
        <tr>
          <th scope="col">No. Run</th>
          <th scope="col">Periode</th>
          <th scope="col">Status</th>
          <th scope="col" className="num">
            Jml. Karyawan
          </th>
          <th scope="col" className="num">
            Gaji Kotor
          </th>
          <th scope="col" className="num">
            Tunjangan Pajak
          </th>
          <th scope="col" className="num">
            BPJS Karyawan
          </th>
          <th scope="col" className="num">
            BPJS Perusahaan
          </th>
          <th scope="col" className="num">
            PPh 21
          </th>
          <th scope="col" className="num">
            Gaji Bersih
          </th>
          <th scope="col" className="num">
            Belum Dibayar
          </th>
          <th scope="col" className="num">
            BPJS Belum Disetor
          </th>
          <th scope="col" className="num">
            PPh 21 Belum Disetor
          </th>
        </tr>
      </thead>
      <tbody>
        {rows.map((row) => {
          const badge = payrollRunStatusBadge(row.status);
          return (
            <tr key={`${row.run_id}-${row.revision}`}>
              <td>
                <Link href={payrollRunHref(entity, row.run_id)}>{row.run_number}</Link>
              </td>
              <td>{payrollPeriodName(row.period_start)}</td>
              <td>
                <span className={`status-badge status-badge-${badge.tone}`}>{badge.text}</span>
              </td>
              <td className="num">{row.employee_count}</td>
              <td className="num">{formatMoney(row.gross_pay, currency)}</td>
              <td className="num">
                {row.tax_allowance === null ? "—" : formatMoney(row.tax_allowance, currency)}
              </td>
              <td className="num">{formatMoney(row.employee_bpjs, currency)}</td>
              <td className="num">{formatMoney(row.employer_bpjs, currency)}</td>
              <td className="num">{row.pph21 === null ? "—" : formatMoney(row.pph21, currency)}</td>
              <td className="num">{formatMoney(row.net_pay, currency)}</td>
              <td className="num">{formatMoney(row.net_unpaid, currency)}</td>
              <td className="num">{formatMoney(row.bpjs_unpaid, currency)}</td>
              <td className="num">
                {row.pph21_period_outstanding === null
                  ? "—"
                  : formatMoney(row.pph21_period_outstanding, currency)}
              </td>
            </tr>
          );
        })}
      </tbody>
      <tfoot>
        <tr>
          <th scope="row" colSpan={4}>
            Total
          </th>
          <td className="num">{formatMoney(totals.grossPay.toString(), currency)}</td>
          <td className="num">
            {totals.taxAllowance === null
              ? "—"
              : formatMoney(totals.taxAllowance.toString(), currency)}
          </td>
          <td className="num">{formatMoney(totals.employeeBpjs.toString(), currency)}</td>
          <td className="num">{formatMoney(totals.employerBpjs.toString(), currency)}</td>
          <td className="num">
            {totals.pph21 === null ? "—" : formatMoney(totals.pph21.toString(), currency)}
          </td>
          <td className="num">{formatMoney(totals.netPay.toString(), currency)}</td>
          <td className="num">{formatMoney(totals.netUnpaid.toString(), currency)}</td>
          <td className="num">{formatMoney(totals.bpjsUnpaid.toString(), currency)}</td>
          <td className="num">
            {totals.pph21PeriodOutstanding === null
              ? "—"
              : formatMoney(totals.pph21PeriodOutstanding.toString(), currency)}
          </td>
        </tr>
      </tfoot>
    </table>
  );
}

function PayrollControlTable({
  rows,
  canView,
  currency,
}: {
  rows: readonly PayrollControlRow[];
  canView: boolean;
  currency: string;
}) {
  if (!canView) {
    return (
      <div className="list-empty">
        <p>Anda tidak memiliki izin untuk melihat laporan payroll.</p>
      </div>
    );
  }
  if (rows.length === 0) {
    return (
      <div className="list-empty">
        <p>Tidak ada akun kontrol payroll untuk Entity ini.</p>
      </div>
    );
  }
  const summary = payrollControlSummary(rows);
  return (
    <>
      <p className="list-screen-summary">
        {summary.mismatchCount === 0
          ? `Seluruh ${summary.accountCount} akun seimbang.`
          : `${summary.mismatchCount} dari ${summary.accountCount} akun tidak seimbang.`}
      </p>
      <table className="record-table">
        <thead>
          <tr>
            <th scope="col">Akun</th>
            <th scope="col" className="num">
              Sub-Ledger
            </th>
            <th scope="col" className="num">
              Ledger (Payroll Run)
            </th>
            <th scope="col" className="num">
              Ledger (Lainnya)
            </th>
            <th scope="col" className="num">
              Ledger (Total)
            </th>
            <th scope="col" className="num">
              Selisih
            </th>
            <th scope="col">Status</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((row) => {
            const balanced = payrollControlRowBalanced(row);
            return (
              <tr key={row.account_key}>
                <td>{payrollControlAccountLabel(row.account_key)}</td>
                <td className="num">{formatMoney(row.sub_ledger, currency)}</td>
                <td className="num">{formatMoney(row.ledger_workflow, currency)}</td>
                <td className="num">{formatMoney(row.ledger_other, currency)}</td>
                <td className="num">{formatMoney(row.ledger_total, currency)}</td>
                <td className="num">{formatMoney(row.difference, currency)}</td>
                <td>
                  <span
                    className={`status-badge status-badge-${balanced ? "success" : "critical"}`}
                  >
                    {balanced ? "Seimbang" : "Tidak Seimbang"}
                  </span>
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </>
  );
}

function FiscalScheduleTable({
  rows,
  assets,
  assetId,
  canView,
  currency,
}: {
  rows: readonly FiscalScheduleRow[];
  assets: readonly AssetRow[];
  assetId: string | null;
  canView: boolean;
  currency: string;
}) {
  if (!canView) {
    return (
      <div className="list-empty">
        <p>Anda tidak memiliki izin untuk melihat jadwal penyusutan fiskal.</p>
      </div>
    );
  }
  if (assets.length === 0) {
    return (
      <div className="list-empty">
        <p>Tidak ada aset yang dapat dipilih.</p>
      </div>
    );
  }
  const asset = assets.find((a) => a.asset_id === assetId);
  if (rows.length === 0) {
    return (
      <div className="list-empty">
        <p>Aset ini tidak memiliki jadwal penyusutan fiskal.</p>
      </div>
    );
  }
  const totalDepreciation = fiscalScheduleTotalDepreciation(rows);
  return (
    <table className="record-table">
      <thead>
        <tr>
          <th scope="col" colSpan={4}>
            {asset ? `${asset.asset_code} · ${asset.name}` : "Aset"}
          </th>
        </tr>
        <tr>
          <th scope="col">Tahun Fiskal</th>
          <th scope="col" className="num">
            Nilai Awal
          </th>
          <th scope="col" className="num">
            Penyusutan
          </th>
          <th scope="col" className="num">
            Nilai Akhir
          </th>
        </tr>
      </thead>
      <tbody>
        {rows.map((row) => (
          <tr key={row.fiscal_year}>
            <td>
              {row.fiscal_year} (v{row.rule_version})
            </td>
            <td className="num">{formatMoney(row.opening_value, currency)}</td>
            <td className="num">{formatMoney(row.depreciation, currency)}</td>
            <td className="num">{formatMoney(row.closing_value, currency)}</td>
          </tr>
        ))}
      </tbody>
      <tfoot>
        <tr>
          <th scope="row" colSpan={2}>
            Total Penyusutan Fiskal
          </th>
          <td className="num">{formatMoney(totalDepreciation.toString(), currency)}</td>
          <td />
        </tr>
      </tfoot>
    </table>
  );
}

function AssetControlTable({
  rows,
  canView,
  currency,
}: {
  rows: readonly AssetControlRow[];
  canView: boolean;
  currency: string;
}) {
  if (!canView) {
    return (
      <div className="list-empty">
        <p>Anda tidak memiliki izin untuk melihat kontrol aset tetap.</p>
      </div>
    );
  }
  if (rows.length === 0) {
    return (
      <div className="list-empty">
        <p>Tidak ada akun kontrol aset tetap untuk Entity ini.</p>
      </div>
    );
  }
  const summary = assetControlSummary(rows);
  return (
    <>
      <p className="list-screen-summary">
        {summary.mismatchCount === 0
          ? `Seluruh ${summary.accountCount} akun seimbang.`
          : `${summary.mismatchCount} dari ${summary.accountCount} akun tidak seimbang.`}
      </p>
      <table className="record-table">
        <thead>
          <tr>
            <th scope="col">Akun</th>
            <th scope="col" className="num">
              Sub-Ledger
            </th>
            <th scope="col" className="num">
              Ledger (Alur Kerja Aset)
            </th>
            <th scope="col" className="num">
              Ledger (Lainnya)
            </th>
            <th scope="col" className="num">
              Ledger (Total)
            </th>
            <th scope="col" className="num">
              Selisih
            </th>
            <th scope="col">Status</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((row) => {
            const balanced = assetControlRowBalanced(row);
            return (
              <tr key={row.account_key}>
                <td>{assetControlAccountLabel(row.account_key)}</td>
                <td className="num">{formatMoney(row.sub_ledger, currency)}</td>
                <td className="num">{formatMoney(row.ledger_workflow, currency)}</td>
                <td className="num">{formatMoney(row.ledger_other, currency)}</td>
                <td className="num">{formatMoney(row.ledger_total, currency)}</td>
                <td className="num">{formatMoney(row.difference, currency)}</td>
                <td>
                  <span
                    className={`status-badge status-badge-${balanced ? "success" : "critical"}`}
                  >
                    {balanced ? "Seimbang" : "Tidak Seimbang"}
                  </span>
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </>
  );
}
