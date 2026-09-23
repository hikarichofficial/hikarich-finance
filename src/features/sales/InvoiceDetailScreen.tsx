import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import { Decimal } from "@/domain/money/decimal";
import {
  invoiceActivityTimeline,
  invoiceDocumentStatus,
} from "@/domain/sales/invoiceList";
import { SETTLEMENT_LABELS } from "@/domain/sales/settlement";
import type { InvoiceDocument } from "@/schemas/sales";
import {
  InvoiceActions,
  type InvoiceActionPermissions,
} from "./InvoiceActions";
import { InvoiceDocumentView, formatDocumentDate } from "./InvoiceDocumentView";
import { formatShortDate } from "./format";

/**
 * Invoice Detail (P13 Part 3a, Step 09 §10, §11): Header / Summary / Activity / Documents, in the Standard
 * Record Detail Pattern's order, with Accounting/Tax/Audit shown as their own labeled sections rather than
 * omitted -- the IA stays complete even before each area has a read path (DECISIONS 157's "coming soon"
 * placeholder principle, applied within a screen here). No per-invoice journal drill-down or tax
 * determination RPC exists yet (Step 12's `general_ledger` is entity/period-scoped, not invoice-scoped),
 * so those two sections say so plainly instead of fabricating a link.
 */
export function InvoiceDetailScreen({
  invoiceId,
  doc,
  permissions,
  backHref,
}: {
  invoiceId: string;
  doc: InvoiceDocument;
  permissions: InvoiceActionPermissions;
  backHref: string;
}) {
  const status = invoiceDocumentStatus(doc);
  const timeline = invoiceActivityTimeline(doc);
  const customerName =
    (doc.customer &&
      typeof doc.customer.display_name === "string" &&
      doc.customer.display_name) ||
    "Pelanggan";
  const hasRefund = !Decimal.parse(doc.refunded).isZero();

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={backHref}>← Kembali ke daftar faktur</Link>
      </p>

      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Faktur Penjualan</p>
          <h1>{doc.invoice_number ?? "Draf"}</h1>
          <p className="record-detail-counterparty">{customerName}</p>
        </div>
        <div className="record-detail-header-end">
          <span className={`status-badge status-badge-${status.tone}`}>
            {status.text}
          </span>
          <p className="record-detail-amount">
            {formatMoney(doc.total, doc.currency)}
          </p>
          <p className="record-detail-dates">
            {formatDocumentDate(doc.issue_date)} · Jatuh tempo{" "}
            {formatDocumentDate(doc.due_date)}
          </p>
        </div>
      </header>

      <InvoiceActions
        invoiceId={invoiceId}
        status={doc.status}
        permissions={permissions}
      />

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Ringkasan</h2>
        </div>
        <dl className="record-summary-grid">
          <div>
            <dt>Total Faktur</dt>
            <dd>{formatMoney(doc.total, doc.currency)}</dd>
          </div>
          <div>
            <dt>Sudah Dibayar</dt>
            <dd>{formatMoney(doc.settled, doc.currency)}</dd>
          </div>
          <div>
            <dt>Sisa Tagihan</dt>
            <dd>{formatMoney(doc.outstanding, doc.currency)}</dd>
          </div>
          <div>
            <dt>Status Pelunasan</dt>
            <dd>{SETTLEMENT_LABELS[doc.settlement_status ?? "unpaid"]}</dd>
          </div>
          {hasRefund ? (
            <div>
              <dt>Total Dikembalikan</dt>
              <dd>{formatMoney(doc.refunded, doc.currency)}</dd>
            </div>
          ) : null}
          {doc.is_overdue ? (
            <div>
              <dt>Status Jatuh Tempo</dt>
              <dd>Jatuh tempo, belum dilunasi</dd>
            </div>
          ) : null}
        </dl>
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Aktivitas</h2>
        </div>
        <ul className="record-activity-list">
          {timeline.map((entry, index) => (
            <li
              key={`${entry.label}-${index}`}
              className="record-activity-item"
            >
              <span className={`status-badge status-badge-${entry.tone}`}>
                {entry.label}
              </span>
              {entry.date ? (
                <span className="record-activity-date">
                  {formatShortDate(entry.date)}
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
          Rincian jurnal per faktur belum tersedia di tahap ini; lihat Buku
          Besar pada modul Akuntansi untuk dampak akuntansi Entitas secara
          keseluruhan.
        </p>
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Pajak</h2>
        </div>
        <p className="dashboard-empty">
          Penentuan pajak per faktur belum tersedia di tahap ini.
        </p>
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Dokumen</h2>
        </div>
        <InvoiceDocumentView doc={doc} />
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Audit / Lanjutan</h2>
        </div>
        <p className="dashboard-empty">
          Riwayat teknis dan versi belum tersedia di tahap ini.
        </p>
      </section>
    </div>
  );
}
