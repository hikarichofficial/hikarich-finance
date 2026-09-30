import { requirePermission } from "@/services/identity/access";
import { listAccountingPeriods } from "@/services/accounting/ledger";
import { sortPeriodsByStart } from "@/domain/accounting/periodsList";
import { PeriodsListScreen } from "@/features/accounting/PeriodsListScreen";

/** Accounting Periods List (P13, Step 09 §14). */
export default async function PeriodsListPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  const { membership } = await requirePermission("accounting.view", { entityCode: entity });

  const rows = await listAccountingPeriods(membership.entity_id);
  const sorted = sortPeriodsByStart(rows);

  return <PeriodsListScreen rows={sorted} entity={entity} />;
}
