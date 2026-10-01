import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import {
  FORECAST_MONTH_OPTIONS,
  FORECAST_SOURCE_LABELS,
  type ForecastGrid,
} from "@/domain/planning/forecast";
import type { BudgetRow } from "@/schemas/planning";
import { formatMonthLabel } from "./format";

/**
 * Forecasts (Step 09 §18, decision 250). Clearly labelled as a planning estimate, never an actual. Each
 * figure is the 3-month average actual of its category, or -- when a budget is chosen -- the budgeted
 * amount where that budget plans the category-month (marked). The budget itself is changed on the Budgets
 * screen, so adjusting a forecast means adjusting the budget.
 */
export function ForecastScreen({
  grid,
  currency,
  months,
  budgets,
  budgetId,
  entity,
}: {
  grid: ForecastGrid;
  currency: string;
  months: number;
  budgets: readonly BudgetRow[];
  budgetId: string | null;
  entity: string | undefined;
}) {
  const chosen = budgets.find((b) => b.id === budgetId) ?? null;
  const budgetHref = chosen
    ? `/planning/budgets/${chosen.id}${entity ? `?entity=${encodeURIComponent(entity)}` : ""}`
    : null;
  const empty = grid.groups.every((g) => g.lines.length === 0);

  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Perkiraan</h1>
          <p className="list-screen-summary">
            Estimasi perencanaan, bukan angka aktual. Dasar: rata-rata aktual 3 bulan terakhir per
            kategori{chosen ? `, disesuaikan dengan anggaran "${chosen.name}"` : ""}.
          </p>
        </div>
      </header>

      <div className="list-screen-toolbar">
        <form method="get" className="list-search-form">
          {entity ? <input type="hidden" name="entity" value={entity} /> : null}
          <label>
            Periode
            <select name="months" defaultValue={String(months)}>
              {FORECAST_MONTH_OPTIONS.map((m) => (
                <option key={m} value={m}>
                  {m} bulan
                </option>
              ))}
            </select>
          </label>
          <label>
            Sesuaikan dengan anggaran
            <select name="budget" defaultValue={budgetId ?? ""}>
              <option value="">Tanpa anggaran</option>
              {budgets.map((b) => (
                <option key={b.id} value={b.id}>
                  {b.name}
                </option>
              ))}
            </select>
          </label>
          <button type="submit" className="btn-secondary">
            Terapkan
          </button>
        </form>
      </div>

      {budgetHref ? (
        <p className="hint">
          Angka bertanda * berasal dari anggaran. Untuk mengubahnya,{" "}
          <Link href={budgetHref}>ubah anggaran {chosen?.name}</Link>.
        </p>
      ) : null}

      {empty ? (
        <div className="list-empty">
          <p>
            Belum ada aktivitas dalam 3 bulan terakhir untuk dijadikan dasar perkiraan. Pilih
            anggaran untuk memakai angka anggaran.
          </p>
        </div>
      ) : (
        <div className="plan-lines-table-wrap">
          <table className="record-table">
            <thead>
              <tr>
                <th scope="col">Kategori</th>
                {grid.months.map((m) => (
                  <th key={m} scope="col" className="num">
                    {formatMonthLabel(m)}
                  </th>
                ))}
                <th scope="col" className="num">
                  Total
                </th>
              </tr>
            </thead>
            {grid.groups.map((group) =>
              group.lines.length === 0 ? null : (
                <tbody key={group.kind}>
                  <tr>
                    <th scope="rowgroup" colSpan={grid.months.length + 2}>
                      {group.label}
                    </th>
                  </tr>
                  {group.lines.map((line) => (
                    <tr key={line.categoryId}>
                      <td>{line.name}</td>
                      {line.cells.map((cell) => (
                        <td
                          key={cell.month}
                          className="num"
                          title={FORECAST_SOURCE_LABELS[cell.source]}
                        >
                          {formatMoney(cell.amount, currency)}
                          {cell.source === "budget" ? " *" : ""}
                        </td>
                      ))}
                      <td className="num">{formatMoney(line.total, currency)}</td>
                    </tr>
                  ))}
                  <tr>
                    <td>
                      <strong>Total {group.label}</strong>
                    </td>
                    {group.monthTotals.map((t, i) => (
                      <td key={grid.months[i]} className="num">
                        <strong>{formatMoney(t, currency)}</strong>
                      </td>
                    ))}
                    <td className="num">
                      <strong>{formatMoney(group.total, currency)}</strong>
                    </td>
                  </tr>
                </tbody>
              ),
            )}
            <tfoot>
              <tr>
                <td>
                  <strong>Selisih (Pendapatan − Beban)</strong>
                </td>
                {grid.netByMonth.map((t, i) => (
                  <td key={grid.months[i]} className="num">
                    <strong>{formatMoney(t, currency)}</strong>
                  </td>
                ))}
                <td className="num">
                  <strong>{formatMoney(grid.netTotal, currency)}</strong>
                </td>
              </tr>
            </tfoot>
          </table>
        </div>
      )}
    </div>
  );
}
