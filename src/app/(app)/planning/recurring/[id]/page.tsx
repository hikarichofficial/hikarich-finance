import { notFound } from "next/navigation";
import { requirePermission } from "@/services/identity/access";
import { listRecurringOccurrences, listRecurringRules } from "@/services/planning/planning";
import { RecurringRuleDetailScreen } from "@/features/planning/RecurringRuleDetailScreen";

/** Recurring Rule Detail (P13 Part 3h, first increment, Step 09 §10, §18). No per-rule RPC returns the row
 * itself -- only `list_recurring_rules`, Entity-scoped -- so the page fetches the register for the active
 * Entity and looks up the one row by id, the same "no per-record RPC, fetch the list and find by id" shape
 * Employee Detail already uses (decision 179, itself reusing decision 169). An id belonging to a different
 * Entity, or one the caller cannot see, lands here as "not found", never a cross-Entity leak. */
export default async function RecurringRuleDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string }>;
}) {
  const { id } = await params;
  const { entity } = await searchParams;
  const { membership } = await requirePermission("planning.view", { entityCode: entity });

  const entries = await listRecurringRules({ entity_id: membership.entity_id });
  const rule = entries.find((row) => row.id === id);
  if (!rule) notFound();

  const occurrences = await listRecurringOccurrences({ rule_id: id });
  const backHref = entity
    ? `/planning/recurring?entity=${encodeURIComponent(entity)}`
    : "/planning/recurring";

  return (
    <RecurringRuleDetailScreen
      rule={rule}
      occurrences={occurrences}
      entity={entity}
      backHref={backHref}
    />
  );
}
