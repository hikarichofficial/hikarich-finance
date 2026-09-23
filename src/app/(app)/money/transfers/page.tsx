import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import { getMoneyControl, listTransfers } from "@/services/money/money";
import {
  filterTransferRows,
  mergeTransferRows,
  parseTransferFilter,
} from "@/domain/money/transferList";
import { TransfersListScreen } from "@/features/money/TransfersListScreen";

/** Transfers List (P13 Part 3c, Step 09 §9, §13). `?status=` is one of `TRANSFER_FILTER_OPTIONS`' values;
 * an absent or unknown value shows every transfer, matching every other List screen's own null-filter
 * meaning. */
export default async function TransfersListPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; status?: string; q?: string }>;
}) {
  const { entity, status, q } = await searchParams;
  const { access, membership } = await requirePermission("money.view", { entityCode: entity });
  const filter = parseTransferFilter(status) ?? null;
  const query = q ?? "";

  const [transfers, accounts] = await Promise.all([
    listTransfers(membership.entity_id),
    getMoneyControl(membership.entity_id),
  ]);
  const rows = mergeTransferRows(transfers, accounts);
  const visible = filterTransferRows(rows, filter, query);

  return (
    <TransfersListScreen
      rows={visible}
      activeFilter={filter}
      query={query}
      entity={entity}
      canCreate={can(access, membership.entity_id, "money.transfer_create")}
    />
  );
}
