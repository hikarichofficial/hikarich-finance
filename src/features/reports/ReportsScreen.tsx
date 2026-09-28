import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import type { Decimal } from "@/domain/money/decimal";
import {
  BALANCE_SHEET_SECTION_ORDER,
  CASH_FLOW_BUCKET_LABELS,
  CASH_FLOW_BUCKET_ORDER,
  PNL_SECTION_ORDER,
  balanceSheetTotals,
  cashFlowTotals,
  equityClosingTotal,
  equityRowAmounts,
  groupByAccountClass,
  pnlNetIncome,
  type CashFlowBucket,
  type CashFlowTotals,
  type ReportDateRange,
} from "@/domain/reports/reports";
import type {
  BalanceSheetRow,
  CashFlowRow,
  EquityChangeRow,
  ProfitAndLossRow,
} from "@/schemas/reports";

export type ReportStatement = "pnl" | "balance_sheet" | "equity" | "cashflow";

export const REPORT_STATEMENT_TABS: readonly { value: ReportStatement; label: string }[] = [
  { value: "pnl", label: "Laba Rugi" },
  { value: "balance_sheet", label: "Neraca" },
  { value: "equity", label: "Perubahan Ekuitas" },
  { value: "cashflow", label: "Arus Kas" },
];

export type ReportsData =
  | { statement: "pnl"; range: ReportDateRange; rows: readonly ProfitAndLossRow[] }
  | { statement: "balance_sheet"; asOf: string; rows: readonly BalanceSheetRow[] }
  | { statement: "equity"; range: ReportDateRange; rows: readonly EquityChangeRow[] }
  | { statement: "cashflow"; range: ReportDateRange; rows: readonly CashFlowRow[] };

function buildTabHref(entity: string | undefined, statement: ReportStatement): string {
  const params = new URLSearchParams();
  if (entity) params.set("entity", entity);
  params.set("statement", statement);
  return `/reports?${params.toString()}`;
}

/**
 * Financial Reports (P13 Part 4, Step 12 §3-§5, first increment; nav's "Financial Reports" -> `/reports`,
 * decision 155). The four canonical statements P12 already computes -- Profit & Loss, Balance Sheet,
 * Statement of Changes in Equity, Cash Flow Statement -- switched by `?statement=`, each with its own date
 * filter form (Standard List Screen Pattern, Step 09 §9, with the usual status-filter tabs standing in for
 * a statement switcher instead). General Ledger drill-down, the Custom Report Builder and Consolidated
 * Analysis are their own later Part 4 increments (decision 189); the other Reports nav sub-items
 * (Sales/Purchase, a standalone Cashflow view, Tax, Payroll, Assets/Loans, Saved Reports) have no P12 RPC
 * behind them yet and fall through to the `[...slug]` "coming soon" placeholder (decision 157's precedent)
 * until one exists. Every figure here is the database's own debit/credit, re-signed once via
 * `naturalAmount` (`@/domain/reports`) -- never a second computation of the same fact.
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
    </div>
  );
}

function RangeForm({ data, entity }: { data: ReportsData; entity: string | undefined }) {
  return (
    <form method="get" className="list-search-form">
      {entity ? <input type="hidden" name="entity" value={entity} /> : null}
      <input type="hidden" name="statement" value={data.statement} />
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
  return (
    <table className="record-table">
      <thead>
        <tr>
          <th scope="col">Kode</th>
          <th scope="col">Akun</th>
          <th scope="col" className="num">
            Jumlah
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
            {net.isNegative() ? "Rugi Bersih" : "Laba Bersih"}
          </th>
          <td className="num">{formatMoney(net.toString(), currency)}</td>
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
