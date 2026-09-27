import Link from "next/link";
import { PLAN_PERIOD_TYPE_LABELS } from "@/domain/planning/planning";
import {
  PLAN_STATUS_FILTER_OPTIONS,
  planStatusBadge,
  type PlanStatusFilterOption,
} from "@/domain/planning/budgetList";
import type { RevenueTargetRow } from "@/schemas/planning";
import type { PlanStatus } from "@/domain/planning/planning";
import { formatShortDate } from "./format";

/**
 * Revenue Target Register (P13 Part 3h, third increment, Step 09 §9, §18). Follows the same Standard List
 * Screen Pattern as Recurring Rules (decision 183) and Budgets (decision 184): `list_revenue_targets`'s own
 * `p_status` argument is sent server-side, only the free-text name search is client-side. No Create button --
 * a revenue target's own create flow is a multi-step period grid builder (`set_revenue_target_lines`),
 * deferred to a later increment along with activate/close, the same ordering decision 164 already set out.
 */
export function RevenueTargetRegisterScreen({
  rows,
  status,
  query,
  entity,
}: {
  rows: readonly RevenueTargetRow[];
  status: PlanStatus | null;
  query: string;
  entity: string | undefined;
}) {
  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Target Pendapatan</h1>
          <p className="list-screen-summary">{rows.length} target pendapatan ditampilkan.</p>
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
            placeholder="Cari nama target pendapatan…"
            aria-label="Cari target pendapatan"
          />
          <button type="submit" className="btn-secondary">
            Terapkan
          </button>
        </form>
      </div>

      {rows.length === 0 ? (
        <div className="list-empty">
          <p>Tidak ada target pendapatan pada saringan ini.</p>
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
                ? `/planning/targets/${row.id}?entity=${encodeURIComponent(entity)}`
                : `/planning/targets/${row.id}`;
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
