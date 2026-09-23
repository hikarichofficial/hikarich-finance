import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import { formatMonthLabel } from "./format";
import type { DashboardTrendPoint } from "@/services/dashboard/dashboard";

/**
 * Cashflow / Trend (Step 09 §8, Step 10 §10 & §12): one restrained line/area chart of closing cash by
 * month, bronze-on-neutral, with an exact per-point tooltip and a numeric legend underneath so the chart
 * is never the only source of the exact figures (Step 10 §12: "always have a table/drill-down source").
 *
 * The chart only ever positions pixels -- `Number(...)` here never feeds a financial computation, every
 * value shown to the person is still the original exact decimal text from `closingCashFromCashFlowRows`.
 */

const WIDTH = 600;
const HEIGHT = 160;
const PADDING = 10;

export function CashflowTrend({
  trend,
  currency,
}: {
  trend: DashboardTrendPoint[] | null;
  currency: string;
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

  const numeric = trend.map((t) => (t.closingCash === null ? null : Number(t.closingCash)));
  const known = numeric.filter((v): v is number => v !== null);
  const min = known.length ? Math.min(...known, 0) : 0;
  const max = known.length ? Math.max(...known, 0) : 0;
  const range = max - min || 1;
  const step = trend.length > 1 ? (WIDTH - PADDING * 2) / (trend.length - 1) : 0;

  const points = trend.map((point, i) => {
    const value = numeric[i];
    return {
      month: point.month,
      raw: point.closingCash,
      x: PADDING + step * i,
      y:
        value === null ? null : HEIGHT - PADDING - ((value - min) / range) * (HEIGHT - PADDING * 2),
    };
  });

  const plotted = points.filter((p) => p.y !== null) as Array<
    (typeof points)[number] & { y: number }
  >;
  const linePath = plotted.map((p, i) => `${i === 0 ? "M" : "L"} ${p.x} ${p.y}`).join(" ");
  const areaPath =
    plotted.length > 0
      ? `${linePath} L ${plotted[plotted.length - 1].x} ${HEIGHT - PADDING} L ${plotted[0].x} ${HEIGHT - PADDING} Z`
      : "";

  const latest = trend[trend.length - 1];

  return (
    <section className="dashboard-section">
      <div className="dashboard-section-header">
        <h2 className="dashboard-section-title">Tren Arus Kas</h2>
        <Link className="dashboard-section-link" href="/reports/cashflow">
          Lihat laporan
        </Link>
      </div>
      <svg
        className="trend-chart"
        viewBox={`0 0 ${WIDTH} ${HEIGHT}`}
        preserveAspectRatio="none"
        role="img"
        aria-label="Grafik saldo kas akhir per bulan"
      >
        <line
          className="trend-chart-axis"
          x1={PADDING}
          y1={HEIGHT - PADDING}
          x2={WIDTH - PADDING}
          y2={HEIGHT - PADDING}
        />
        {areaPath ? <path className="trend-chart-area" d={areaPath} /> : null}
        {linePath ? <path className="trend-chart-line" d={linePath} /> : null}
        {plotted.map((p) => (
          <circle key={p.month} className="trend-chart-dot" cx={p.x} cy={p.y} r={3}>
            <title>
              {formatMonthLabel(p.month)}: {p.raw !== null ? formatMoney(p.raw, currency) : "-"}
            </title>
          </circle>
        ))}
      </svg>
      <div className="trend-legend">
        <span>{formatMonthLabel(trend[0].month)}</span>
        <span>
          Saldo kas akhir {formatMonthLabel(latest.month)}:{" "}
          <strong>
            {latest.closingCash !== null ? formatMoney(latest.closingCash, currency) : "-"}
          </strong>
        </span>
      </div>
    </section>
  );
}
