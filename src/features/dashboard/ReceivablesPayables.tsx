import Link from "next/link";
import { Decimal } from "@/domain/money/decimal";
import { formatMoney } from "@/domain/money/format";
import type {
  DashboardPayablesSection,
  DashboardReceivablesSection,
} from "@/services/dashboard/dashboard";

function overduePercent(total: string, overdue: string): number {
  const t = Decimal.parse(total);
  if (t.isZero()) return 0;
  const o = Decimal.parse(overdue);
  const pct = Number(o.toString()) / Number(t.toString());
  return Math.min(100, Math.max(0, pct * 100));
}

function AgingBlock({
  title,
  href,
  section,
  currency,
  customerCount,
}: {
  title: string;
  href: string;
  section: { total: string; overdue: string };
  currency: string;
  customerCount: number;
}) {
  const pct = overduePercent(section.total, section.overdue);
  return (
    <div>
      <div className="dashboard-section-header">
        <h3 className="dashboard-section-title">{title}</h3>
        <Link className="dashboard-section-link" href={href}>
          Lihat rincian
        </Link>
      </div>
      <div className="aging-summary">
        <span className="aging-summary-figure">{formatMoney(section.total, currency)}</span>
        <span className="dashboard-list-item-detail">{customerCount} pihak</span>
      </div>
      <div className="aging-bar">
        <span
          className="aging-bar-segment"
          data-bucket="not_due"
          style={{ width: `${100 - pct}%` }}
        />
        <span className="aging-bar-segment" data-bucket="overdue" style={{ width: `${pct}%` }} />
      </div>
      <p className="dashboard-list-item-detail">
        {Decimal.parse(section.overdue).isZero()
          ? "Tidak ada yang jatuh tempo"
          : `${formatMoney(section.overdue, currency)} jatuh tempo (${pct.toFixed(0)}%)`}
      </p>
    </div>
  );
}

/** Receivables & Payables (Step 09 §8) / AR-AP zone (Step 10 §10): one outstanding/overdue distribution
 * per side, each only rendered when its own permission (`invoices.view` / `bills.view`) let the service
 * fetch it. */
export function ReceivablesPayables({
  currency,
  receivables,
  payables,
}: {
  currency: string;
  receivables: DashboardReceivablesSection | null;
  payables: DashboardPayablesSection | null;
}) {
  if (!receivables && !payables) return null;
  return (
    <section className="dashboard-section">
      <div className="dashboard-column">
        {receivables ? (
          <AgingBlock
            title="Piutang Usaha"
            href="/sales/invoices"
            section={receivables}
            currency={currency}
            customerCount={receivables.aging.length}
          />
        ) : null}
        {payables ? (
          <AgingBlock
            title="Utang Usaha"
            href="/purchases/bills"
            section={payables}
            currency={currency}
            customerCount={payables.aging.length}
          />
        ) : null}
      </div>
    </section>
  );
}
