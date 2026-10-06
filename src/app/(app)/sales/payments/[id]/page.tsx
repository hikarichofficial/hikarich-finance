import { notFound } from "next/navigation";
import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import {
  getPaymentReceipt,
  getPaymentRefundOptions,
  listPaymentRefunds,
  listPayments,
} from "@/services/sales/sales";
import { getMoneyControl } from "@/services/money/money";
import { formatMoney } from "@/domain/money/format";
import { emailDeliveryEnabled } from "@/services/email/resend";
import { listEmailDeliveries } from "@/services/email/deliveries";
import { getContact } from "@/services/contacts/contacts";
import { EmailHistory } from "@/features/sales/EmailHistory";
import { SendReceiptEmailForm } from "@/features/sales/SendReceiptEmailForm";
import { RefundForm } from "@/features/sales/RefundForm";
import { RefundActionForms } from "@/features/sales/RefundActionForms";
import { PaymentDetailScreen } from "@/features/sales/PaymentDetailScreen";
import { getEntityLogo } from "@/services/settings/settings";
import { formatShortDate } from "@/features/sales/format";
import type { RefundRow } from "@/schemas/sales";
import { todayInBusinessZone } from "@/lib/time";

const REFUND_STATUS_LABELS: Readonly<Record<RefundRow["status"], string>> = {
  draft: "Draft (Menunggu Konfirmasi)",
  confirmed: "Terkonfirmasi",
  rejected: "Ditolak",
  cancelled: "Dibatalkan",
  reversed: "Dibalik",
};

/** Payment Detail (unbuilt-screens backlog, Step 09 §10/§11), reached from either Payments Received or
 * Refunds. `list_payments` has no single-item counterpart (matching Accounting Periods' own Detail page
 * precedent), so the row is looked up from the Entity's own payments list by id; `payment_receipt_document`
 * supplies the printable Dokumen section directly by id and independently re-checks the payment's own
 * Entity server-side regardless of what `?entity=` says here.
 *
 * The Refund draft/confirm/reject/cancel/reverse screen (decision 263's own deferred item, closed by
 * decision 285) lives here too, since every refund action is already scoped to one payment. `RefundForm`
 * now opens for `refunds.create` ALONE (`canOfferRefundForm`), not only the combined `refunds.create` +
 * `refunds.confirm` decision 263 originally gated it on -- the form itself picks `create_refund`'s own
 * `p_confirm` (its `immediate` prop) by whether the caller also holds `refunds.confirm`, so a create-only
 * caller now gets a real draft instead of being shown no form at all. `listPaymentRefunds` reads
 * `public.refunds` directly (no `list_refunds` RPC exists, the same "direct read, RLS alone gates it" shape
 * `listBillsOverview` uses for `public.bills`) and is fetched unconditionally -- `refunds_select`'s own RLS
 * policy already narrows it to nothing for a caller without `refunds.view`, so no second permission check is
 * needed here. Each listed refund gets `RefundActionForms` when it is still actionable (`draft` or
 * `confirmed`); every other status is terminal and shows only its own `closed_reason`/`reverse_reason`. */
