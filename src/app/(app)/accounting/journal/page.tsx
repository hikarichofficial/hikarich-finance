import { requirePermission } from "@/services/identity/access";
import { listAccountingPeriods, listJournals } from "@/services/accounting/ledger";
import {
  filterJournalRows,
  parseJournalFilter,
  parseJournalStatusFilter,
} from "@/domain/accounting/journalList";
import { JournalsListScreen } from "@/features/accounting/JournalsListScreen";

/** Journal List (P13 Part 3d, Step 09 §9, §14). `?type=` filters by `entry_type`, `?status=` by
 * draft/posted, `?period=` by `accounting_periods.id` -- an absent or unknown value shows every journal,
 * matching every other List screen's own null-filter meaning. */
export default async function JournalListPage({
  searchParams,
}: {
  searchParams: Promise<{
    entity?: string;
    type?: string;
    status?: string;
    period?: string;
    q?: string;
  }>;
}) {
  const { entity, type, status, period, q } = await searchParams;
  const { membership } = await requirePermission("accounting.view", { entityCode: entity });
  const entryType = parseJournalFilter(type) ?? null;
  const journalStatus = parseJournalStatusFilter(status) ?? null;
  const periodId = period ?? null;
  const query = q ?? "";

  const [journals, periods] = await Promise.all([
    listJournals(membership.entity_id),
    listAccountingPeriods(membership.entity_id),
  ]);
  const rows = filterJournalRows(journals, entryType, journalStatus, periodId, query);

  return (
    <JournalsListScreen
      rows={rows}
      periods={periods}
      entryType={entryType}
      status={journalStatus}
      periodId={periodId}
      query={query}
      entity={entity}
    />
  );
}
