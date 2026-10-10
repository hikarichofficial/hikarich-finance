import { formatMoney } from "@/domain/money/format";
import { PLAN_PERIOD_TYPE_LABELS, monthRangeInclusive } from "@/domain/planning/planning";
import { planStatusBadge } from "@/domain/planning/budgetList";
import type { CategoryRow } from "@/schemas/categories";
import type {
  RevenueTargetLineRow,
  RevenueTargetReportRow,
  RevenueTargetRow,
} from "@/schemas/planning";
import { RevenueTargetActions, type RevenueTargetActionPermissions } from "./RevenueTargetActions";
import { RevenueTargetLinesEditor } from "./RevenueTargetLinesEditor";
import { formatShortDate } from "./format";
import { BackLink } from "@/features/shell/BackLink";

/**
 * Revenue Target Detail (P13 Part 3h, third increment, Step 09 §10, §18: "period-based editable planning
 * tables with Actual vs Budget/Target comparisons"). No per-target RPC returns the row itself -- only
 * `list_revenue_targets`, Entity-scoped -- so this screen fetches the register and finds the row by id, the
 * same precedent decisions 169/179/183/184 already established. Unlike Budgets there are no
 * Committed/Remaining/%Used columns -- `get_revenue_target_report` returns Target, Actual (issued invoice
 * revenue) and AR Outstanding. Since decision 399 a target may also be split per revenue category, so the
 * report carries a "Target" column naming what each row is about: the whole Entity, or one category. The
 * Entity row and the category rows of a month are deliberately not added together -- they are two different
 * sums (the invoice total against the invoice lines of that category), and the parts need not cover the
 * whole. Open AR and "Perkiraan" belong to the Entity row only, for the same reason. "Perkiraan" is the
 * 3-month average issued revenue for the current and future months, "—" for past months (decision 250). The report is already ordered by the RPC itself (`period_month`) -- rendered in that order.
 * Activate/Close are rendered as actual buttons by `RevenueTargetActions` (P13 Part 3h, fourth increment).
 * "Atur Baris Target Pendapatan" (P13 Part 3h, fifth increment) renders `RevenueTargetLinesEditor` -- gated
 * and keyed exactly like Budget Detail's own `BudgetLinesEditor` (`permissions.canManage`, not while
 * `closed`, keyed by `target.version` so a successful save remounts it from the freshly revalidated `lines`).
 */
export function RevenueTargetDetailScreen({
  target,
  report,
  lines,
  categories,
  currency,
  backHref,
  permissions,
}: {
  target: RevenueTargetRow;
  report: readonly RevenueTargetReportRow[];
  lines: readonly RevenueTargetLineRow[];
  categories: readonly CategoryRow[];
  currency: string;
  backHref: string;
  permissions: RevenueTargetActionPermissions;
}) {
  const statusBadge = planStatusBadge(target.status);
  const months = monthRangeInclusive(target.start_date, target.end_date);
  const canEditLines = permissions.canManage && target.status !== "closed";

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <BackLink href={backHref}>← Kembali ke daftar target pendapatan</BackLink>
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
        <RevenueTargetActions
          targetId={target.id}
          status={target.status}
          permissions={permissions}
        />
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Atur Baris Target Pendapatan</h2>
        </div>
        {canEditLines ? (
          <RevenueTargetLinesEditor
            key={target.version}
            targetId={target.id}
            months={months}
            categories={categories}
            existingLines={lines}
            expectedVersion={target.version}
            currency={currency}
          />
        ) : (
          <p className="hint">
            {target.status === "closed"
              ? "Target pendapatan yang ditutup tidak dapat diedit lagi."
              : "Anda tidak memiliki izin untuk mengubah baris target pendapatan."}
          </p>
        )}
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
                <th scope="col">Target</th>
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
                <th scope="col" className="num">
                  Perkiraan
                </th>
              </tr>
            </thead>
            <tbody>
              {report.map((line) => (
                <tr key={`${line.period_month}-${line.category_id ?? "total"}`}>
                  <td>{formatShortDate(line.period_month)}</td>
                  <td>
                    {line.category_id === null ? (
                      <strong>Seluruh Entitas</strong>
                    ) : (
                      (line.category_name ?? "Kategori")
                    )}
                  </td>
                  <td className="num">{formatMoney(line.target_amount, currency)}</td>
                  <td className="num">{formatMoney(line.actual_amount, currency)}</td>
                  <td className="num">
                    {line.category_id === null
                      ? formatMoney(line.ar_outstanding_amount, currency)
                      : "—"}
                  </td>
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
