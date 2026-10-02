import Link from "next/link";
import type { ReactNode } from "react";
import { formatMoney } from "@/domain/money/format";
import { paymentRowStatus, refundStatusDisplay } from "@/domain/sales/paymentsList";
import type { PaymentListRow, ReceiptDocument } from "@/schemas/sales";
import { PaymentActions, type PaymentActionPermissions } from "./PaymentActions";
import { ReceiptDocumentView } from "./ReceiptDocumentView";
import { formatShortDate } from "./format";

/**
 * Payment Detail (P13 unbuilt-screens backlog, Step 09 §10/§11), reachable from either Payments Received or
 * Refunds. `list_payments` has no single-item counterpart, so the row (for the Ringkasan fields --
 * `refund_status`/`refundable`/`advance_remaining`, none of which `payment_receipt_document` returns) comes
 * from the page's own `list_payments` call matched by id, the same "look up from the list result" shape
 * Accounting Periods' own Detail page already established (no per-period RPC either). `payment_receipt_document`
 * supplies the printable Dokumen section via the existing `ReceiptDocumentView` (already shipped for the
 * public receipt page, P13 Part 5). No Accounting/Tax sections: `reverse_payment`'s own journal effect has no
 * per-payment drill-down RPC yet, matching Invoice Detail's own "no per-invoice journal drill-down" note.
 */
export function PaymentDetailScreen({
  row,
  receipt,
  permissions,
  backHref,
  refundPanel,
}: {
  row: PaymentListRow;
  receipt: ReceiptDocument;
  permissions: PaymentActionPermissions;
  backHref: string;
  /** The refund form, when the person may refund and something is still refundable (decision 263). */
  refundPanel?: ReactNode;
}) {
  const status = paymentRowStatus(row);
  const refund = refundStatusDisplay(row.refund_status);
  const hasAdvance = row.advance_remaining !== null && row.advance_remaining !== "0";

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={backHref}>← Kembali ke daftar pembayaran</Link>
      </p>

      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Pembayaran Diterima</p>
          <h1>{row.payment_number}</h1>
          <p className="record-detail-counterparty">{row.customer_name}</p>
        </div>
        <div className="record-detail-header-end">
          <span className={`status-badge status-badge-${status.tone}`}>{status.text}</span>
          <p className="record-detail-amount">{formatMoney(row.amount, row.currency)}</p>
          <p className="record-detail-dates">{formatShortDate(row.payment_date)}</p>
        </div>
      </header>

      <PaymentActions paymentId={row.payment_id} status={row.status} permissions={permissions} />
      {refundPanel}

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Ringkasan</h2>
        </div>
        <dl className="record-summary-grid">
          <div>
            <dt>Jumlah Dibayar</dt>
            <dd>{formatMoney(row.amount, row.currency)}</dd>
          </div>
          <div>
            <dt>Dialokasikan ke Faktur</dt>
            <dd>{formatMoney(row.allocated_amount, row.currency)}</dd>
          </div>
          {hasAdvance ? (
            <div>
              <dt>Sisa Uang Muka</dt>
              <dd>{formatMoney(row.advance_remaining as string, row.currency)}</dd>
            </div>
          ) : null}
          <div>
            <dt>Status Refund</dt>
            <dd>
              <span className={`status-badge status-badge-${refund.tone}`}>{refund.text}</span>
            </dd>
          </div>
          {row.refund_status !== "none" ? (
            <div>
              <dt>Total Dikembalikan</dt>
              <dd>{formatMoney(row.refunded, row.currency)}</dd>
            </div>
          ) : null}
          {row.status === "confirmed" ? (
            <div>
              <dt>Sisa Dapat Direfund</dt>
              <dd>{formatMoney(row.refundable, row.currency)}</dd>
            </div>
          ) : null}
          {row.reference ? (
            <div>
              <dt>Referensi</dt>
              <dd>{row.reference}</dd>
            </div>
          ) : null}
        </dl>
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Dokumen</h2>
        </div>
        <ReceiptDocumentView receipt={receipt} />
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Audit / Lanjutan</h2>
        </div>
        <p className="dashboard-empty">
          Rincian jurnal per pembayaran belum tersedia di tahap ini; lihat Buku Besar pada modul
          Akuntansi untuk dampak akuntansi Entitas secara keseluruhan.
        </p>
      </section>
    </div>
  );
}
