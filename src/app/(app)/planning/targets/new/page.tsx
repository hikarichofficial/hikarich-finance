import { requirePermission } from "@/services/identity/access";
import { listRevenueTargets } from "@/services/planning/planning";
import { CreatePlanForm } from "@/features/planning/CreatePlanForm";
import { BackLink } from "@/features/shell/BackLink";

/** Revenue Target create form (P13 Part 3h, fifth increment, Step 09 §13, §18). Gated on
 * `planning.budget_edit`, the exact permission `create_revenue_target` itself checks (decision 185's own
 * confirmed mapping -- Revenue Target shares Budget's edit permission, no separate one exists). Same shape
 * as `NewBudgetPage`: creates only the draft shell, `redirect()`-on-success sends the user to the resulting
 * target's own Detail page to fill in lines. */
export default async function NewRevenueTargetPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  const { membership } = await requirePermission("planning.budget_edit", { entityCode: entity });

  // Names used before are offered first in the name picker (decision 395); a read that fails just
  // means no suggestions from history, never a broken page.
  const usedNames = (await listRevenueTargets({ entity_id: membership.entity_id }).catch(() => [])).map(
    (row) => row.name,
  );

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <BackLink
          href={
            entity ? `/planning/targets?entity=${encodeURIComponent(entity)}` : "/planning/targets"
          }
        >
          ← Kembali ke daftar target pendapatan
        </BackLink>
      </p>
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Target Pendapatan</p>
          <h1>Buat Target Pendapatan Baru</h1>
        </div>
      </header>
      <section className="dashboard-section">
        <CreatePlanForm
          kind="revenue_target"
          entityId={membership.entity_id}
          entity={entity}
          usedNames={usedNames}
        />
      </section>
    </div>
  );
}
