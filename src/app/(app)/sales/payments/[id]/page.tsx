import { notFound } from "next/navigation";
import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import { getPaymentReceipt, listPayments } from "@/services/sales/sales";
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

  const backHref = entity
    ? `/sales/payments?entity=${encodeURIComponent(entity)}`
    : "/sales/payments";

  return (
    <PaymentDetailScreen
      row={row}
      receipt={receipt}
      backHref={backHref}
      permissions={{
        canReverse: can(access, membership.entity_id, "invoices.confirm_payment"),
      }}
    />
  );
}
