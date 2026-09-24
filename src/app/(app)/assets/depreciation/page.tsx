import { requirePermission } from "@/services/identity/access";
import {
  depreciationDue,
  depreciationReport,
  getEntityBaseCurrency,
} from "@/services/assets/assets";
import {
  depreciationDuePostable,
  depreciationTotals,
  filterDepreciationRows,
  resolveDepreciationRange,
} from "@/domain/assets/depreciationReport";
import { DepreciationReportScreen } from "@/features/assets/DepreciationReportScreen";

/** Depreciation report (P13 Part 3f, fifth and final increment, Step 09 §9, §16). `?from=`/`?to=` are sent
 * straight to `asset_depreciation_report`'s own `p_from`/`p_to` arguments (server-side filtering, mirroring
 * Cash/Bank Activity's `resolveActivityRange`); `?q=` is a client-side asset code/name search. `asset_depreciation_due`
 * is read for the same range's `to` bound as the "through" cut-off, for the attention band. Both RPCs are
 * gated on `assets.view` (verified directly against `20260926100400_p8_asset_reports.sql`'s own
 * `has_permission` checks), matching this route's own permission and the nav item's already-correct
 * declaration -- no bug to fix here, unlike decision 176's Other Receivables/Payables find. */
export default async function DepreciationReportPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; from?: string; to?: string; q?: string }>;
}) {
  const { entity, from, to, q } = await searchParams;
  const { membership } = await requirePermission("assets.view", { entityCode: entity });
  const range = resolveDepreciationRange(from, to);
  const query = q ?? "";

  const [entries, dueRows, currency] = await Promise.all([
    depreciationReport({ entity_id: membership.entity_id, from: range.from, to: range.to }),
    depreciationDue(membership.entity_id, range.to),
    getEntityBaseCurrency(membership.entity_id),
  ]);
  const rows = filterDepreciationRows(entries, query);
  const due = depreciationDuePostable(dueRows);
  const totalsDecimal = depreciationTotals(rows);
  const totals = {
    posted: totalsDecimal.posted.toString(),
    scheduled: totalsDecimal.scheduled.toString(),
  };

  return (
    <DepreciationReportScreen
      rows={rows}
      due={due}
      totals={totals}
      range={range}
      query={query}
      currency={currency}
      entity={entity}
    />
  );
}
