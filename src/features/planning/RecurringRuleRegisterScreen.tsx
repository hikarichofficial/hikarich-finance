import Link from "next/link";
import { RECURRING_FREQUENCY_LABELS, RECURRING_KIND_LABELS } from "@/domain/planning/planning";
import {
  RECURRING_STATUS_FILTER_OPTIONS,
  recurringStatusBadge,
  type RecurringStatusFilterOption,
} from "@/domain/planning/recurringList";
import type { RecurringRuleRow } from "@/schemas/planning";
import type { RecurringStatus } from "@/domain/planning/planning";
import { formatShortDate } from "./format";

/**
 * Recurring Rules Register (P13 Part 3h, first increment, Step 09 §9, §18: "Recurring Rules list shows next
 * run, status, frequency and generated history"). Follows the same Standard List Screen Pattern as every
 * other Part 3 register: `list_recurring_rules`'s own `p_status` argument is sent server-side (matching the
 * Loan/Payroll Run registers' own split), and only the free-text label search is client-side since no RPC
 * parameter covers it. No Create button -- a recurring rule's own create flow is a multi-step template builder
 * (invoice/bill/expense line items), materially larger than this list/detail pair, so it is deferred to a
 * later increment exactly like every other Part 3 family's own create/edit builder (decision 164's own
 * ordering).
 */
export function RecurringRuleRegisterScreen({
  rows,
  status,
  query,
  entity,
}: {
  rows: readonly RecurringRuleRow[];
  status: RecurringStatus | null;
  query: string;
  entity: string | undefined;
}) {
  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Aturan Berulang</h1>
          <p className="list-screen-summary">{rows.length} aturan ditampilkan.</p>
        </div>
      </header>

      <div className="list-screen-toolbar">
        <form method="get" className="list-search-form">
          {entity ? <input type="hidden" name="entity" value={entity} /> : null}
          <label>
            Status
            <select name="status" defaultValue={status ?? ""}>
              {RECURRING_STATUS_FILTER_OPTIONS.map((option: RecurringStatusFilterOption) => (
                <option key={option.label} value={option.value ?? ""}>
                  {option.label}
                </option>
              ))}
            </select>
          </label>
          <input
            type="search"
            name="q"
            defaultValue={query}
            placeholder="Cari nama aturan…"
            aria-label="Cari aturan berulang"
          />
          <button type="submit" className="btn-secondary">
            Terapkan
          </button>
        </form>
      </div>

      {rows.length === 0 ? (
        <div className="list-empty">
          <p>Tidak ada aturan berulang pada saringan ini.</p>
        </div>
      ) : (
        <table className="record-table">
          <thead>
            <tr>
              <th scope="col">Nama</th>
              <th scope="col">Jenis</th>
              <th scope="col">Frekuensi</th>
              <th scope="col">Berikutnya</th>
              <th scope="col">Terakhir Dibuat</th>
              <th scope="col">Status</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => {
              const badge = recurringStatusBadge(row.status);
              const href = entity
                ? `/planning/recurring/${row.id}?entity=${encodeURIComponent(entity)}`
                : `/planning/recurring/${row.id}`;
              return (
                <tr key={row.id}>
                  <td>
                    <Link href={href}>{row.label}</Link>
                  </td>
                  <td>{RECURRING_KIND_LABELS[row.kind]}</td>
                  <td>{RECURRING_FREQUENCY_LABELS[row.frequency]}</td>
                  <td>{formatShortDate(row.next_occurrence_date)}</td>
                  <td>
                    {row.last_generated_date ? formatShortDate(row.last_generated_date) : "—"}
                  </td>
                  <td>
                    <span className={`status-badge status-badge-${badge.tone}`}>{badge.text}</span>
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
