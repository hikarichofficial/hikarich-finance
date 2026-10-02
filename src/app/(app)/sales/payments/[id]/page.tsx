import { notFound } from "next/navigation";
import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import { getPaymentReceipt, getPaymentRefundOptions, listPayments } from "@/services/sales/sales";
import { getMoneyControl } from "@/services/money/money";
import { RefundForm } from "@/features/sales/RefundForm";
import { PaymentDetailScreen } from "@/features/sales/PaymentDetailScreen";

/** Payment Detail (unbuilt-screens backlog, Step 09 §10/§11), reached from either Payments Received or
 * Refunds. `list_payments` has no single-item counterpart (matching Accounting Periods' own Detail page
 * precedent), so the row is looked up from the Entity's own payments list by id; `payment_receipt_document`
 * supplies the printable Dokumen section directly by id and independently re-checks the payment's own
 * Entity server-side regardless of what `?entity=` says here. */
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

  const canRefund =
    row.status === "confirmed" &&
    can(access, membership.entity_id, "refunds.create") &&
    can(access, membership.entity_id, "refunds.confirm");
  const [refundOptions, accounts] = canRefund
    ? await Promise.all([
        getPaymentRefundOptions(id).catch(() => []),
        getMoneyControl(membership.entity_id).catch(() => []),
      ])
    : [[], []];
  const refundable = refundOptions.filter((o) => Number(o.refundable) > 0);

  const backHref = entity
    ? `/sales/payments?entity=${encodeURIComponent(entity)}`
    : "/sales/payments";

  return (
    <PaymentDetailScreen
      row={row}
      receipt={receipt}
      backHref={backHref}
      refundPanel={
        canRefund && refundable.length > 0 ? (
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
            today={new Date().toISOString().slice(0, 10)}
          />
        ) : null
      }
      permissions={{
        canReverse: can(access, membership.entity_id, "invoices.confirm_payment"),
      }}
    />
  );
}
