import { requirePermission } from "@/services/identity/access";
import { listRecurringRules } from "@/services/planning/planning";
import { filterRecurringRows, parseRecurringStatusFilter } from "@/domain/planning/recurringList";
import { RecurringRuleRegisterScreen } from "@/features/planning/RecurringRuleRegisterScreen";

/** Recurring Rules Register (P13 Part 3h, first increment, Step 09 §9, §18). `?status=` is sent straight to
 * `list_recurring_rules`'s own `p_status` argument (server-side filtering, matching every other Part 3
 * register); `?q=` is a client-side label search since no RPC parameter covers it. */
export default async function RecurringRuleRegisterPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; status?: string; q?: string }>;
}) {
  const { entity, status, q } = await searchParams;
  const { membership } = await requirePermission("planning.view", { entityCode: entity });
  const recurringStatus = parseRecurringStatusFilter(status) ?? null;
  const query = q ?? "";

  const entries = await listRecurringRules({
    entity_id: membership.entity_id,
    status: recurringStatus ?? undefined,
  });
  const rows = filterRecurringRows(entries, query);

  return (
    <RecurringRuleRegisterScreen
      rows={rows}
      status={recurringStatus}
      query={query}
      entity={entity}
    />
  );
}
