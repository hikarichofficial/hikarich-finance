import type { DashboardSnapshot } from "@/services/dashboard/dashboard";
import { HeroSummary } from "./HeroSummary";
import { KpiStrip } from "./KpiStrip";
import { CashflowTrend } from "./CashflowTrend";
import { FlowCard } from "./FlowCard";
import { ReceivablesPayables } from "./ReceivablesPayables";
import { TaxSnapshot } from "./TaxSnapshot";
import { TasksAttention } from "./TasksAttention";
import { AccountSnapshot } from "./AccountSnapshot";
import { RecentActivity } from "./RecentActivity";

/**
 * Dashboard / Overview screen composition (Step 09 §8, Step 10 §10): Hero + KPI Row up top, then a
 * two-column layout with the financial narrative (Trend, AR/AP, Recent Activity) on the left and what
 * needs a decision (Attention, Tax, Account freshness) on the right -- "the first viewport should answer:
 * how are finances doing, what changed, what needs attention, where is the money" (Step 10 §10 rule), not
 * maximize the number of widgets.
 */
export function DashboardScreen({
  snapshot,
  displayName,
  entityName,
  monthHref,
}: {
  snapshot: DashboardSnapshot;
  displayName: string | null;
  entityName: string;
  monthHref: { prev: string; next: string };
}) {
  return (
    <div className="dashboard">
      <HeroSummary
        displayName={displayName}
        entityName={entityName}
        month={snapshot.period.month}
        monthHref={monthHref}
        currency={snapshot.currency}
        netResult={snapshot.finance?.netResult ?? null}
      />

      <KpiStrip
        currency={snapshot.currency}
        period={snapshot.period}
        finance={snapshot.finance}
        cash={snapshot.cash}
        receivables={snapshot.receivables}
        payables={snapshot.payables}
      />

      <div className="dashboard-grid">
        <div className="dashboard-column">
          <CashflowTrend
            trend={snapshot.trend}
            currency={snapshot.currency}
            selectedMonth={snapshot.period.month}
          />
          {snapshot.finance ? (
            <div className="dashboard-charts-row">
              <FlowCard
                side="revenue"
                flow={snapshot.finance.flow}
                breakdown={snapshot.finance.revenueBreakdown}
                currency={snapshot.currency}
                selectedMonth={snapshot.period.month}
              />
              <FlowCard
                side="expense"
                flow={snapshot.finance.flow}
                breakdown={snapshot.finance.expenseBreakdown}
                currency={snapshot.currency}
                selectedMonth={snapshot.period.month}
              />
            </div>
          ) : null}
          <ReceivablesPayables
            currency={snapshot.currency}
            receivables={snapshot.receivables}
            payables={snapshot.payables}
          />
          <RecentActivity items={snapshot.recentActivity} />
        </div>
        <div className="dashboard-column">
          <TasksAttention items={snapshot.attention} />
          <TaxSnapshot currency={snapshot.currency} tax={snapshot.tax} />
          <AccountSnapshot cash={snapshot.cash} reconciliation={snapshot.reconciliation} />
        </div>
      </div>
    </div>
  );
}
