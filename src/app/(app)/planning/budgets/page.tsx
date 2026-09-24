import { requirePermission } from "@/services/identity/access";
import { listBudgets } from "@/services/planning/planning";
import { filterBudgetRows, parsePlanStatusFilter } from "@/domain/planning/budgetList";
import { BudgetRegisterScreen } from "@/features/planning/BudgetRegisterScreen";

/** Budget Register (P13 Part 3h, second increment, Step 09 §9, §18). `?status=` is sent straight to
 * `list_budgets`'s own `p_status` argument (server-side filtering); `?q=` is a client-side name search since
 * no RPC parameter covers it. */
export default async function BudgetRegisterPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; status?: string; q?: string }>;
}) {
  const { entity, status, q } = await searchParams;
  const { membership } = await requirePermission("planning.view", { entityCode: entity });
  const planStatus = parsePlanStatusFilter(status) ?? null;
  const query = q ?? "";

  const entries = await listBudgets({
    entity_id: membership.entity_id,
    status: planStatus ?? undefined,
  });
  const rows = filterBudgetRows(entries, query);

  return <BudgetRegisterScreen rows={rows} status={planStatus} query={query} entity={entity} />;
}