export default async function PaymentDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string }>;
}) {
  const { id } = await params;
  const { entity } = await searchParams;
  const { access, membership } = await requirePermission("invoices.view", { entityCode: entity });

  const rows = await listPayments(membership.entity_id);
  const row = rows.find((candidate) => candidate.payment_id === id);
  if (!row) notFound();

  const receipt = await getPaymentReceipt(id).catch(() => null);
  if (!receipt) notFound();

  const canCreateRefund = can(access, membership.entity_id, "refunds.create");
  const canConfirmRefund = can(access, membership.entity_id, "refunds.confirm");
  const canOfferRefundForm = row.status === "confirmed" && canCreateRefund;
  const [refundOptions, accounts, refunds] = await Promise.all([
    canOfferRefundForm ? getPaymentRefundOptions(id).catch(() => []) : Promise.resolve([]),
    canOfferRefundForm
      ? getMoneyControl(membership.entity_id).catch(() => [])
      : Promise.resolve([]),
    // RLS alone gates this (`refunds_select`, `refunds.view`) -- a caller without it simply sees no rows.
    listPaymentRefunds(id).catch(() => []),
  ]);
  const refundable = refundOptions.filter((o) => Number(o.refundable) > 0);
  const today = todayInBusinessZone();

  const canSendEmail = can(access, membership.entity_id, "invoices.regenerate_link");
  const [emailHistory, customerContact] = await Promise.all([
    listEmailDeliveries(membership.entity_id, "payment_receipt", id),
    canSendEmail ? getContact(row.customer_id).catch(() => null) : Promise.resolve(null),
  ]);

  const backHref = entity
    ? `/sales/payments?entity=${encodeURIComponent(entity)}`
    : "/sales/payments";

  return (
    <PaymentDetailScreen
      row={row}
      receipt={receipt}
      logo={await getEntityLogo(membership.entity_id)}
      backHref={backHref}
      emailPanel={
        <>
          {canSendEmail && row.status === "confirmed" ? (
            <section className="dashboard-section">
              <div className="dashboard-section-header">
                <h2 className="dashboard-section-title">Kirim Bukti Pembayaran</h2>
              </div>
              <SendReceiptEmailForm
                paymentId={id}
                entity={entity}
                defaultEmail={customerContact?.email ?? null}
                configured={emailDeliveryEnabled()}
              />
            </section>
          ) : null}
          <EmailHistory
            rows={emailHistory}
            emptyText="Bukti pembayaran ini belum pernah dikirim lewat email."
          />
        </>
      }
      refundPanel={
        <>
          {canOfferRefundForm && refundable.length > 0 ? (
            <RefundForm
              paymentId={id}
              options={refundable.map((o, index) => ({
                key: `${o.source}-${o.allocation_id ?? index}`,
                source: o.source,
                allocationId: o.allocation_id,
                label:
                  o.source === "advance"
                    ? "Uang muka yang belum dipakai"
                    : `Invoice ${o.invoice_number ?? ""}`.trim(),
                refundable: o.refundable,
              }))}
              accounts={accounts
                .filter((a) => a.is_active)
                .map((a) => ({ id: a.financial_account_id, label: `${a.name} (${a.currency})` }))}
              today={today}
              immediate={canConfirmRefund}
            />
          ) : null}
          {refunds.length > 0 ? (
            <section className="dashboard-section">
              <div className="dashboard-section-header">
                <h2 className="dashboard-section-title">Refund</h2>
              </div>
              {refunds.map((refund) => (
                <div
                  key={refund.id}
                  className="record-summary-grid"
                  style={{ marginBottom: "1rem" }}
                >
                  <div>
                    <dt>Nomor</dt>
                    <dd>{refund.refund_number ?? "(draft)"}</dd>
                  </div>
                  <div>
                    <dt>Jumlah</dt>
                    <dd>{formatMoney(refund.amount, refund.currency)}</dd>
                  </div>
                  <div>
                    <dt>Tanggal</dt>
                    <dd>{formatShortDate(refund.refund_date)}</dd>
                  </div>
                  <div>
                    <dt>Status</dt>
                    <dd>
                      <span className="status-badge">{REFUND_STATUS_LABELS[refund.status]}</span>
                    </dd>
                  </div>
                  {refund.closed_reason ? (
                    <div>
                      <dt>Alasan {refund.status === "rejected" ? "Penolakan" : "Pembatalan"}</dt>
                      <dd>{refund.closed_reason}</dd>
                    </div>
                  ) : null}
                  {refund.reverse_reason ? (
                    <div>
                      <dt>Alasan Pembalikan</dt>
                      <dd>{refund.reverse_reason}</dd>
                    </div>
                  ) : null}
                  {refund.status === "draft" || refund.status === "confirmed" ? (
                    <RefundActionForms
                      refundId={refund.id}
                      paymentId={id}
                      status={refund.status}
                      canConfirm={canConfirmRefund}
                      canCreate={canCreateRefund}
                      today={today}
                    />
                  ) : null}
                </div>
              ))}
            </section>
          ) : null}
        </>
      }
      permissions={{
        canReverse: can(access, membership.entity_id, "invoices.confirm_payment"),
      }}
    />
  );
}
