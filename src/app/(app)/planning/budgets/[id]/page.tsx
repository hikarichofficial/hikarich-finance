import { notFound } from "next/navigation";
import { requirePermission } from "@/services/identity/access";
import { getBudgetReport, getEntityBaseCurrency, listBudgets } from "@/services/planning/planning";
import { BudgetDetailScreen } from "@/features/planning/BudgetDetailScreen";

/** Budget Detail (P13 Part 3h, second increment, Step 09 §10, §18). No per-budget RPC returns the row itself
 * -- only `list_budgets`, Entity-scoped -- so the page fetches the register and finds the row by id, the same
 * precedent decisions 169/179/183 already established. `get_budget_report` alone covers the report (it is a
 * strict superset of `get_budget_lines`, decision documented in the screen component itself). */
export default async function BudgetDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string }>;
}) {
  const { id } = await params;
  const { entity } = await searchParams;
  const { membership } = await requirePermission("planning.view", { entityCode: entity });

  const entries = await listBudgets({ entity_id: membership.entity_id });
  const budget = entries.find((row) => row.id === id);
  if (!budget) notFound();

  const [report, currency] = await Promise.all([
    getBudgetReport(id),
    getEntityBaseCurrency(membership.entity_id),
  ]);
  const backHref = entity
    ? `/planning/budgets?entity=${encodeURIComponent(entity)}`
    : "/planning/budgets";

  return (
    <BudgetDetailScreen budget={budget} report={report} currency={currency} backHref={backHref} />
  );
}
