import { notFound } from "next/navigation";
import { can } from "@/domain/authz/access";
import { listActiveCategories } from "@/services/accounting/categories";
import { requirePermission } from "@/services/identity/access";
import {
  getEntityBaseCurrency,
  getRevenueTargetLines,
  getRevenueTargetReport,
  listRevenueTargets,
} from "@/services/planning/planning";
import { RevenueTargetDetailScreen } from "@/features/planning/RevenueTargetDetailScreen";

/** Revenue Target Detail (P13 Part 3h, third increment, Step 09 §10, §18). No per-target RPC returns the row
 * itself -- only `list_revenue_targets`, Entity-scoped -- so the page fetches the register and finds the row
 * by id, the same precedent decisions 169/179/183/184 already established. `get_revenue_target_report` alone
 * covers the report (Target/Actual/AR Outstanding/Variance per month and, since decision 399, per revenue
 * category where the target names one). `permissions` (fourth increment) follows
 * the same active-Entity `can()` pattern every other screen uses (decision 158), reusing `planning.budget_edit`
 * since Revenue Target shares that capability with Budget (decision 184). From the fifth increment,
 * `get_revenue_target_lines`'s own raw lines feed `RevenueTargetLinesEditor`, fetched unconditionally
 * (needs only Entity membership) alongside the report and currency. The editor also needs this Entity's
 * revenue categories (decision 399), read the same Entity-scoped way the Budget page reads them; only
 * `kind === "revenue"` is passed, which is what `set_revenue_target_lines` itself accepts. */
export default async function RevenueTargetDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string }>;
}) {
  const { id } = await params;
  const { entity } = await searchParams;
  const { access, membership } = await requirePermission("planning.view", { entityCode: entity });

  const entries = await listRevenueTargets({ entity_id: membership.entity_id });
  const target = entries.find((row) => row.id === id);
  if (!target) notFound();

  const [report, lines, categories, currency] = await Promise.all([
    getRevenueTargetReport(id),
    getRevenueTargetLines(id),
    listActiveCategories(membership.entity_id),
    getEntityBaseCurrency(membership.entity_id),
  ]);
  const backHref = entity
    ? `/planning/targets?entity=${encodeURIComponent(entity)}`
    : "/planning/targets";

  return (
    <RevenueTargetDetailScreen
      target={target}
      report={report}
      lines={lines}
      categories={categories.filter((category) => category.kind === "revenue")}
      currency={currency}
      backHref={backHref}
      permissions={{ canManage: can(access, membership.entity_id, "planning.budget_edit") }}
    />
  );
}
