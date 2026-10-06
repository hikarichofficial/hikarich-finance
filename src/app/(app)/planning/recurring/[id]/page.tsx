import { notFound } from "next/navigation";
import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import { listActiveCategories } from "@/services/accounting/categories";
import { listPayeeNameSuggestions } from "@/services/purchases/expenses";
import {
  listActiveContacts,
  listActiveFinancialAccounts,
  listActivePaymentChannels,
  listRecurringOccurrences,
  listRecurringRules,
} from "@/services/planning/planning";
import { RecurringRuleDetailScreen } from "@/features/planning/RecurringRuleDetailScreen";

/** Recurring Rule Detail (P13 Part 3h, first increment, Step 09 §10, §18). No per-rule RPC returns the row
 * itself -- only `list_recurring_rules`, Entity-scoped -- so the page fetches the register for the active
 * Entity and looks up the one row by id, the same "no per-record RPC, fetch the list and find by id" shape
 * Employee Detail already uses (decision 179, itself reusing decision 169). An id belonging to a different
 * Entity, or one the caller cannot see, lands here as "not found", never a cross-Entity leak. `permissions`
 * (fourth increment) is read off the currently active Entity, the same per-page pattern every other screen
 * uses (decision 158); the database still re-checks every action against the rule's own actual Entity
 * regardless of what is active here. From the sixth increment: unlike the create page (which must fetch
 * every kind's own pickers up front, since the form itself chooses the kind), this page already knows the
 * one rule's own `kind` and fetches only the pickers that kind's template builder needs -- fetched
 * unconditionally alongside the occurrences (neither needs a permission beyond what this page already
 * requires, the same reasoning `BudgetDetailPage` already applied to `listActiveCategories`); the screen
 * itself decides whether to render the edit form (`permissions.canManage` and `recurringRuleActions(status)
 * .canEdit`, i.e. not `ended`). */
export default async function RecurringRuleDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string }>;
}) {
  const { id } = await params;
  const { entity } = await searchParams;
  const { access, membership } = await requirePermission("planning.view", { entityCode: entity });
  const entityId = membership.entity_id;

  const entries = await listRecurringRules({ entity_id: entityId });
  const rule = entries.find((row) => row.id === id);
  if (!rule) notFound();

  const [occurrences, customers, vendors, accounts, channels, categories, payeeSuggestions] =
    await Promise.all([
      listRecurringOccurrences({ rule_id: id }),
      rule.kind === "invoice" ? listActiveContacts(entityId, "customer") : Promise.resolve([]),
      rule.kind === "bill" || rule.kind === "expense"
        ? listActiveContacts(entityId, "vendor")
        : Promise.resolve([]),
      rule.kind === "invoice" || rule.kind === "expense"
        ? listActiveFinancialAccounts(entityId)
        : Promise.resolve([]),
      rule.kind === "invoice" ? listActivePaymentChannels(entityId) : Promise.resolve([]),
      listActiveCategories(entityId),
      rule.kind === "expense" ? listPayeeNameSuggestions(entityId) : Promise.resolve([]),
    ]);
  const backHref = entity
    ? `/planning/recurring?entity=${encodeURIComponent(entity)}`
    : "/planning/recurring";

  return (
    <RecurringRuleDetailScreen
      rule={rule}
      occurrences={occurrences}
      entity={entity}
      entityId={entityId}
      backHref={backHref}
      customers={customers}
      vendors={vendors}
      accounts={accounts}
      channels={channels}
      categories={categories}
      payeeSuggestions={payeeSuggestions}
      permissions={{
        canManage: can(access, membership.entity_id, "planning.recurring_edit"),
      }}
    />
  );
}
