import Link from "next/link";
import { PLAN_PERIOD_TYPE_LABELS } from "@/domain/planning/planning";
import {
  PLAN_STATUS_FILTER_OPTIONS,
  planStatusBadge,
  type PlanStatusFilterOption,
} from "@/domain/planning/budgetList";
import type { BudgetRow } from "@/schemas/planning";
import type { PlanStatus } from "@/domain/planning/planning";
import { RecordPreviewLink } from "@/features/shell/RecordPreviewLink";
import { formatShortDate } from "./format";

/**
 * Budget Register (P13 Part 3h, second increment, Step 09 §9, §18). Follows the same Standard List Screen
 * Pattern as Recurring Rules (decision 183): `list_budgets`'s own `p_status` argument is sent server-side,
 * only the free-text name search is client-side. No Create button -- a budget's own create flow is a
 * multi-step period x category grid builder (`set_budget_lines` takes up to 2000 lines) -- shipped in the
 * fifth increment as its own "set lines" grid on Budget Detail, reached from here via the "Buat Anggaran
 * Baru" button (`canCreate`, `planning.budget_edit`, the exact permission `create_budget` itself checks).
 * The empty state carries one CTA (Step 09 §9/§25, Step 10 §24, decision 218): "Hapus Saringan" when the
 * status/query form is active, else the header's own "Buat Anggaran Baru" action.
 */
export function BudgetRegisterScreen({
  rows,
  status,
  query,
  entity,
  canCreate,
}: {
  rows: readonly BudgetRow[];
  status: PlanStatus | null;
  query: string;
  entity: string | undefined;
  canCreate: boolean;
}) {
  const newHref = entity
    ? `/planning/budgets/new?entity=${encodeURIComponent(entity)}`
    : "/planning/budgets/new";
  const baseHref = entity
    ? `/planning/budgets?entity=${encodeURIComponent(entity)}`
    : "/planning/budgets";
  const isFiltered = Boolean(status) || query.trim().length > 0;

  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Anggaran</h1>
          <p className="list-screen-summary">{rows.length} anggaran ditampilkan.</p>
        </div>
        {canCreate ? (
          <Link href={newHref} className="btn-primary">
            Buat Anggaran Baru
          </Link>
        ) : null}
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
          {isFiltered ? (
            <Link href={baseHref} className="btn-secondary list-empty-action">
              Hapus Saringan
            </Link>
          ) : canCreate ? (
            <Link href={newHref} className="btn-primary list-empty-action">
              Buat Anggaran Baru
            </Link>
          ) : null}
        </div>
      ) : (
        <table className="record-table record-table-stacked">
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
                    <RecordPreviewLink
                      href={href}
                      label={row.name}
                      eyebrow="Anggaran"
                      title={row.name}
                      badges={[{ tone: badge.tone, text: badge.text }]}
                      fields={[
                        { label: "Jenis Periode", value: PLAN_PERIOD_TYPE_LABELS[row.period_type] },
                        { label: "Tahun Fiskal", value: row.fiscal_year ?? "—" },
                        {
                          label: "Periode",
                          value: `${formatShortDate(row.start_date)} – ${formatShortDate(row.end_date)}`,
                        },
                      ]}
                    />
                  </td>
                  <td data-label="Jenis Periode">{PLAN_PERIOD_TYPE_LABELS[row.period_type]}</td>
                  <td data-label="Tahun Fiskal">{row.fiscal_year ?? "—"}</td>
                  <td data-label="Periode">
                    {formatShortDate(row.start_date)} – {formatShortDate(row.end_date)}
                  </td>
                  <td data-label="Status">
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
