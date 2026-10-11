import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import { formatMonthLabel } from "./format";
import { periodYear, type DashboardPeriod } from "@/domain/dashboard/dashboard";
import { PageHelp } from "@/features/shared/PageHelp";

/**
 * Hero Finance Summary (Step 09 §8, Step 10 §10): Entity + greeting/context + period, and one dominant
 * metric (Profit/Surplus for the selected period) with restrained supporting context -- not a second KPI
 * strip. `netResult` is `null` when the caller cannot see `reports.view` (the whole `finance` section is
 * withheld) or when the statement legitimately returned no synthetic net-result row.
 */
const SCOPE_LABELS = { month: "Bulanan", year: "Tahunan", all: "Sejak Awal" } as const;

export function HeroSummary({
  displayName,
  entityName,
  period,
  periodHref,
  scopeHref,
  currency,
  netResult,
}: {
  displayName: string | null;
  entityName: string;
  period: DashboardPeriod;
  periodHref: { prev: string; next: string } | null;
  scopeHref: { month: string; year: string; all: string };
  currency: string;
  netResult: string | null;
}) {
  const periodLabel =
    period.scope === "all"
      ? "seluruh pembukuan"
      : period.scope === "year"
        ? `Tahun ${periodYear(period)}`
        : formatMonthLabel(period.month);
  const tone = netResult === null ? undefined : netResult.startsWith("-") ? "negative" : "positive";
  return (
    <div className="dashboard-hero">
      <div>
        <h1 className="dashboard-hero-title">Selamat datang, {displayName ?? "Pengguna"}</h1>
        <PageHelp />
        <p className="dashboard-hero-subtitle">
          Ringkasan keuangan <strong>{entityName}</strong> untuk{" "}
          <span className="period-nav">
            {periodHref ? (
              <Link
                href={periodHref.prev}
                className="period-nav-link"
                aria-label="Periode sebelumnya"
              >
                ‹
              </Link>
            ) : null}
            <span className="period-nav-label">{periodLabel}</span>
            {periodHref ? (
              <Link
                href={periodHref.next}
                className="period-nav-link"
                aria-label="Periode berikutnya"
              >
                ›
              </Link>
            ) : null}
          </span>
        </p>
        {/* Bulanan / Tahunan / Sejak Awal (OWNER, 11 October 2026; decision 404). */}
        <p className="dashboard-scope">
          {(["month", "year", "all"] as const).map((option) => (
            <Link
              key={option}
              href={scopeHref[option]}
              className={
                period.scope === option
                  ? "list-filter-tab list-filter-tab-active"
                  : "list-filter-tab"
              }
            >
              {SCOPE_LABELS[option]}
            </Link>
          ))}
        </p>
      </div>
      {netResult !== null ? (
        <div className="dashboard-hero-net">
          <span className="dashboard-hero-net-label">
            {netResult.startsWith("-") ? "Rugi Periode Berjalan" : "Laba Periode Berjalan"}
          </span>
          <span className="dashboard-hero-net-value" data-tone={tone}>
            {formatMoney(netResult, currency)}
          </span>
        </div>
      ) : null}
    </div>
  );
}
