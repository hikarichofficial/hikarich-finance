import { formatMoney } from "@/domain/money/format";
import { PLAN_PERIOD_TYPE_LABELS, monthRangeInclusive } from "@/domain/planning/planning";
import { planStatusBadge } from "@/domain/planning/budgetList";
import type { CategoryRow } from "@/schemas/categories";
import type { BudgetLineRow, BudgetReportRow, BudgetRow } from "@/schemas/planning";
import { BudgetActions, type BudgetActionPermissions } from "./BudgetActions";
import { BudgetLinesEditor } from "./BudgetLinesEditor";
import { formatShortDate } from "./format";
import { BackLink } from "@/features/shell/BackLink";

/**
 * Budget Detail (P13 Part 3h, second increment, Step 09 §10, §18: "period-based editable planning tables
 * with Actual vs Budget/Target comparisons"). No per-budget RPC returns the row itself -- only `list_budgets`,
 * Entity-scoped -- so the page fetches the register and finds the row by id, the same precedent decisions
 * 169/179/183 already established. `get_budget_report` is a strict superset of `get_budget_lines` (it already
 * carries every budgeted-line's own category/month/amount, plus Actual/Committed/Remaining/%Used/Variance
 * computed live) so this screen fetches only the report, not the raw lines separately. "Perkiraan" is
 * `forecast_amount`: the 3-month average actual for the current and future months, "—" for past months
 * (decision 250, OWNER answer to decision 139). The report is already ordered by the RPC itself
 * (`period_month`, then category `sort_order`/`name`) -- rendered in that order rather than re-grouped, the
 * same "trust the RPC's own order" choice every other flat report table in this codebase makes. Activate/
 * Close are rendered as actual buttons by `BudgetActions` (P13 Part 3h, fourth increment). "Atur Baris
 * Anggaran" (P13 Part 3h, fifth increment) renders `BudgetLinesEditor` -- gated the same way every other
 * write action on this screen is (`permissions.canManage`), and only while the budget is not `closed` (a
 * closed budget can never be reopened or edited again, `budgetActions`'s own reasoning). Its month columns
 * are derived from the budget's own date range (`monthRangeInclusive`) rather than fetched, and it is keyed
 * by `budget.version` so a successful save (which bumps the version) remounts it with the freshly revalidated
 * `lines` rather than keeping stale local row state around.
 */
export function BudgetDetailScreen({
  budget,
  report,
  lines,
  categories,
  currency,
  backHref,
  permissions,
}: {
  budget: BudgetRow;
  report: readonly BudgetReportRow[];
  lines: readonly BudgetLineRow[];
  categories: readonly CategoryRow[];
  currency: string;
  backHref: string;
  permissions: BudgetActionPermissions;
}) {
  const statusBadge = planStatusBadge(budget.status);
  const months = monthRangeInclusive(budget.start_date, budget.end_date);
  const canEditLines = permissions.canManage && budget.status !== "closed";

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <BackLink href={backHref}>← Kembali ke daftar anggaran</BackLink>
      </p>

      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">
            Anggaran · {PLAN_PERIOD_TYPE_LABELS[budget.period_type]}
          </p>
          <h1>{budget.name}</h1>
        </div>
        <div className="record-detail-header-end">
          <span className={`status-badge status-badge-${statusBadge.tone}`}>
            {statusBadge.text}
          </span>
        </div>
      </header>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Ringkasan</h2>
        </div>
        <dl className="record-summary-grid">
          <div>
            <dt>Periode</dt>
            <dd>
              {formatShortDate(budget.start_date)} – {formatShortDate(budget.end_date)}
            </dd>
          </div>
          <div>
            <dt>Tahun Fiskal</dt>
            <dd>{budget.fiscal_year ?? "—"}</dd>
          </div>
          {budget.note ? (
            <div>
              <dt>Catatan</dt>
              <dd>{budget.note}</dd>
            </div>
          ) : null}
        </dl>
        <BudgetActions budgetId={budget.id} status={budget.status} permissions={permissions} />
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Atur Baris Anggaran</h2>
        </div>
        {canEditLines ? (
          <BudgetLinesEditor
            key={budget.version}
            budgetId={budget.id}
            months={months}
            categories={categories}
            existingLines={lines}
            expectedVersion={budget.version}
            currency={currency}
          />
        ) : (
          <p className="hint">
            {budget.status === "closed"
              ? "Anggaran yang ditutup tidak dapat diedit lagi."
              : "Anda tidak memiliki izin untuk mengubah baris anggaran."}
          </p>
        )}
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Anggaran vs Aktual</h2>
        </div>
        {report.length === 0 ? (
          <p className="dashboard-empty">Belum ada baris anggaran.</p>
        ) : (
          <table className="record-table">
            <thead>
              <tr>
                <th scope="col">Bulan</th>
                <th scope="col">Kategori</th>
                <th scope="col" className="num">
                  Anggaran
                </th>
                <th scope="col" className="num">
                  Aktual
                </th>
                <th scope="col" className="num">
                  Komitmen
                </th>
                <th scope="col" className="num">
                  Sisa
                </th>
                <th scope="col" className="num">
                  % Terpakai
                </th>
                <th scope="col" className="num">
                  Varians
                </th>
                <th scope="col" className="num">
                  Perkiraan
                </th>
              </tr>
            </thead>
            <tbody>
              {report.map((line, index) => (
                <tr key={`${line.category_id}-${line.period_month}-${index}`}>
                  <td>{formatShortDate(line.period_month)}</td>
                  <td>{line.category_name}</td>
                  <td className="num">{formatMoney(line.budgeted_amount, currency)}</td>
                  <td className="num">{formatMoney(line.actual_amount, currency)}</td>
                  <td className="num">{formatMoney(line.committed_amount, currency)}</td>
                  <td className="num">{formatMoney(line.remaining_amount, currency)}</td>
                  <td className="num">{line.pct_used === null ? "—" : `${line.pct_used}%`}</td>
                  <td className="num">{formatMoney(line.variance_amount, currency)}</td>
                  <td className="num">
                    {line.forecast_amount === null
                      ? "—"
                      : formatMoney(line.forecast_amount, currency)}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>
    </div>
  );
}
