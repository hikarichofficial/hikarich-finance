import { notFound } from "next/navigation";
import { requirePermission } from "@/services/identity/access";
import {
  getEntityBaseCurrency,
  getRevenueTargetReport,
  listRevenueTargets,
} from "@/services/planning/planning";
import { RevenueTargetDetailScreen } from "@/features/planning/RevenueTargetDetailScreen";

/** Revenue Target Detail (P13 Part 3h, third increment, Step 09 §10, §18). No per-target RPC returns the row
 * itself -- only `list_revenue_targets`, Entity-scoped -- so the page fetches the register and finds the row
 * by id, the same precedent decisions 169/179/183/184 already established. `get_revenue_target_report` alone
 * covers the report (Target/Actual/AR Outstanding/Variance per month, entity-wide -- no category breakdown
 * and no separate lines RPC to fetch alongside it, unlike Budgets). */
export default async function RevenueTargetDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string }>;
}) {
  const { id } = await params;
  const { entity } = await searchParams;
  const { membership } = await requirePermission("planning.view", { entityCode: entity });

  const entries = await listRevenueTargets({ entity_id: membership.entity_id });
  const target = entries.find((row) => row.id === id);
  if (!target) notFound();

  const [report, currency] = await Promise.all([
    getRevenueTargetReport(id),
    getEntityBaseCurrency(membership.entity_id),
  ]);
  const backHref = entity
    ? `/planning/targets?entity=${encodeURIComponent(entity)}`
    : "/planning/targets";

  return (
    <RevenueTargetDetailScreen
      target={target}
      report={report}
      currency={currency}
      backHref={backHref}
    />
  );
}
