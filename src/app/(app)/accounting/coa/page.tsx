import { requirePermission } from "@/services/identity/access";
import { listLedgerAccounts } from "@/services/accounting/ledger";
import { parseCoaStatusFilter } from "@/domain/accounting/coaList";
import { ChartOfAccountsScreen } from "@/features/accounting/ChartOfAccountsScreen";

/** Chart of Accounts (P13 Part 3d, Step 09 §14). `?status=` is `active`/`inactive`; an absent or unknown
 * value shows every account, matching every other List screen's own null-filter meaning. */
export default async function ChartOfAccountsPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; status?: string; q?: string }>;
}) {
  const { entity, status, q } = await searchParams;
  const { membership } = await requirePermission("accounting.view", { entityCode: entity });
  const statusFilter = parseCoaStatusFilter(status) ?? null;
  const query = q ?? "";

  const accounts = await listLedgerAccounts(membership.entity_id);

  return (
    <ChartOfAccountsScreen
      accounts={accounts}
      status={statusFilter}
      query={query}
      entity={entity}
    />
  );
}
