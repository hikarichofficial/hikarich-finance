import Link from "next/link";
import { Decimal } from "@/domain/money/decimal";
import { formatMoney } from "@/domain/money/format";
import { CALENDAR_STATE_LABELS, CALENDAR_STEP_LABELS, TAX_TYPE_LABELS } from "@/domain/tax/tax";
import { totalOutstanding } from "@/domain/tax/taxOverview";
import type { DashboardTaxSection } from "@/services/dashboard/dashboard";

const DAY_FORMAT = new Intl.DateTimeFormat("id-ID", { day: "numeric", timeZone: "UTC" });
const MONTH_FORMAT = new Intl.DateTimeFormat("id-ID", { month: "short", timeZone: "UTC" });

/** Tax Snapshot (Step 09 §8, Step 10 §10): what is owed by type (share bars) and the nearest not-yet-done
 * deadlines (date cards). Both come straight from `tax_overview`/`tax_calendar` -- the Dashboard never
 * recomputes a tax position. The full page is Ringkasan Pajak. */
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
  const owed = totalOutstanding(tax.overview.outstanding);
  const owedNumber = Number(owed);

  return (
    <section className="dashboard-section">
      <div className="dashboard-section-header">
        <h2 className="dashboard-section-title">Ringkasan Pajak</h2>
        <Link className="dashboard-section-link" href="/tax">
          Buka Pajak
        </Link>
      </div>

      <div className="flow-card-head">
        <div>
          <p className="flow-card-figure">{formatMoney(owed, currency)}</p>
          <p className="flow-card-sub">Total terutang</p>
        </div>
        {tax.overview.needs_review_count > 0 ? (
          <Link className="delta-chip" data-tone="bad" href="/tax/ledger?status=needs_review">
            {tax.overview.needs_review_count} perlu ditinjau
          </Link>
        ) : null}
      </div>

      {outstandingEntries.length > 0 ? (
        <ul className="tax-owed">
          {outstandingEntries.map(([taxType, amount]) => {
            const share = owedNumber > 0 ? Math.max((Number(amount) / owedNumber) * 100, 2) : 2;
            return (
              <li key={taxType}>
                <div className="share-bar-top">
                  <span className="share-bar-name">
                    {TAX_TYPE_LABELS[taxType as keyof typeof TAX_TYPE_LABELS] ?? taxType}
                  </span>
                  <span className="share-bar-value">{formatMoney(amount, currency)}</span>
                </div>
                <div className="share-bar-track">
                  <span
                    className="share-bar-fill"
                    data-tone={taxType === "vat" ? "info" : undefined}
                    style={{ width: `${share}%` }}
                  />
                </div>
              </li>
            );
          })}
        </ul>
      ) : (
        <p className="dashboard-empty">Tidak ada kewajiban terutang.</p>
      )}

      {tax.deadlines.length > 0 ? (
        <>
          <div className="dashboard-section-header dashboard-subsection">
            <h3 className="dashboard-section-title">Tenggat terdekat</h3>
            <Link className="dashboard-section-link" href="/tax/calendar">
              Kalender
            </Link>
          </div>
          <ul className="tax-deadlines">
            {tax.deadlines.map((row) => {
              const due = row.due_date ? new Date(`${row.due_date}T00:00:00Z`) : null;
              return (
                <li key={`${row.tax_type}-${row.tax_period}-${row.step}`} className="tax-deadline">
                  <span className="tax-deadline-date" data-state={row.state}>
                    <strong>{due ? DAY_FORMAT.format(due) : "-"}</strong>
                    <span>{due ? MONTH_FORMAT.format(due) : ""}</span>
                  </span>
                  <span>
                    <p className="tax-deadline-title">
                      {TAX_TYPE_LABELS[row.tax_type]} · {CALENDAR_STEP_LABELS[row.step]}
                    </p>
                    <p className="tax-deadline-sub">{CALENDAR_STATE_LABELS[row.state]}</p>
                  </span>
                  {row.outstanding !== null ? (
                    <span className="tax-deadline-amount">
                      {formatMoney(row.outstanding, currency)}
                    </span>
                  ) : null}
                </li>
              );
            })}
          </ul>
        </>
      ) : null}
    </section>
  );
}
