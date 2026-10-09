import { formatMoney } from "@/domain/money/format";
import { vendorPaymentRowStatus } from "@/domain/purchases/vendorPaymentsList";
import type { VendorPaymentRow } from "@/schemas/purchases";
import { VendorPaymentActions, type VendorPaymentActionPermissions } from "./VendorPaymentActions";
import { formatShortDate } from "./format";
import { BackLink } from "@/features/shell/BackLink";

/**
 * Payment Made Detail (P13 unbuilt-screens backlog, Step 09 §10): Header/Actions/Ringkasan only, the same
 * narrower Standard Record Detail Pattern subset Transfer Detail already uses (decision 169) -- a vendor
 * payment has a lifecycle (confirmed/reversed) but no printable document RPC of its own yet
 * (`payment_receipt_document` has no vendor-payment counterpart) and no per-payment activity feed, so
 * Documents/Activity placeholders would say nothing new. `bill_count` is shown as a plain number: no RPC
 * returns the allocated bills' own numbers, so this does not fabricate a drill-down list from data that
 * was never returned.
 */
export function VendorPaymentDetailScreen({
  row,
  permissions,
  backHref,
}: {
  row: VendorPaymentRow;
  permissions: VendorPaymentActionPermissions;
  backHref: string;
}) {
  const status = vendorPaymentRowStatus(row);
  const hasFx = Number(row.fx_difference) !== 0;

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <BackLink href={backHref}>← Kembali ke daftar pembayaran</BackLink>
      </p>

      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Pembayaran ke Vendor</p>
          <h1>{row.payment_number}</h1>
          <p className="record-detail-counterparty">{row.vendor_name}</p>
        </div>
        <div className="record-detail-header-end">
          <span className={`status-badge status-badge-${status.tone}`}>{status.text}</span>
          <p className="record-detail-amount">{formatMoney(row.amount, row.currency)}</p>
          <p className="record-detail-dates">{formatShortDate(row.payment_date)}</p>
        </div>
      </header>

      <VendorPaymentActions
        paymentId={row.payment_id}
        status={row.status}
        permissions={permissions}
      />

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Ringkasan</h2>
        </div>
        <dl className="record-summary-grid">
          <div>
            <dt>Vendor</dt>
            <dd>{row.vendor_name}</dd>
          </div>
          <div>
            <dt>Jumlah Dibayar</dt>
            <dd>{formatMoney(row.amount, row.currency)}</dd>
          </div>
          <div>
            <dt>Jumlah Bill Dialokasikan</dt>
            <dd>{row.bill_count}</dd>
          </div>
          {hasFx ? (
            <div>
              <dt>Selisih Kurs</dt>
              <dd>{formatMoney(row.fx_difference, "IDR")}</dd>
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
    </div>
  );
}
