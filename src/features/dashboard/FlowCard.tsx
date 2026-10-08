import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import { formatPercent, percentChange, type BreakdownItem } from "@/domain/dashboard/chart";
import { BarChart, type ChartPoint } from "@/features/charts/InteractiveCharts";
import type { DashboardFlowPoint } from "@/services/dashboard/dashboard";
import { formatMonthLabel, formatMonthShort, reportHref } from "./format";

/**
 * Pendapatan / Beban card: the month shown as one big figure with its change from the month before, six
 * months of bars (hover for the exact amount, click to open that month's Laba Rugi), and the biggest
 * accounts of the month as share bars.
 */
export function FlowCard({
  side,
  flow,
  breakdown,
  currency,
  selectedMonth,
}: {
  side: "revenue" | "expense";
  flow: DashboardFlowPoint[];
  breakdown: BreakdownItem[];
  currency: string;
  selectedMonth: string;
}) {
  const isRevenue = side === "revenue";
  const title = isRevenue ? "Pendapatan" : "Beban";
  const section = isRevenue ? "pnl-revenue" : "pnl-expense";
  const valueOf = (p: DashboardFlowPoint) => (isRevenue ? p.revenue : p.expense);
  const tone = isRevenue ? "success" : "danger";

  const points: ChartPoint[] = flow.map((p, i) => {
    const change = i > 0 ? percentChange(valueOf(flow[i - 1]), valueOf(p)) : null;
    return {
      key: p.month,
      short: formatMonthShort(p.month),
      label: `${title} ${formatMonthLabel(p.month)}`,
      value: Number(valueOf(p)),
      display: formatMoney(valueOf(p), currency),
      note: change === null ? undefined : `${formatPercent(change)} dari bulan sebelumnya`,
      href: reportHref("pnl", p.month, section),
      active: p.month === selectedMonth,
    };
  });

  const current = flow[flow.length - 1];
  const change =
    flow.length > 1 ? percentChange(valueOf(flow[flow.length - 2]), valueOf(current)) : null;
  // More revenue is good news, more expense is not.
  const chipTone = change === null ? undefined : change >= 0 === isRevenue ? "good" : "bad";

  return (
    <section className="dashboard-section">
      <div className="dashboard-section-header">
        <h2 className="dashboard-section-title">{title}</h2>
        <Link className="dashboard-section-link" href={reportHref("pnl", selectedMonth, section)}>
          Lihat rincian
        </Link>
      </div>
      <div className="flow-card-head">
        <div>
          <p className="flow-card-figure">{formatMoney(valueOf(current), currency)}</p>
          <p className="flow-card-sub">{formatMonthLabel(current.month)}</p>
        </div>
        {change !== null ? (
          <span className="delta-chip" data-tone={chipTone}>
            {formatPercent(change)} vs bulan lalu
          </span>
        ) : null}
      </div>
      <BarChart points={points} tone={tone} ariaLabel={`${title} per bulan`} />
      {breakdown.length > 0 ? (
        <ul className="share-bars">
          {breakdown.map((item) => (
            <li key={item.name}>
              <div className="share-bar-top">
                <span className="share-bar-name">{item.name}</span>
                <span className="share-bar-value">{formatMoney(item.amount, currency)}</span>
              </div>
              <div className="share-bar-track">
                <span
                  className="share-bar-fill"
                  data-tone={tone}
                  style={{ width: `${Math.max(item.share, 2)}%` }}
                />
              </div>
            </li>
          ))}
        </ul>
      ) : (
        <p className="dashboard-empty">Belum ada {title.toLowerCase()} bulan ini.</p>
      )}
    </section>
  );
}
