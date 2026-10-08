import Link from "next/link";
import { Decimal } from "@/domain/money/decimal";
import { formatMoney } from "@/domain/money/format";
import {
  CALENDAR_STATE_LABELS,
  CALENDAR_STEP_LABELS,
  TAX_TYPE_LABELS,
  incomeRegimeLabel,
  monthNameId,
  taxpayerKindLabel,
  vatStatusLabel,
  yesNoUnknownLabel,
} from "@/domain/tax/tax";
import { incomeTaxByMonth, totalOutstanding } from "@/domain/tax/taxOverview";
import { BarChart, type ChartPoint } from "@/features/charts/InteractiveCharts";
import type { FinalPreview, NonFinalIncome, TaxLedgerRow, TaxOverview } from "@/schemas/tax";
import { TaxNonFinalCard } from "./TaxNonFinalCard";
import { formatShortDate } from "./format";

const DAY_FORMAT = new Intl.DateTimeFormat("id-ID", { day: "numeric", timeZone: "UTC" });
const MONTH_FORMAT = new Intl.DateTimeFormat("id-ID", { month: "short", timeZone: "UTC" });

/**
 * Ringkasan Pajak, the Tax group's landing screen: four figures first (what is owed, this month's PPh Final
 * estimate, the yearly estimate on income outside the final tax, what still needs review), then the income tax
 * recorded per month as bars (hover for the amount, click to open that month in the Buku Besar Pajak), what is
 * owed by type, and the nearest deadlines. Explanations are folded away; the figures are the page.
 */
