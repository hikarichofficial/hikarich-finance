import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import { PLAN_PERIOD_TYPE_LABELS } from "@/domain/planning/planning";
import { planStatusBadge } from "@/domain/planning/budgetList";
import type { RevenueTargetReportRow, RevenueTargetRow } from "@/schemas/planning";
import { formatShortDate } from "./format";

/**
 * Revenue Target Detail (P13 Part 3h, third increment, Step 09 §10, §18: "period-based editable planning
 * tables with Actual vs Budget/Target comparisons"). No per-target RPC returns the row itself -- only
 * `list_revenue_targets`, Entity-scoped -- so this screen fetches the register and finds the row by id, the
 * same precedent decisions 169/179/183/184 already established. Unlike Budgets, a revenue target has no
 * category breakdown (Step 01 #23 names no "Category -> Subcategory" the way #22 does for Budgets) and no
 * Committed/Remaining/%Used columns -- `get_revenue_target_report` returns only Target, Actual (issued
 * invoice revenue) and AR Outstanding per month, entity-wide. `forecast_amount` is never rendered as its own
 * column for the same reason as Budget Detail: the RPC always returns it `null` (decision 139's own "no
 * locked projection methodology" ruling), so a column that could only ever show "—" would be noise, not
 * information. The report is already ordered by the RPC itself (`period_month`) -- rendered in that order.
 */
export function RevenueTargetDetailScreen({
  target,
  report,
  currency,
  backHref,
}: {
  target: RevenueTargetRow;
  report: readonly RevenueTargetReportRow[];
  currency: string;
  backHref: string;
}) {
  const statusBadge = planStatusBadge(target.status);

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={backHref}>← Kembali ke daftar target pendapatan</Link>
      </p>

      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">
            Target Pendapatan · {PLAN_PERIOD_TYPE_LABELS[target.period_type]}
          </p>
          <h1>{target.name}</h1>
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
              {formatShortDate(target.start_date)} – {formatShortDate(target.end_date)}
            </dd>
          </div>
          <div>
            <dt>Tahun Fiskal</dt>
            <dd>{target.fiscal_year ?? "—"}</dd>
          </div>
          {target.note ? (
            <div>
              <dt>Catatan</dt>
              <dd>{target.note}</dd>
            </div>
          ) : null}
        </dl>
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Target vs Aktual</h2>
        </div>
        {report.length === 0 ? (
          <p className="dashboard-empty">Belum ada baris target pendapatan.</p>
        ) : (
          <table className="record-table">
            <thead>
              <tr>
                <th scope="col">Bulan</th>
                <th scope="col" className="num">
                  Target
                </th>
                <th scope="col" className="num">
                  Aktual
                </th>
                <th scope="col" className="num">
                  Piutang Belum Tertagih
                </th>
                <th scope="col" className="num">
                  Varians
                </th>
              </tr>
            </thead>
            <tbody>
              {report.map((line) => (
                <tr key={line.period_month}>
                  <td>{formatShortDate(line.period_month)}</td>
                  <td className="num">{formatMoney(line.target_amount, currency)}</td>
                  <td className="num">{formatMoney(line.actual_amount, currency)}</td>
                  <td className="num">{formatMoney(line.ar_outstanding_amount, currency)}</td>
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
