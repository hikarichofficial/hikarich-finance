import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import { Decimal } from "@/domain/money/decimal";
import type {
  DashboardCashSection,
  DashboardFinanceSection,
  DashboardPayablesSection,
  DashboardReceivablesSection,
} from "@/services/dashboard/dashboard";

interface KpiCardProps {
  label: string;
  value: string;
  context?: string;
  href?: string;
}

function KpiCard({ label, value, context, href }: KpiCardProps) {
  const body = (
    <>
      <p className="kpi-card-label">{label}</p>
      <p className="kpi-card-value">{value}</p>
      {context ? <p className="kpi-card-context">{context}</p> : null}
    </>
  );
  if (href) {
    return (
      <Link className="kpi-card" href={href}>
        {body}
      </Link>
    );
  }
  return <div className="kpi-card">{body}</div>;
}

/**
 * Primary KPI Strip (Step 09 §8, Step 10 §10-11): Cash, Revenue/Income, Expense, Profit/Surplus,
 * Receivables, Payables -- contextual by Entity, meaning only the cards whose section the caller may see
 * are shown at all (an omitted card, never a locked/greyed one). No decorative trend arrows are added
 * (Step 10 §11) since Part 2 has no prior-period comparison figure to make one economically meaningful.
 */
export function KpiStrip({
  currency,
  finance,
  cash,
  receivables,
  payables,
}: {
  currency: string;
  finance: DashboardFinanceSection | null;
  cash: DashboardCashSection | null;
  receivables: DashboardReceivablesSection | null;
  payables: DashboardPayablesSection | null;
}) {
  const cards: KpiCardProps[] = [];

  if (cash) {
    cards.push({
      label: "Kas & Bank",
      value: formatMoney(cash.balance, currency),
      context: `${cash.accounts.filter((a) => a.is_active).length} akun aktif`,
      href: "/money/accounts",
    });
  }

  if (finance) {
    cards.push({
      label: "Pendapatan",
      value: formatMoney(finance.revenue, currency),
      href: "/reports",
    });
    cards.push({ label: "Beban", value: formatMoney(finance.expense, currency), href: "/reports" });
    if (finance.netResult !== null) {
      cards.push({
        label: finance.netResult.startsWith("-") ? "Rugi Berjalan" : "Laba Berjalan",
        value: formatMoney(finance.netResult, currency),
        href: "/reports",
      });
    }
  }

  if (receivables) {
    cards.push({
      label: "Piutang Usaha",
      value: formatMoney(receivables.total, currency),
      context: Decimal.parse(receivables.overdue).isZero()
        ? "Tidak ada yang jatuh tempo"
        : `${formatMoney(receivables.overdue, currency)} jatuh tempo`,
      href: "/sales/invoices",
    });
  }

  if (payables) {
    cards.push({
      label: "Utang Usaha",
      value: formatMoney(payables.total, currency),
      context: Decimal.parse(payables.overdue).isZero()
        ? "Tidak ada yang jatuh tempo"
        : `${formatMoney(payables.overdue, currency)} jatuh tempo`,
      href: "/purchases/bills",
    });
  }

  if (cards.length === 0) return null;

  return (
    <div className="kpi-strip">
      {cards.map((card) => (
        <KpiCard key={card.label} {...card} />
      ))}
    </div>
  );
}
