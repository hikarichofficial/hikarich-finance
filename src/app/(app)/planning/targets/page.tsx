import { requirePermission } from "@/services/identity/access";
import { listRevenueTargets } from "@/services/planning/planning";
import { filterRevenueTargetRows, parsePlanStatusFilter } from "@/domain/planning/budgetList";
import { RevenueTargetRegisterScreen } from "@/features/planning/RevenueTargetRegisterScreen";

/** Revenue Target Register (P13 Part 3h, third increment, Step 09 §9, §18). `?status=` is sent straight to
 * `list_revenue_targets`'s own `p_status` argument (server-side filtering); `?q=` is a client-side name
 * search since no RPC parameter covers it -- the same pattern as Budget Register (decision 184). */
export default async function RevenueTargetRegisterPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; status?: string; q?: string }>;
}) {
  const { entity, status, q } = await searchParams;
  const { membership } = await requirePermission("planning.view", { entityCode: entity });
  const planStatus = parsePlanStatusFilter(status) ?? null;
  const query = q ?? "";

  const entries = await listRevenueTargets({
    entity_id: membership.entity_id,
    status: planStatus ?? undefined,
  });
  const rows = filterRevenueTargetRows(entries, query);

  return (
    <RevenueTargetRegisterScreen rows={rows} status={planStatus} query={query} entity={entity} />
  );
}
