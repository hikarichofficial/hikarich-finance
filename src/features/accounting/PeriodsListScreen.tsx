import Link from "next/link";
import type { ReactNode } from "react";
import { periodStatusDisplay } from "@/domain/accounting/periodsList";
import type { AccountingPeriodRow } from "@/schemas/accounting";
import { formatShortDate } from "./format";

/**
 * Accounting Periods List (P13, Step 09 §14). No Create action -- periods come from the calendar/fiscal-year
 * setup, not a form (no RPC creates one; `accounting_periods` is seeded per Entity). Same
 * header/table/empty-state structure every other List screen uses, without a search toolbar since a year
 * carries at most ~12 rows and every one is meant to be seen, not filtered out.
 */
export function PeriodsListScreen({
  rows,
  entity,
  yearClose,
}: {
  rows: readonly AccountingPeriodRow[];
  entity: string | undefined;
  /** The fiscal-year close / reverse forms (client components), passed in by the page. */
  yearClose?: ReactNode;
}) {
  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Periode Akuntansi</h1>
          <p className="list-screen-summary">{rows.length} periode ditampilkan.</p>
        </div>
      </header>

      {rows.length === 0 ? (
        <div className="list-empty">
          <p>Belum ada periode akuntansi untuk Entity ini.</p>
        </div>
      ) : (
        <table className="record-table record-table-stacked">
          <thead>
            <tr>
              <th scope="col">Periode</th>
              <th scope="col">Tahun Fiskal</th>
              <th scope="col">Status</th>
              <th scope="col">Ditutup</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => {
              const status = periodStatusDisplay(row.status);
              const href = entity
                ? `/accounting/periods/${row.id}?entity=${encodeURIComponent(entity)}`
                : `/accounting/periods/${row.id}`;
              return (
                <tr key={row.id}>
                  <td>
                    <Link href={href}>
                      {formatShortDate(row.period_start)} – {formatShortDate(row.period_end)}
                    </Link>
                  </td>
                  <td data-label="Tahun Fiskal">{row.fiscal_year}</td>
                  <td data-label="Status">
                    <span className={`status-badge status-badge-${status.tone}`}>
                      {status.text}
                    </span>
                  </td>
                  <td data-label="Ditutup">
                    {row.closed_at ? formatShortDate(row.closed_at.slice(0, 10)) : "—"}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
      {yearClose}
    </div>
  );
}
