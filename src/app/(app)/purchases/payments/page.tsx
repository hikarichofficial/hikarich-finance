import { requirePermission } from "@/services/identity/access";
import { listVendorPayments } from "@/services/purchases/purchases";
import { filterVendorPaymentRows } from "@/domain/purchases/vendorPaymentsList";
import { VendorPaymentsListScreen } from "@/features/purchases/VendorPaymentsListScreen";

/** Payments Made (unbuilt-screens backlog, Step 09 primary sitemap). `list_vendor_payments` itself is
 * gated on `bills.view`, matching this page's gate and `navigation.ts`'s own declared permission. */
export default async function VendorPaymentsListPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; q?: string }>;
}) {
  const { entity, q } = await searchParams;
  const { membership } = await requirePermission("bills.view", { entityCode: entity });
  const query = q ?? "";

  const rows = await listVendorPayments(membership.entity_id);
  const visible = filterVendorPaymentRows(rows, query);

  return <VendorPaymentsListScreen rows={visible} query={query} entity={entity} />;
}
