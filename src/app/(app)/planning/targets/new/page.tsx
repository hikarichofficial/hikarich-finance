import Link from "next/link";
import { requirePermission } from "@/services/identity/access";
import { CreatePlanForm } from "@/features/planning/CreatePlanForm";

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

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link
          href={
            entity ? `/planning/targets?entity=${encodeURIComponent(entity)}` : "/planning/targets"
          }
        >
          ← Kembali ke daftar target pendapatan
        </Link>
      </p>
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Target Pendapatan</p>
          <h1>Buat Target Pendapatan Baru</h1>
        </div>
      </header>
      <section className="dashboard-section">
        <CreatePlanForm kind="revenue_target" entityId={membership.entity_id} entity={entity} />
      </section>
    </div>
  );
}
