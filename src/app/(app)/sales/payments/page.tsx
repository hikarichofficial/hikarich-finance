import { requirePermission } from "@/services/identity/access";
import { listPayments } from "@/services/sales/sales";
import { filterPaymentRows, listReceivedPayments } from "@/domain/sales/paymentsList";
import { PaymentsListScreen } from "@/features/sales/PaymentsListScreen";

/** Payments Received (unbuilt-screens backlog, Step 09 primary sitemap). `list_payments` itself is gated
 * on `invoices.view` (its own "View invoices and receipts" permission), matching this page's gate and
 * `navigation.ts`'s own declared permission for this href. */
export default async function PaymentsListPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; q?: string }>;
}) {
  const { entity, q } = await searchParams;
  const { membership } = await requirePermission("invoices.view", { entityCode: entity });
  const query = q ?? "";

  const rows = await listPayments(membership.entity_id);
  const visible = filterPaymentRows(listReceivedPayments(rows), query);

  return (
    <PaymentsListScreen
      rows={visible}
      query={query}
      entity={entity}
      view="received"
      basePath="/sales/payments"
      title="Pembayaran Diterima"
      searchPlaceholder="Cari nomor pembayaran, pelanggan atau referensi…"
      emptyLabel="Belum ada pembayaran yang tercatat."
    />
  );
}
