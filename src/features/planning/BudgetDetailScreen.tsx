import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import { PLAN_PERIOD_TYPE_LABELS } from "@/domain/planning/planning";
import { planStatusBadge } from "@/domain/planning/budgetList";
import type { BudgetReportRow, BudgetRow } from "@/schemas/planning";
import { formatShortDate } from "./format";

/**
 * Budget Detail (P13 Part 3h, second increment, Step 09 §10, §18: "period-based editable planning tables
 * with Actual vs Budget/Target comparisons"). No per-budget RPC returns the row itself -- only `list_budgets`,
 * Entity-scoped -- so the page fetches the register and finds the row by id, the same precedent decisions
 * 169/179/183 already established. `get_budget_report` is a strict superset of `get_budget_lines` (it already
 * carries every budgeted-line's own category/month/amount, plus Actual/Committed/Remaining/%Used/Variance
 * computed live) so this screen fetches only the report, not the raw lines separately. `forecast_amount` is
 * never rendered as its own column -- the RPC always returns it `null` (decision 139: "no locked spec defines
 * a projection methodology, filed as an open OWNER question"), so a column that could only ever show "—"
 * would be pure noise rather than information. The report is already ordered by the RPC itself
 * (`period_month`, then category `sort_order`/`name`) -- rendered in that order rather than re-grouped, the
 * same "trust the RPC's own order" choice every other flat report table in this codebase makes.
 */
export function BudgetDetailScreen({
  budget,
  report,
  currency,
  backHref,
}: {
  budget: BudgetRow;
  report: readonly BudgetReportRow[];
  currency: string;
  backHref: string;
}) {
  const statusBadge = planStatusBadge(budget.status);

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={backHref}>← Kembali ke daftar anggaran</Link>
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
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>
    </div>
  );
}
