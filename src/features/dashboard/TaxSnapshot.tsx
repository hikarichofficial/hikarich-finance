import Link from "next/link";
import { Decimal } from "@/domain/money/decimal";
import { formatMoney } from "@/domain/money/format";
import { CALENDAR_STATE_LABELS, CALENDAR_STEP_LABELS, TAX_TYPE_LABELS } from "@/domain/tax/tax";
import type { DashboardTaxSection } from "@/services/dashboard/dashboard";
import { formatShortDate } from "./format";

const STATE_BADGE_CLASS: Readonly<Record<string, string>> = {
  overdue: "status-badge-critical",
  due: "status-badge-attention",
  upcoming: "status-badge-progress",
};

/** Tax Snapshot (Step 09 §8, Step 10 §10): current recorded obligations by tax type and the nearest
 * not-yet-done deadlines. Both numbers come straight from `tax_overview`/`tax_calendar` -- the Dashboard
 * never recomputes a tax position. */
export function TaxSnapshot({
  currency,
  tax,
}: {
  currency: string;
  tax: DashboardTaxSection | null;
}) {
  if (!tax) return null;
  const outstandingEntries = Object.entries(tax.overview.outstanding).filter(
    ([, amount]) => !Decimal.parse(amount).isZero(),
  );

  return (
    <section className="dashboard-section">
      <div className="dashboard-section-header">
        <h2 className="dashboard-section-title">Ringkasan Pajak</h2>
        <Link className="dashboard-section-link" href="/tax">
          Buka Pajak
        </Link>
      </div>

      {outstandingEntries.length > 0 ? (
        <ul className="dashboard-list">
          {outstandingEntries.map(([taxType, amount]) => (
            <li key={taxType} className="dashboard-list-item">
              <p className="dashboard-list-item-title">
                {TAX_TYPE_LABELS[taxType as keyof typeof TAX_TYPE_LABELS] ?? taxType}
              </p>
              <span className="dashboard-list-item-value">{formatMoney(amount, currency)}</span>
            </li>
          ))}
        </ul>
      ) : (
        <p className="dashboard-empty">Tidak ada kewajiban pajak terutang.</p>
      )}

      {tax.overview.needs_review_count > 0 ? (
        <p className="dashboard-list-item-detail dashboard-note">
          {tax.overview.needs_review_count} transaksi perlu ditinjau untuk penentuan pajak.
        </p>
      ) : null}

      {tax.deadlines.length > 0 ? (
        <>
          <div className="dashboard-section-header dashboard-subsection">
            <h3 className="dashboard-section-title">Tenggat Terdekat</h3>
            <Link className="dashboard-section-link" href="/tax/calendar">
              Lihat kalender
            </Link>
          </div>
          <ul className="dashboard-list">
            {tax.deadlines.map((row) => (
              <li
                key={`${row.tax_type}-${row.tax_period}-${row.step}`}
                className="dashboard-list-item"
              >
                <div>
                  <p className="dashboard-list-item-title">
                    {TAX_TYPE_LABELS[row.tax_type]} · {CALENDAR_STEP_LABELS[row.step]}
                  </p>
                  <p className="dashboard-list-item-detail">
                    <span
                      className={`status-badge ${STATE_BADGE_CLASS[row.state] ?? "status-badge-neutral"}`}
                    >
                      {CALENDAR_STATE_LABELS[row.state]}
                    </span>
                  </p>
                </div>
                <div className="dashboard-list-item-end">
                  {row.due_date ? (
                    <span className="dashboard-list-item-date">
                      {formatShortDate(row.due_date)}
                    </span>
                  ) : null}
                  {row.outstanding !== null ? (
                    <span className="dashboard-list-item-value">
                      {formatMoney(row.outstanding, currency)}
                    </span>
                  ) : null}
                </div>
              </li>
            ))}
          </ul>
        </>
      ) : null}
    </section>
  );
}
