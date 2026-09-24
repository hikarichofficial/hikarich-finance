import Link from "next/link";
import { PLAN_PERIOD_TYPE_LABELS } from "@/domain/planning/planning";
import {
  PLAN_STATUS_FILTER_OPTIONS,
  planStatusBadge,
  type PlanStatusFilterOption,
} from "@/domain/planning/budgetList";
import type { BudgetRow } from "@/schemas/planning";
import type { PlanStatus } from "@/domain/planning/planning";
import { formatShortDate } from "./format";

/**
 * Budget Register (P13 Part 3h, second increment, Step 09 §9, §18). Follows the same Standard List Screen
 * Pattern as Recurring Rules (decision 183): `list_budgets`'s own `p_status` argument is sent server-side,
 * only the free-text name search is client-side. No Create button -- a budget's own create flow is a
 * multi-step period x category grid builder (`set_budget_lines` takes up to 2000 lines), materially larger
 * than this list/detail pair, deferred to a later increment along with activate/close (decision 164's own
 * ordering).
 */
export function BudgetRegisterScreen({
  rows,
  status,
  query,
  entity,
}: {
  rows: readonly BudgetRow[];
  status: PlanStatus | null;
  query: string;
  entity: string | undefined;
}) {
  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Anggaran</h1>
          <p className="list-screen-summary">{rows.length} anggaran ditampilkan.</p>
        </div>
      </header>

      <div className="list-screen-toolbar">
        <form method="get" className="list-search-form">
          {entity ? <input type="hidden" name="entity" value={entity} /> : null}
          <label>
            Status
            <select name="status" defaultValue={status ?? ""}>
              {PLAN_STATUS_FILTER_OPTIONS.map((option: PlanStatusFilterOption) => (
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
            placeholder="Cari nama anggaran…"
            aria-label="Cari anggaran"
          />
          <button type="submit" className="btn-secondary">
            Terapkan
          </button>
        </form>
      </div>

      {rows.length === 0 ? (
        <div className="list-empty">
          <p>Tidak ada anggaran pada saringan ini.</p>
        </div>
      ) : (
        <table className="record-table">
          <thead>
            <tr>
              <th scope="col">Nama</th>
              <th scope="col">Jenis Periode</th>
              <th scope="col">Tahun Fiskal</th>
              <th scope="col">Periode</th>
              <th scope="col">Status</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => {
              const badge = planStatusBadge(row.status);
              const href = entity
                ? `/planning/budgets/${row.id}?entity=${encodeURIComponent(entity)}`
                : `/planning/budgets/${row.id}`;
              return (
                <tr key={row.id}>
                  <td>
                    <Link href={href}>{row.name}</Link>
                  </td>
                  <td>{PLAN_PERIOD_TYPE_LABELS[row.period_type]}</td>
                  <td>{row.fiscal_year ?? "—"}</td>
                  <td>
                    {formatShortDate(row.start_date)} – {formatShortDate(row.end_date)}
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