export function TaxOverviewScreen({
  overview,
  currency,
  entity,
  estimate,
  estimatePeriod,
  nonFinal,
  currentYear,
  shownYear,
  ledger,
}: {
  overview: TaxOverview;
  currency: string;
  entity: string | undefined;
  estimate: FinalPreview;
  estimatePeriod: string;
  nonFinal: NonFinalIncome;
  currentYear: number;
  shownYear: number;
  ledger: TaxLedgerRow[];
}) {
  const entityParam = entity ? `entity=${encodeURIComponent(entity)}` : "";
  const qs = entityParam ? `?${entityParam}` : "";
  const withEntity = (path: string, params: Record<string, string> = {}) => {
    const query = new URLSearchParams(params);
    if (entity) query.set("entity", entity);
    const text = query.toString();
    return text ? `${path}?${text}` : path;
  };

  const outstandingEntries = Object.entries(overview.outstanding).filter(
    ([, amount]) => !Decimal.parse(amount).isZero(),
  );
  const owedTotal = totalOutstanding(overview.outstanding);
  const owedNumber = Number(owedTotal);
  const perMonth = incomeTaxByMonth(ledger, shownYear);
  const yearTotal = perMonth.reduce((sum, v) => sum.add(Decimal.parse(v)), Decimal.zero());

  const points: ChartPoint[] = perMonth.map((value, i) => {
    const month = i + 1;
    const period = `${shownYear}-${String(month).padStart(2, "0")}-01`;
    return {
      key: period,
      short: monthNameId(month).slice(0, 3),
      label: `PPh ${monthNameId(month)} ${shownYear}`,
      value: Number(value),
      display: formatMoney(value, currency),
      href: withEntity("/tax/ledger", { period }),
      active: shownYear === currentYear && period.slice(0, 7) === estimatePeriod.slice(0, 7),
    };
  });

  const finalAuto = estimate.status === "auto_determined";
  const nonFinalRate = nonFinal.rate === null ? null : Math.round(Number(nonFinal.rate) * 100);

  const profile = overview.profile;

  return (
    <div className="tax-page">
      <header className="tax-hero">
        <div>
          <p className="record-detail-eyebrow">Pajak</p>
          <h1>Ringkasan Pajak</h1>
          <p className="record-detail-dates">
            Per {formatShortDate(overview.as_of)}
            {overview.engine_active_from
              ? ` · mesin pajak aktif sejak ${formatShortDate(overview.engine_active_from)}`
              : " · mesin pajak belum diaktifkan"}
          </p>
          {profile ? (
            <div className="tax-chips">
              <span className="tax-chip">
                <span>Wajib pajak</span>
                <strong>{taxpayerKindLabel(profile.taxpayer_kind)}</strong>
              </span>
              <span className="tax-chip">
                <span>Rezim</span>
                <strong>{incomeRegimeLabel(profile.income_regime)}</strong>
              </span>
              <span className="tax-chip">
                <span>PPN</span>
                <strong>{vatStatusLabel(profile.vat_status)}</strong>
              </span>
              <span className="tax-chip">
                <span>Pemotong pajak</span>
                <strong>{yesNoUnknownLabel(profile.withholding_agent)}</strong>
              </span>
            </div>
          ) : (
            <div className="tax-chips">
              <Link className="tax-chip" href={`/tax/setup${qs}`}>
                <strong>Isi profil pajak Entity →</strong>
              </Link>
            </div>
          )}
        </div>
        <div className="tax-chips">
          <Link className="tax-chip" href={`/tax/ledger${qs}`}>
            <strong>Buku Besar Pajak</strong>
          </Link>
          <Link className="tax-chip" href={`/tax/calendar${qs}`}>
            <strong>Kalender</strong>
          </Link>
        </div>
      </header>

      <div className="tax-kpis">
        <Link
          className="tax-kpi"
          data-tone={owedNumber > 0 ? "danger" : "success"}
          href={`/tax/ledger${qs}`}
        >
          <p className="tax-kpi-label">Total terutang</p>
          <p className="tax-kpi-value">{formatMoney(owedTotal, currency)}</p>
          <p className="tax-kpi-note">
            {outstandingEntries.length === 0
              ? "Tidak ada kewajiban"
              : `${outstandingEntries.length} jenis pajak belum dibayar`}
          </p>
        </Link>

        {finalAuto ? (
          <Link className="tax-kpi" data-tone="info" href={`/tax/pph${qs}`}>
            <p className="tax-kpi-label">PPh Final bulan ini (perkiraan)</p>
            <p className="tax-kpi-value">{formatMoney(estimate.tax, currency)}</p>
            <p className="tax-kpi-note">
              {estimate.turnover_month !== undefined
                ? `Penjualan ${formatMoney(estimate.turnover_month, currency)}`
                : "Dari invoice terbit bulan ini"}
            </p>
          </Link>
        ) : null}

        <div className="tax-kpi">
          <p className="tax-kpi-label">Perkiraan PPh {nonFinal.year}</p>
          <p className="tax-kpi-value">
            {nonFinal.estimated_tax !== null ? formatMoney(nonFinal.estimated_tax, currency) : "-"}
          </p>
          <p className="tax-kpi-note">
            {nonFinalRate !== null
              ? `${nonFinalRate}% × hasil bersih ${formatMoney(nonFinal.total, currency)}`
              : "Isi jenis wajib pajak untuk melihat perkiraan"}
          </p>
        </div>

        <Link
          className="tax-kpi"
          data-tone={overview.needs_review_count > 0 ? "warning" : "success"}
          href={withEntity("/tax/ledger", { status: "needs_review" })}
        >
          <p className="tax-kpi-label">Perlu ditinjau</p>
          <p className="tax-kpi-value">{overview.needs_review_count}</p>
          <p className="tax-kpi-note">
            {overview.needs_review_count > 0
              ? "Transaksi menunggu penentuan pajak"
              : "Semua transaksi sudah ditentukan"}
          </p>
        </Link>
      </div>

      <div className="tax-grid">
        <div className="dashboard-column">
          <section className="dashboard-section">
            <div className="dashboard-section-header">
              <h2 className="dashboard-section-title">PPh per bulan · {shownYear}</h2>
              <span className="delta-chip">
                Total {formatMoney(yearTotal.toString(), currency)}
              </span>
            </div>
            <BarChart points={points} tone="accent" ariaLabel={`PPh per bulan ${shownYear}`} />
            <p className="hint">
              <Link href={withEntity("/tax", { year: String(shownYear - 1) })}>
                ← {shownYear - 1}
              </Link>
              {shownYear < currentYear ? (
                <>
                  {" · "}
                  <Link href={withEntity("/tax", { year: String(shownYear + 1) })}>
                    {shownYear + 1} →
                  </Link>
                </>
              ) : null}
            </p>
          </section>

          <TaxNonFinalCard data={nonFinal} currentYear={currentYear} entity={entity} />
        </div>

        <div className="dashboard-column">
          <section className="dashboard-section">
            <div className="dashboard-section-header">
              <h2 className="dashboard-section-title">Terutang per jenis</h2>
            </div>
            {outstandingEntries.length === 0 ? (
              <p className="dashboard-empty">Tidak ada kewajiban terutang.</p>
            ) : (
              <ul className="tax-owed">
                {outstandingEntries.map(([taxType, amount]) => {
                  const share =
                    owedNumber > 0 ? Math.max((Number(amount) / owedNumber) * 100, 2) : 2;
                  return (
                    <li key={taxType}>
                      <Link
                        className="share-bar-top"
                        href={withEntity("/tax/ledger", { type: taxType })}
                      >
                        <span className="share-bar-name">
                          {TAX_TYPE_LABELS[taxType as keyof typeof TAX_TYPE_LABELS] ?? taxType}
                        </span>
                        <span className="share-bar-value">{formatMoney(amount, currency)}</span>
                      </Link>
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
            )}
          </section>

          <section className="dashboard-section">
            <div className="dashboard-section-header">
              <h2 className="dashboard-section-title">Tenggat terdekat</h2>
              <Link className="dashboard-section-link" href={`/tax/calendar${qs}`}>
                Kalender
              </Link>
            </div>
            {overview.attention.length === 0 ? (
              <p className="dashboard-empty">Tidak ada tenggat yang mendesak.</p>
            ) : (
              <ul className="tax-deadlines">
                {overview.attention.map((row) => {
                  const due = row.due_date ? new Date(`${row.due_date}T00:00:00Z`) : null;
                  return (
                    <li key={`${row.tax_type}-${row.tax_period}-${row.step}`}>
                      <Link
                        className="tax-deadline"
                        href={withEntity("/tax/ledger", {
                          type: row.tax_type,
                          period: row.tax_period,
                        })}
                      >
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
                      </Link>
                    </li>
                  );
                })}
              </ul>
            )}
          </section>
        </div>
      </div>
    </div>
  );
}
