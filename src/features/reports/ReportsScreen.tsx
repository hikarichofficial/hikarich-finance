import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import type { Decimal } from "@/domain/money/decimal";
import { ENTRY_TYPE_LABELS } from "@/domain/accounting/journalList";
import {
  BALANCE_SHEET_SECTION_ORDER,
  CASH_FLOW_BUCKET_LABELS,
  CASH_FLOW_BUCKET_ORDER,
  PNL_SECTION_ORDER,
  balanceSheetTotals,
  cashFlowTotals,
  customReportTotals,
  equityClosingTotal,
  equityRowAmounts,
  generalLedgerTotals,
  groupByAccountClass,
  hasPnlComparison,
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
  CustomReportRow,
  EquityChangeRow,
  GeneralLedgerRow,
  ProfitAndLossRow,
  ReportDatasetCatalogRow,
} from "@/schemas/reports";
import type { LedgerAccountRow } from "@/schemas/accounting";
import { formatShortDate } from "./format";

export type ReportStatement = "pnl" | "balance_sheet" | "equity" | "cashflow" | "gl" | "custom";

export const REPORT_STATEMENT_TABS: readonly { value: ReportStatement; label: string }[] = [
  { value: "pnl", label: "Laba Rugi" },
  { value: "balance_sheet", label: "Neraca" },
  { value: "equity", label: "Perubahan Ekuitas" },
  { value: "cashflow", label: "Arus Kas" },
  { value: "gl", label: "Buku Besar" },
  { value: "custom", label: "Laporan Kustom" },
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
 * RPC returned, grouped and summed once, in the database. Consolidated Analysis is still a later Part 4
 * increment (decision 189); the other Reports nav sub-items (Sales/Purchase, a standalone Cashflow view,
 * Tax, Payroll, Assets/Loans, Saved Reports) have no P12 RPC behind them yet and fall through to the
 * `[...slug]` "coming soon" placeholder (decision 157's precedent) until one exists. Every figure here is
 * the database's own debit/credit, re-signed once via `naturalAmount` (`@/domain/reports`) -- never a
 * second computation of the same fact.
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
      {data.statement === "balance_sheet" ? (
        <label>
          Per tanggal
          <input type="date" name="as_of" defaultValue={data.asOf} />
        </label>
      ) : (
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
