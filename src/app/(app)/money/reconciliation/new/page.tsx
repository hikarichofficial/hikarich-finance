import { notFound } from "next/navigation";
import { requirePermission } from "@/services/identity/access";
import { getMoneyControl, getReconciliationStatus } from "@/services/money/money";
import { newSessionDefaults } from "@/domain/money/reconciliationSession";
import { NewSessionForm } from "@/features/money/ReconciliationForms";
import { todayInBusinessZone } from "@/lib/time";
import { BackLink } from "@/features/shell/BackLink";

/** Start a reconciliation session for one account (decision 251). Gated `money.reconcile`, the permission
 * `create_reconciliation_session` checks. The period and opening balance default to continuing from the
 * account's last reconciled statement, which the database requires. */
export default async function NewReconciliationPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; account?: string }>;
}) {
  const { entity, account } = await searchParams;
  const { membership } = await requirePermission("money.reconcile", { entityCode: entity });
  const [control, status] = await Promise.all([
    getMoneyControl(membership.entity_id),
    getReconciliationStatus(membership.entity_id),
  ]);
  const target = control.find((a) => a.financial_account_id === account);
  if (!target) notFound();
  const accountStatus = status.find((s) => s.financial_account_id === account) ?? null;
  const backHref = entity
    ? `/money/reconciliation?entity=${encodeURIComponent(entity)}`
    : "/money/reconciliation";

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <BackLink href={backHref}>← Kembali ke rekonsiliasi</BackLink>
      </p>
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Kas &amp; Bank · Rekonsiliasi</p>
          <h1>Rekonsiliasi baru</h1>
        </div>
      </header>
      <section className="dashboard-section">
        <NewSessionForm
          entity={entity}
          accountId={target.financial_account_id}
          accountName={target.name}
          currency={target.currency}
          defaults={newSessionDefaults(accountStatus, todayInBusinessZone())}
        />
      </section>
    </div>
  );
}
