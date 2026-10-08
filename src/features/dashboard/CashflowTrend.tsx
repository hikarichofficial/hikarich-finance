import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import { formatPercent, percentChange } from "@/domain/dashboard/chart";
import { LineChart, type ChartPoint } from "@/features/charts/InteractiveCharts";
import { formatMonthLabel, formatMonthShort, reportHref } from "./format";
import type { DashboardTrendPoint } from "@/services/dashboard/dashboard";

/**
 * Tren Arus Kas: closing cash by month as a line chart. Hover a point for the exact balance, click it to open
 * the Arus Kas report of that month. The big figure above is the latest month; the chip is its change from the
 * month before. Every figure shown is the database's own decimal text; the chart only positions it.
 */
export function CashflowTrend({
  trend,
  currency,
  selectedMonth,
}: {
  trend: DashboardTrendPoint[] | null;
  currency: string;
  selectedMonth: string;
}) {
  if (!trend || trend.length === 0) {
    return (
      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Tren Arus Kas</h2>
        </div>
        <p className="dashboard-empty">Belum ada data arus kas untuk ditampilkan.</p>
      </section>
    );
  }

  const points: ChartPoint[] = trend.map((t, i) => {
    const change = i > 0 ? percentChange(trend[i - 1].closingCash, t.closingCash) : null;
    return {
      key: t.month,
      short: formatMonthShort(t.month),
      label: `Saldo kas akhir ${formatMonthLabel(t.month)}`,
      value: t.closingCash === null ? null : Number(t.closingCash),
      display: t.closingCash === null ? "-" : formatMoney(t.closingCash, currency),
      note: change === null ? undefined : `${formatPercent(change)} dari bulan sebelumnya`,
      href: reportHref("cashflow", t.month),
      active: t.month === selectedMonth,
    };
  });

  const latest = trend[trend.length - 1];
  const change =
    trend.length > 1
      ? percentChange(trend[trend.length - 2].closingCash, latest.closingCash)
      : null;

  return (
    <section className="dashboard-section">
      <div className="dashboard-section-header">
        <h2 className="dashboard-section-title">Tren Arus Kas</h2>
        <Link className="dashboard-section-link" href="/reports?statement=cashflow">
          Lihat laporan
        </Link>
      </div>
      <div className="flow-card-head">
        <div>
          <p className="flow-card-figure">
            {latest.closingCash !== null ? formatMoney(latest.closingCash, currency) : "-"}
          </p>
          <p className="flow-card-sub">Saldo kas akhir {formatMonthLabel(latest.month)}</p>
        </div>
        {change !== null ? (
          <span className="delta-chip" data-tone={change >= 0 ? "good" : "bad"}>
            {formatPercent(change)} vs bulan lalu
          </span>
        ) : null}
      </div>
      <LineChart points={points} ariaLabel="Saldo kas akhir per bulan" />
    </section>
  );
}
