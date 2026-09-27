import { notFound } from "next/navigation";
import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import { listActiveCategories } from "@/services/accounting/categories";
import {
  getBudgetLines,
  getBudgetReport,
  getEntityBaseCurrency,
  listBudgets,
} from "@/services/planning/planning";
import { BudgetDetailScreen } from "@/features/planning/BudgetDetailScreen";

/** Budget Detail (P13 Part 3h, second increment, Step 09 §10, §18). No per-budget RPC returns the row itself
 * -- only `list_budgets`, Entity-scoped -- so the page fetches the register and finds the row by id, the same
 * precedent decisions 169/179/183 already established. `get_budget_report` alone covers the report (it is a
 * strict superset of `get_budget_lines`, decision documented in the screen component itself). `permissions`
 * (fourth increment) follows the same active-Entity `can()` pattern every other screen uses (decision 158).
 * From the fifth increment, `get_budget_lines`'s own raw lines and `listActiveCategories` (a direct RLS-
 * scoped table read, no RPC needed -- see `@/services/accounting/categories`) feed `BudgetLinesEditor`; both
 * are fetched unconditionally (neither needs a permission beyond Entity membership, which this page already
 * requires), and the screen itself decides whether to render the editor. */
export default async function BudgetDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string }>;
}) {
  const { id } = await params;
  const { entity } = await searchParams;
  const { access, membership } = await requirePermission("planning.view", { entityCode: entity });

  const entries = await listBudgets({ entity_id: membership.entity_id });
  const budget = entries.find((row) => row.id === id);
  if (!budget) notFound();

  const [report, lines, categories, currency] = await Promise.all([
    getBudgetReport(id),
    getBudgetLines(id),
    listActiveCategories(membership.entity_id),
    getEntityBaseCurrency(membership.entity_id),
  ]);
  const backHref = entity
    ? `/planning/budgets?entity=${encodeURIComponent(entity)}`
    : "/planning/budgets";

  return (
    <BudgetDetailScreen
      budget={budget}
      report={report}
      lines={lines}
      categories={categories}
      currency={currency}
      backHref={backHref}
      permissions={{ canManage: can(access, membership.entity_id, "planning.budget_edit") }}
    />
  );
}
