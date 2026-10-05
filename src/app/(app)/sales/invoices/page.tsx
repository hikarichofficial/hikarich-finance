import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import { listDraftInvoices, listInvoicePositions } from "@/services/sales/sales";
import { filterInvoicePositionsByQuery, parseInvoiceFilter } from "@/domain/sales/invoiceList";
import { InvoicesListScreen } from "@/features/sales/InvoicesListScreen";

/** Invoices List (P13 Part 3a, Step 09 §9, §11). `?status=` is one of `invoiceFilterSchema`'s values; an
 * absent or unknown value shows every invoice, matching `list_invoice_positions`' own null-filter meaning. */
export default async function InvoicesListPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; status?: string; q?: string }>;
}) {
  const { entity, status, q } = await searchParams;
  const { access, membership } = await requirePermission("invoices.view", { entityCode: entity });
  const filter = parseInvoiceFilter(status) ?? null;
  const query = q ?? "";

  // Drafts have no number or receivable, so the position RPC omits them: show them under "Semua" and "Draf".
  const issued =
    filter === "draft"
      ? []
      : await listInvoicePositions(membership.entity_id, { filter: filter ?? undefined });
  const drafts =
    filter === null || filter === "draft" ? await listDraftInvoices(membership.entity_id) : [];
  const rows = [...drafts, ...issued];
  const visible = filterInvoicePositionsByQuery(rows, query);

  return (
    <InvoicesListScreen
      rows={visible}
      activeFilter={filter}
      query={query}
      entity={entity}
      canCreate={can(access, membership.entity_id, "invoices.create")}
    />
  );
}
