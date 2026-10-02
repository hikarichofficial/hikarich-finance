import { requirePermission } from "@/services/identity/access";
import { formatMoney } from "@/domain/money/format";
import { activeCashBalance } from "@/domain/dashboard/dashboard";
import { getEntityBaseCurrency } from "@/services/reports/reports";
import { getMoneyControl, getReconciliationStatus } from "@/services/money/money";
import { AccountSnapshot } from "@/features/dashboard/AccountSnapshot";

/** Saldo Kas & Bank (Step 09 §3 Overview "Cash & Bank Snapshot", decision 255): a read-only snapshot of
 * every active cash/bank balance and its reconciliation freshness -- the Dashboard's own Account Snapshot
 * section on its own page, so the Ringkasan menu has its own destination instead of jumping into Kas &
 * Bank > Rekening (where accounts are managed). Same `money.view` gate and the same two RPCs. */
export default async function CashSnapshotPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  const { membership } = await requirePermission("money.view", { entityCode: entity });
  const [accounts, reconciliation, currency] = await Promise.all([
    getMoneyControl(membership.entity_id),
    getReconciliationStatus(membership.entity_id),
    getEntityBaseCurrency(membership.entity_id),
  ]);
  const balance = activeCashBalance(accounts).toString();

  return (
    <div className="record-detail">
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Ringkasan</p>
          <h1>Saldo Kas &amp; Bank</h1>
        </div>
      </header>
      <section className="dashboard-section">
        <dl className="record-summary-grid">
          <div>
            <dt>Total saldo aktif (mata uang dasar)</dt>
            <dd>{formatMoney(balance, currency)}</dd>
          </div>
          <div>
            <dt>Rekening aktif</dt>
            <dd>{accounts.filter((a) => a.is_active).length}</dd>
          </div>
        </dl>
      </section>
      <AccountSnapshot cash={{ balance, accounts }} reconciliation={reconciliation} />
    </div>
  );
}
