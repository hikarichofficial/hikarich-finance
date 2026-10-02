import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import { listAccountingPeriods } from "@/services/accounting/ledger";
import { sortPeriodsByStart } from "@/domain/accounting/periodsList";
import { listFiscalYearClosures } from "@/services/reports/reports";
import { PeriodsListScreen } from "@/features/accounting/PeriodsListScreen";
import { FiscalYearForms } from "@/features/accounting/FiscalYearForms";

/** Accounting Periods List (P13, Step 09 §14). The year-end forms appear for `periods.close` (the permission
 * `close_fiscal_year` checks) and `periods.reopen` (`reverse_fiscal_year_closing`, which also needs a recent
 * step-up). */
export default async function PeriodsListPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  const { access, membership } = await requirePermission("accounting.view", { entityCode: entity });

  const rows = await listAccountingPeriods(membership.entity_id);
  const sorted = sortPeriodsByStart(rows);

  const canClose = can(access, membership.entity_id, "periods.close");
  const canReverse = can(access, membership.entity_id, "periods.reopen");
  const closures =
    canClose || canReverse
      ? await listFiscalYearClosures(membership.entity_id).catch(() => [])
      : [];
  const closedYears = closures.filter((c) => c.reversed_at === null).map((c) => c.fiscal_year);
  const years = [...new Set(sorted.map((row) => row.fiscal_year))].sort((a, b) => b - a);
  const selfHref = entity
    ? `/accounting/periods?entity=${encodeURIComponent(entity)}`
    : "/accounting/periods";

  return (
    <PeriodsListScreen
      rows={sorted}
      entity={entity}
      yearClose={
        (canClose || canReverse) && years.length > 0 ? (
          <FiscalYearForms
            entity={entity}
            years={years}
            closedYears={closedYears}
            canClose={canClose}
            canReverse={canReverse}
            next={selfHref}
          />
        ) : null
      }
    />
  );
}
