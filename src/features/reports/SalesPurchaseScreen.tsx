import { formatMoney } from "@/domain/money/format";
import {
  DIMENSION_LABELS,
  SIDE_LABELS,
  dimensionOptions,
  salesPurchaseTotals,
} from "@/domain/reports/salesPurchase";
import type {
  SalesPurchaseDimension,
  SalesPurchaseRow,
  SalesPurchaseSide,
} from "@/schemas/reports";
import { formatShortDate } from "./format";
import { ReportExportButtons } from "./ReportExportButtons";

/**
 * Sales/Purchase report (Step 09 §19, decision 252): issued invoices (sales) or approved bills and
 * confirmed expenses (purchases) in a date range, grouped by one dimension, in base currency before and
 * after tax. Every figure comes from `sales_purchase_report`; only the totals row is summed here, exactly.
 */
export function SalesPurchaseScreen({
  rows,
  side,
  dimension,
  from,
  to,
  currency,
  entity,
  canView,
}: {
  rows: readonly SalesPurchaseRow[];
  side: SalesPurchaseSide;
  dimension: SalesPurchaseDimension;
  from: string;
  to: string;
  currency: string;
  entity: string | undefined;
  canView: boolean;
}) {
  const totals = salesPurchaseTotals(rows);
  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Laporan Penjualan &amp; Pembelian</h1>
          <p className="list-screen-summary">
            {SIDE_LABELS[side]} per {DIMENSION_LABELS[dimension].toLowerCase()},{" "}
            {formatShortDate(from)} – {formatShortDate(to)}. Penjualan: invoice terbit. Pembelian:
            tagihan disetujui dan beban dikonfirmasi.
          </p>
        </div>
        <ReportExportButtons fileName={`laporan-${side === "sales" ? "penjualan" : "pembelian"}`} />
      </header>

      <div className="list-screen-toolbar">
        <form method="get" className="list-search-form">
          {entity ? <input type="hidden" name="entity" value={entity} /> : null}
          <label>
            Jenis
            <select name="side" defaultValue={side}>
              <option value="sales">{SIDE_LABELS.sales}</option>
              <option value="purchases">{SIDE_LABELS.purchases}</option>
            </select>
          </label>
          <label>
            Kelompokkan per
            <select name="by" defaultValue={dimension}>
              {(["party", "category", "product", "month"] as const).map((d) => (
                <option key={d} value={d} disabled={!dimensionOptions(side).includes(d)}>
                  {DIMENSION_LABELS[d]}
                </option>
              ))}
            </select>
          </label>
          <label>
            Dari
            <input type="date" name="from" defaultValue={from} />
          </label>
          <label>
            Sampai
            <input type="date" name="to" defaultValue={to} />
          </label>
          <button type="submit" className="btn-secondary">
            Terapkan
          </button>
        </form>
      </div>

      {!canView ? (
        <div className="list-empty">
          <p>Anda tidak memiliki izin melihat data {SIDE_LABELS[side].toLowerCase()}.</p>
        </div>
      ) : rows.length === 0 ? (
        <div className="list-empty">
          <p>Tidak ada transaksi pada periode ini.</p>
        </div>
      ) : (
        <div data-report-root>
          <table className="record-table">
            <thead>
              <tr>
                <th scope="col">{DIMENSION_LABELS[dimension]}</th>
                <th scope="col" className="num">
                  Dokumen
                </th>
                <th scope="col" className="num">
                  Sebelum Pajak
                </th>
                <th scope="col" className="num">
                  Termasuk Pajak
                </th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r, i) => (
                <tr key={`${r.dimension_id ?? "none"}-${r.period_month ?? i}`}>
                  <td>{r.dimension_label}</td>
                  <td className="num">{r.document_count}</td>
                  <td className="num">{formatMoney(r.net_amount, currency)}</td>
                  <td className="num">{formatMoney(r.gross_amount, currency)}</td>
                </tr>
              ))}
            </tbody>
            <tfoot>
              <tr>
                <td>
                  <strong>Total</strong>
                </td>
                <td className="num">
                  <strong>{totals.documents}</strong>
                </td>
                <td className="num">
                  <strong>{formatMoney(totals.net, currency)}</strong>
                </td>
                <td className="num">
                  <strong>{formatMoney(totals.gross, currency)}</strong>
                </td>
              </tr>
            </tfoot>
          </table>
        </div>
      )}
    </div>
  );
}
