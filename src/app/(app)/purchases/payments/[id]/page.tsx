import { notFound } from "next/navigation";
import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import { listVendorPayments } from "@/services/purchases/purchases";
import { VendorPaymentDetailScreen } from "@/features/purchases/VendorPaymentDetailScreen";

/** Payment Made Detail (unbuilt-screens backlog, Step 09 §10). `list_vendor_payments` has no single-item
 * counterpart, so the row is looked up from the Entity's own vendor payments list by id, the same "look up
 * from the list result" shape Accounting Periods and Payment (Sales) Detail already established. */
export default async function VendorPaymentDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string }>;
}) {
  const { id } = await params;
  const { entity } = await searchParams;
  const { access, membership } = await requirePermission("bills.view", { entityCode: entity });

  const rows = await listVendorPayments(membership.entity_id);
  const row = rows.find((candidate) => candidate.payment_id === id);
  if (!row) notFound();

  const backHref = entity
    ? `/purchases/payments?entity=${encodeURIComponent(entity)}`
    : "/purchases/payments";

  return (
    <VendorPaymentDetailScreen
      row={row}
      backHref={backHref}
      permissions={{
        canReverse: can(access, membership.entity_id, "bills.pay"),
      }}
    />
  );
}
