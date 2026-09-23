import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import { formatMonthLabel } from "./format";

/**
 * Hero Finance Summary (Step 09 §8, Step 10 §10): Entity + greeting/context + period, and one dominant
 * metric (Profit/Surplus for the selected period) with restrained supporting context -- not a second KPI
 * strip. `netResult` is `null` when the caller cannot see `reports.view` (the whole `finance` section is
 * withheld) or when the statement legitimately returned no synthetic net-result row.
 */
export function HeroSummary({
  displayName,
  entityName,
  month,
  monthHref,
  currency,
  netResult,
}: {
  displayName: string | null;
  entityName: string;
  month: string;
  monthHref: { prev: string; next: string };
  currency: string;
  netResult: string | null;
}) {
  const tone = netResult === null ? undefined : netResult.startsWith("-") ? "negative" : "positive";
  return (
    <div className="dashboard-hero">
      <div>
        <h1 className="dashboard-hero-title">Selamat datang, {displayName ?? "Pengguna"}</h1>
        <p className="dashboard-hero-subtitle">
          Ringkasan keuangan <strong>{entityName}</strong> untuk{" "}
          <span className="period-nav">
            <Link href={monthHref.prev} className="period-nav-link" aria-label="Bulan sebelumnya">
              ‹
            </Link>
            <span className="period-nav-label">{formatMonthLabel(month)}</span>
            <Link href={monthHref.next} className="period-nav-link" aria-label="Bulan berikutnya">
              ›
            </Link>
          </span>
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
