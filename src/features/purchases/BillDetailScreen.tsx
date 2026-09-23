import Link from "next/link";
import { formatMoney, formatPlain } from "@/domain/money/format";
import {
  billActivityTimeline,
  billListStatus,
  type BillListRow,
} from "@/domain/purchases/billList";
import { PURCHASE_TREATMENT_LABELS } from "@/domain/purchases/bill";
import { SETTLEMENT_LABELS } from "@/domain/purchases/settlement";
import type { BillDetail } from "@/services/purchases/purchases";
import { BillActions, type BillActionPermissions } from "./BillActions";
import { formatShortDate } from "./format";

/**
 * Bill Detail (P13 Part 3b, Step 09 §10, §12): Header / Summary / Line Items / Activity / Accounting / Tax /
 * Audit, following the same order and "coming soon" placeholder principle (DECISIONS 157) that
 * `src/features/sales/InvoiceDetailScreen.tsx` established in Part 3a. Line Items is not one of Step 09
 * §10's seven named areas, but the data already exists on every bill (`bill_lines`, Step 09 §12: "Record
 * Bill supports line items, category, asset classification...") and showing it plainly here is more honest
 * than folding it into Summary or inventing a placeholder for data that already exists. No attachment/receipt
 * upload exists yet (that is part of the same deferred "Record Bill" increment as the create form), so
 * Documents stays a placeholder rather than showing an empty upload control.
 */
export function BillDetailScreen({
  bill,
  permissions,
  backHref,
}: {
  bill: BillDetail;
  permissions: BillActionPermissions;
  backHref: string;
}) {
  const statusRow: BillListRow = {
    bill_id: bill.id,
    bill_number: bill.bill_number,
    vendor_id: bill.vendor_id,
    vendor_name: bill.vendor_name,
    currency: bill.currency,
    status: bill.status,
    bill_date: bill.bill_date,
    due_date: bill.due_date,
    total: bill.total,
    outstanding: bill.outstanding,
    settlement_status: bill.settlement_status,
    is_overdue: bill.is_overdue,
    days_overdue: bill.days_overdue,
  };
  const status = billListStatus(statusRow);
  const timeline = billActivityTimeline(bill);

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={backHref}>← Kembali ke daftar tagihan</Link>
      </p>

      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Tagihan Pembelian</p>
          <h1>{bill.bill_number ?? "Draf"}</h1>
          <p className="record-detail-counterparty">{bill.vendor_name}</p>
        </div>
        <div className="record-detail-header-end">
          <span className={`status-badge status-badge-${status.tone}`}>{status.text}</span>
          <p className="record-detail-amount">{formatMoney(bill.total, bill.currency)}</p>
          <p className="record-detail-dates">
            {formatShortDate(bill.bill_date)} · Jatuh tempo {formatShortDate(bill.due_date)}
          </p>
        </div>
      </header>

      <BillActions billId={bill.id} status={bill.status} permissions={permissions} />

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Ringkasan</h2>
        </div>
        <dl className="record-summary-grid">
          <div>
            <dt>Total Tagihan</dt>
            <dd>{formatMoney(bill.total, bill.currency)}</dd>
          </div>
          <div>
            <dt>Subtotal</dt>
            <dd>{formatMoney(bill.subtotal, bill.currency)}</dd>
          </div>
          <div>
            <dt>Pajak</dt>
            <dd>{formatMoney(bill.tax_total, bill.currency)}</dd>
          </div>
          {bill.settled !== null ? (
            <div>
              <dt>Sudah Dibayar</dt>
              <dd>{formatMoney(bill.settled, bill.currency)}</dd>
            </div>
          ) : null}
          {bill.outstanding !== null ? (
            <div>
              <dt>Sisa Tagihan</dt>
              <dd>{formatMoney(bill.outstanding, bill.currency)}</dd>
            </div>
          ) : null}
          {bill.settlement_status ? (
            <div>
              <dt>Status Pelunasan</dt>
              <dd>{SETTLEMENT_LABELS[bill.settlement_status]}</dd>
            </div>
          ) : null}
          {bill.is_overdue ? (
            <div>
              <dt>Status Jatuh Tempo</dt>
              <dd>Jatuh tempo, belum dilunasi</dd>
            </div>
          ) : null}
          {bill.vendor_reference ? (
            <div>
              <dt>Referensi Vendor</dt>
              <dd>{bill.vendor_reference}</dd>
            </div>
          ) : null}
          {bill.notes ? (
            <div>
              <dt>Catatan</dt>
              <dd>{bill.notes}</dd>
            </div>
          ) : null}
        </dl>
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Rincian Item</h2>
        </div>
        {bill.lines.length === 0 ? (
          <p className="dashboard-empty">Tagihan ini belum memiliki baris item.</p>
        ) : (
          <table className="record-table">
            <thead>
              <tr>
                <th scope="col">Deskripsi</th>
                <th scope="col">Perlakuan</th>
                <th scope="col" className="num">
                  Kuantitas
                </th>
                <th scope="col" className="num">
                  Harga Satuan
                </th>
                <th scope="col" className="num">
                  Total Baris
                </th>
              </tr>
            </thead>
            <tbody>
              {bill.lines.map((line) => (
                <tr key={line.line_no}>
                  <td>{line.description}</td>
                  <td>{PURCHASE_TREATMENT_LABELS[line.treatment]}</td>
                  <td className="num">{formatPlain(line.quantity)}</td>
                  <td className="num">{formatMoney(line.unit_price, bill.currency)}</td>
                  <td className="num">{formatMoney(line.line_total, bill.currency)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Aktivitas</h2>
        </div>
        <ul className="record-activity-list">
          {timeline.map((entry, index) => (
            <li key={`${entry.label}-${index}`} className="record-activity-item">
              <span className={`status-badge status-badge-${entry.tone}`}>{entry.label}</span>
              {entry.date ? (
                <span className="record-activity-date">
                  {formatShortDate(entry.date.slice(0, 10))}
                </span>
              ) : null}
            </li>
          ))}
        </ul>
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Akuntansi</h2>
        </div>
        <p className="dashboard-empty">
          Rincian jurnal per tagihan belum tersedia di tahap ini; lihat Buku Besar pada modul
          Akuntansi untuk dampak akuntansi Entitas secara keseluruhan.
        </p>
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Pajak</h2>
        </div>
        <p className="dashboard-empty">Penentuan pajak per tagihan belum tersedia di tahap ini.</p>
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Dokumen</h2>
        </div>
        <p className="dashboard-empty">Lampiran dan bukti pendukung belum tersedia di tahap ini.</p>
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Audit / Lanjutan</h2>
        </div>
        <p className="dashboard-empty">Riwayat teknis dan versi belum tersedia di tahap ini.</p>
      </section>
    </div>
  );
}
