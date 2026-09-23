import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import { getMoneyControl, getReconciliationStatus } from "@/services/money/money";
import {
  filterAccountRows,
  mergeAccountRows,
  parseAccountFilter,
} from "@/domain/money/accountsList";
import { AccountsListScreen } from "@/features/money/AccountsListScreen";

/** Accounts List (P13 Part 3c, Step 09 §9, §13). `?status=` is one of `ACCOUNT_FILTER_OPTIONS`' values; an
 * absent or unknown value shows every account, matching every other List screen's own null-filter meaning. */
export default async function AccountsListPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; status?: string; q?: string }>;
}) {
  const { entity, status, q } = await searchParams;
  const { access, membership } = await requirePermission("money.view", { entityCode: entity });
  const filter = parseAccountFilter(status) ?? null;
  const query = q ?? "";

  const [control, reconciliation] = await Promise.all([
    getMoneyControl(membership.entity_id),
    getReconciliationStatus(membership.entity_id),
  ]);
  const rows = mergeAccountRows(control, reconciliation);
  const visible = filterAccountRows(rows, filter, query);

  return (
    <AccountsListScreen
      rows={visible}
      activeFilter={filter}
      query={query}
      entity={entity}
      canCreate={can(access, membership.entity_id, "money.edit")}
    />
  );
}
