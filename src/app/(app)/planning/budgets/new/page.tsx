import { requirePermission } from "@/services/identity/access";
import { CreatePlanForm } from "@/features/planning/CreatePlanForm";
import { BackLink } from "@/features/shell/BackLink";

/** Budget create form (P13 Part 3h, fifth increment, Step 09 §13, §18). Gated on `planning.budget_edit`, the
 * exact permission `create_budget` itself checks (decision 184's own confirmed mapping) -- the same
 * "gate the page on the create RPC's own permission" shape `NewTransferPage` already established. Creates
 * only the draft shell (name/period_type/start_date/end_date/fiscal_year/note); filling in lines happens on
 * the resulting Budget's own Detail page, which this form's `redirect()`-on-success sends the user to. */
export default async function NewBudgetPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  const { membership } = await requirePermission("planning.budget_edit", { entityCode: entity });

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <BackLink
          href={
            entity ? `/planning/budgets?entity=${encodeURIComponent(entity)}` : "/planning/budgets"
          }
        >
          ← Kembali ke daftar anggaran
        </BackLink>
      </p>
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Anggaran</p>
          <h1>Buat Anggaran Baru</h1>
        </div>
      </header>
      <section className="dashboard-section">
        <CreatePlanForm kind="budget" entityId={membership.entity_id} entity={entity} />
      </section>
    </div>
  );
}
