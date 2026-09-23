import Link from "next/link";
import { Decimal } from "@/domain/money/decimal";
import { formatMoney } from "@/domain/money/format";
import {
  CALENDAR_STATE_LABELS,
  CALENDAR_STEP_LABELS,
  TAX_TYPE_LABELS,
  incomeRegimeLabel,
  taxResidencyLabel,
  taxpayerKindLabel,
  vatStatusLabel,
  yesNoUnknownLabel,
} from "@/domain/tax/tax";
import type { TaxOverview } from "@/schemas/tax";
import { formatShortDate } from "./format";

const STATE_BADGE_TONE: Readonly<Record<string, string>> = {
  overdue: "status-badge-critical",
  due: "status-badge-attention",
  upcoming: "status-badge-progress",
  done: "status-badge-success",
};

/**
 * Tax Overview (P13 Part 3e, Step 09 §15): the Tax nav group's own landing screen -- `tax_overview`'s outstanding
 * balances by tax type, the Entity's own recorded tax facts (its "profile"), how many documents still need a
 * tax review, and the calendar steps due or overdue in the last two months. This is the same data the
 * Dashboard's Tax Snapshot card teases (a curated top-5), shown here in full and as its own page, reached from
 * the Tax nav group rather than only glimpsed from the Dashboard.
 */
export function TaxOverviewScreen({
  overview,
  currency,
  entity,
}: {
  overview: TaxOverview;
  currency: string;
  entity: string | undefined;
}) {
  const qs = entity ? `?entity=${encodeURIComponent(entity)}` : "";
  const outstandingEntries = Object.entries(overview.outstanding).filter(
    ([, amount]) => !Decimal.parse(amount).isZero(),
  );

  return (
    <div className="record-detail">
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Pajak</p>
          <h1>Ringkasan Pajak</h1>
          <p className="record-detail-counterparty">
            {overview.engine_active_from
              ? `Mesin pajak aktif sejak ${formatShortDate(overview.engine_active_from)}.`
              : "Mesin pajak belum diaktifkan untuk Entity ini."}
          </p>
        </div>
        <div className="record-detail-header-end">
          <p className="record-detail-dates">Per {formatShortDate(overview.as_of)}</p>
        </div>
      </header>

      <p className="hint">
        <Link href={`/tax/ledger${qs}`}>Buka Buku Besar Pajak →</Link>
      </p>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Kewajiban Terutang</h2>
        </div>
        {outstandingEntries.length === 0 ? (
          <p className="dashboard-empty">Tidak ada kewajiban pajak terutang.</p>
        ) : (
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
        )}
        {overview.needs_review_count > 0 ? (
          <p className="dashboard-list-item-detail dashboard-note">
            {overview.needs_review_count} transaksi perlu ditinjau untuk penentuan pajak.
          </p>
        ) : null}
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Profil Pajak Entity</h2>
        </div>
        {overview.profile ? (
          <dl className="record-summary-grid">
            <div>
              <dt>Berlaku Sejak</dt>
              <dd>{formatShortDate(overview.profile.effective_from)}</dd>
            </div>
            <div>
              <dt>Jenis Wajib Pajak</dt>
              <dd>{taxpayerKindLabel(overview.profile.taxpayer_kind)}</dd>
            </div>
            <div>
              <dt>Domisili</dt>
              <dd>{taxResidencyLabel(overview.profile.residency)}</dd>
            </div>
            <div>
              <dt>Rezim Pajak Penghasilan</dt>
              <dd>{incomeRegimeLabel(overview.profile.income_regime)}</dd>
            </div>
            <div>
              <dt>Status PPN</dt>
              <dd>{vatStatusLabel(overview.profile.vat_status)}</dd>
            </div>
            <div>
              <dt>Pemotong Pajak</dt>
              <dd>{yesNoUnknownLabel(overview.profile.withholding_agent)}</dd>
            </div>
          </dl>
        ) : (
          <p className="dashboard-empty">Profil pajak Entity belum diisi.</p>
        )}
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Tenggat Terdekat</h2>
        </div>
        {overview.attention.length === 0 ? (
          <p className="dashboard-empty">Tidak ada tenggat yang jatuh tempo atau terlambat.</p>
        ) : (
          <ul className="dashboard-list">
            {overview.attention.map((row) => (
              <li
                key={`${row.tax_type}-${row.tax_period}-${row.step}`}
                className="dashboard-list-item"
              >
                <div>
                  <p className="dashboard-list-item-title">
                    <Link
                      href={`/tax/ledger?type=${row.tax_type}&period=${row.tax_period}${entity ? `&entity=${encodeURIComponent(entity)}` : ""}`}
                    >
                      {TAX_TYPE_LABELS[row.tax_type]} · {CALENDAR_STEP_LABELS[row.step]}
                    </Link>
                  </p>
                  <p className="dashboard-list-item-detail">
                    <span
                      className={`status-badge ${STATE_BADGE_TONE[row.state] ?? "status-badge-neutral"}`}
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
        )}
      </section>
    </div>
  );
}
