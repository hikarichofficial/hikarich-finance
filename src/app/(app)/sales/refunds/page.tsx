import { requirePermission } from "@/services/identity/access";
import { listPayments } from "@/services/sales/sales";
import { filterPaymentRows, listPaymentsWithRefunds } from "@/domain/sales/paymentsList";
import { PaymentsListScreen } from "@/features/sales/PaymentsListScreen";

/** Refunds (unbuilt-screens backlog, Step 09 primary sitemap): payments that carry refund activity, from
 * the same `list_payments` rows Payments Received uses (no `list_refunds` RPC exists -- see
 * `src/domain/sales/paymentsList.ts`). Gated on `refunds.view`, matching `navigation.ts`'s own declared
 * permission for this href; `list_payments` itself is gated on `invoices.view` at the database level. Every
 * role template that currently holds `refunds.view` (finance_admin, approver) also holds `invoices.view`,
 * so this does not fail in practice today -- flagged here rather than silently patched over, since closing
 * that gap for good would mean either widening `list_payments`' own gate or granting `invoices.view`
 * alongside every future `refunds.view` grant, both OWNER-relevant authorization decisions. */
export default async function RefundsListPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; q?: string }>;
}) {
  const { entity, q } = await searchParams;
  const { membership } = await requirePermission("refunds.view", { entityCode: entity });
  const query = q ?? "";

  const rows = await listPayments(membership.entity_id);
  const visible = filterPaymentRows(listPaymentsWithRefunds(rows), query);

  return (
    <PaymentsListScreen
      rows={visible}
      query={query}
      entity={entity}
      view="refunds"
      basePath="/sales/refunds"
      title="Refund"
      searchPlaceholder="Cari nomor pembayaran, pelanggan atau referensi…"
      emptyLabel="Belum ada pembayaran dengan refund."
    />
  );
}
