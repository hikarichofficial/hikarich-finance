import { notFound } from "next/navigation";
import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import { getPeriodChecks, listAccountingPeriods } from "@/services/accounting/ledger";
import { PeriodCloseScreen } from "@/features/accounting/PeriodCloseScreen";

/** Accounting Period Close Detail (P13, Step 09 §14). No per-period RPC exists, so the page looks the row
 * up from the Entity-scoped `listAccountingPeriods`, the same shape `AccountDetailPage`/`CustomerDetailPage`
 * already use. A period belonging to a different Entity, or one the caller cannot see (`accounting.view`
 * failed already, above), lands here as "not found", never a cross-Entity leak. */
export default async function PeriodClosePage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string }>;
}) {
  const { id } = await params;
  const { entity } = await searchParams;
  const { access, membership } = await requirePermission("accounting.view", { entityCode: entity });

  const periods = await listAccountingPeriods(membership.entity_id);
  const period = periods.find((row) => row.id === id);
  if (!period) notFound();

  const checks = await getPeriodChecks(id);
  const backHref = entity
    ? `/accounting/periods?entity=${encodeURIComponent(entity)}`
    : "/accounting/periods";

  return (
    <PeriodCloseScreen
      period={period}
      checks={checks}
      backHref={backHref}
      permissions={{
        canClose: can(access, membership.entity_id, "periods.close"),
        canReopen: can(access, membership.entity_id, "periods.reopen"),
      }}
    />
  );
}
