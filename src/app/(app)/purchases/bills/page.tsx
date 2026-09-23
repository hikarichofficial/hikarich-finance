import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import { listBillsOverview } from "@/services/purchases/purchases";
import { filterBillRows, parseBillFilter } from "@/domain/purchases/billList";
import { BillsListScreen } from "@/features/purchases/BillsListScreen";

/** Bills List (P13 Part 3b, Step 09 §9, §12). `?status=` is one of `BILL_FILTER_OPTIONS`' values; an absent
 * or unknown value shows every bill, matching every other List screen's own null-filter meaning. */
export default async function BillsListPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; status?: string; q?: string }>;
}) {
  const { entity, status, q } = await searchParams;
  const { access, membership } = await requirePermission("bills.view", {
    entityCode: entity,
  });
  const filter = parseBillFilter(status) ?? null;
  const query = q ?? "";

  const rows = await listBillsOverview(membership.entity_id);
  const visible = filterBillRows(rows, filter, query);

  return (
    <BillsListScreen
      rows={visible}
      activeFilter={filter}
      query={query}
      entity={entity}
      canCreate={can(access, membership.entity_id, "bills.create")}
    />
  );
}
