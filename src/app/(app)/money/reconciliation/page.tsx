import { requirePermission } from "@/services/identity/access";
import { getMoneyControl, getReconciliationStatus } from "@/services/money/money";
import { mergeReconciliationListRows } from "@/domain/money/reconciliationList";
import { ReconciliationListScreen } from "@/features/money/ReconciliationListScreen";

/** Reconciliation List (P13 unbuilt-screens backlog, Step 09 §13, decision 231). Gated `money.view`,
 * matching `reconciliation_status`'s and `money_control`'s own RPC gate. Read-only for now -- see
 * `ReconciliationListScreen`'s own comment for why starting/working a session stays on the catch-all. */
export default async function ReconciliationListPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  const { membership } = await requirePermission("money.view", { entityCode: entity });

  const [status, control] = await Promise.all([
    getReconciliationStatus(membership.entity_id),
    getMoneyControl(membership.entity_id),
  ]);
  const rows = mergeReconciliationListRows(status, control);

  return <ReconciliationListScreen rows={rows} />;
}
