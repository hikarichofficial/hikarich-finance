import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import { listRecurringRules } from "@/services/planning/planning";
import { filterRecurringRows, parseRecurringStatusFilter } from "@/domain/planning/recurringList";
import { RecurringRuleRegisterScreen } from "@/features/planning/RecurringRuleRegisterScreen";

/** Recurring Rules Register (P13 Part 3h, first increment, Step 09 §9, §18). `?status=` is sent straight to
 * `list_recurring_rules`'s own `p_status` argument (server-side filtering, matching every other Part 3
 * register); `?q=` is a client-side label search since no RPC parameter covers it. `canRun` (fourth
 * increment) gates the manual "generate now" button, the same per-page `can()` pattern every other screen
 * uses (decision 158). */
export default async function RecurringRuleRegisterPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; status?: string; q?: string }>;
}) {
  const { entity, status, q } = await searchParams;
  const { access, membership } = await requirePermission("planning.view", { entityCode: entity });
  const recurringStatus = parseRecurringStatusFilter(status) ?? null;
  const query = q ?? "";
  const entityId = membership.entity_id;

  const entries = await listRecurringRules({
    entity_id: entityId,
    status: recurringStatus ?? undefined,
  });
  const rows = filterRecurringRows(entries, query);

  return (
    <RecurringRuleRegisterScreen
      rows={rows}
      status={recurringStatus}
      query={query}
      entity={entity}
      entityId={entityId}
      canRun={can(access, entityId, "planning.recurring_run")}
    />
  );
}
