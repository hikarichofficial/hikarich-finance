import Link from "next/link";
import {
  ENTRY_TYPE_LABELS,
  JOURNAL_FILTER_OPTIONS,
  JOURNAL_STATUS_FILTER_OPTIONS,
  entryTypeLabel,
  journalListStatus,
  periodLabel,
  type JournalListFilter,
  type JournalStatusFilter,
} from "@/domain/accounting/journalList";
import type { AccountingPeriodRow, JournalEntryRow } from "@/schemas/accounting";
import { formatShortDate } from "./format";

/**
 * Journal List (P13 Part 3d, Step 09 §9, §14): "Accounting is a secondary/advanced work area, not the default
 * daily landing zone" -- reached from the Accounting nav group (`accounting.view`), not the Dashboard. Follows
 * the Standard List Screen Pattern with a toolbar of three `<select>` filters (source/entry type, period,
 * status) in one GET form, the same shape Cash/Bank Activity used for a filter set too varied for a small
 * fixed row of tabs. No Create button: journal creation is the Advanced Adjustments builder (`entry_type`
 * manual/adjusting only), deferred per decision 164's "materially larger builder" test -- this list only
 * shows every journal already in the database, whatever created it.
 */

export function JournalsListScreen({
  rows,
  periods,
  entryType,
  status,
  periodId,
  query,
  entity,
}: {
  rows: readonly JournalEntryRow[];
  periods: readonly AccountingPeriodRow[];
  entryType: JournalListFilter | null;
  status: JournalStatusFilter | null;
  periodId: string | null;
  query: string;
  entity: string | undefined;
}) {
  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Jurnal</h1>
          <p className="list-screen-summary">{rows.length} jurnal ditampilkan.</p>
        </div>
      </header>

      <div className="list-screen-toolbar">
        <form method="get" className="list-search-form">
          {entity ? <input type="hidden" name="entity" value={entity} /> : null}
          <label>
            Sumber
            <select name="type" defaultValue={entryType ?? ""}>
              {JOURNAL_FILTER_OPTIONS.map((option) => (
                <option key={option.label} value={option.value ?? ""}>
                  {option.label}
                </option>
              ))}
            </select>
          </label>
          <label>
            Status
            <select name="status" defaultValue={status ?? ""}>
              {JOURNAL_STATUS_FILTER_OPTIONS.map((option) => (
                <option key={option.label} value={option.value ?? ""}>
                  {option.label}
                </option>
              ))}
            </select>
          </label>
          <label>
            Periode
            <select name="period" defaultValue={periodId ?? ""}>
              <option value="">Semua Periode</option>
              {periods.map((period) => (
                <option key={period.id} value={period.id}>
                  {periodLabel(period)}
                </option>
              ))}
            </select>
          </label>
          <input
            type="search"
            name="q"
            defaultValue={query}
            placeholder="Cari nomor jurnal, deskripsi…"
            aria-label="Cari jurnal"
          />
          <button type="submit" className="btn-secondary">
            Terapkan
          </button>
        </form>
      </div>

      {rows.length === 0 ? (
        <div className="list-empty">
          <p>Tidak ada jurnal pada saringan ini.</p>
        </div>
      ) : (
        <table className="record-table">
          <thead>
            <tr>
              <th scope="col">No. Jurnal</th>
              <th scope="col">Tanggal</th>
              <th scope="col">Sumber</th>
              <th scope="col">Deskripsi</th>
              <th scope="col">Status</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => {
              const rowStatus = journalListStatus(row);
              const href = entity
                ? `/accounting/journal/${row.id}?entity=${encodeURIComponent(entity)}`
                : `/accounting/journal/${row.id}`;
              return (
                <tr key={row.id}>
                  <td>
                    <Link href={href}>{row.journal_number ?? "Draf"}</Link>
                  </td>
                  <td>{formatShortDate(row.entry_date)}</td>
                  <td>{entryTypeLabel(row.entry_type)}</td>
                  <td>{row.description}</td>
                  <td>
                    <span className={`status-badge status-badge-${rowStatus.tone}`}>
                      {rowStatus.text}
                    </span>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
    </div>
  );
}

// Re-export for pages that only need the label map (avoids importing the domain module directly there).
export { ENTRY_TYPE_LABELS };
