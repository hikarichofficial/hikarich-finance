import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import {
  getMoneyControl,
  getReconciliationStatus,
  listReconciliationSessions,
} from "@/services/money/money";
import { mergeReconciliationListRows, visibleSessions } from "@/domain/money/reconciliationList";
import { ReconciliationListScreen } from "@/features/money/ReconciliationListScreen";

/** Reconciliation List (Step 09 §13, decisions 231 and 251). Gated `money.view`, matching
 * `reconciliation_status`'s and `money_control`'s own RPC gate. Each account links to its session in
 * progress, or (with `money.reconcile`) to start a new one; the session history is read directly from
 * `reconciliation_sessions` under its `money.view` RLS policy. */
export default async function ReconciliationListPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  const { access, membership } = await requirePermission("money.view", { entityCode: entity });

  const [status, control, sessions] = await Promise.all([
    getReconciliationStatus(membership.entity_id),
    getMoneyControl(membership.entity_id),
    listReconciliationSessions(membership.entity_id),
  ]);
  const rows = mergeReconciliationListRows(status, control);

  return (
    <ReconciliationListScreen
      rows={rows}
      sessions={visibleSessions(sessions, control)}
      entity={entity}
      canReconcile={can(access, membership.entity_id, "money.reconcile")}
    />
  );
}
