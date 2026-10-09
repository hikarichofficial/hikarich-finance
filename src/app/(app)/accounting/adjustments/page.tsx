import { requirePermission } from "@/services/identity/access";
import { getMoneyControl } from "@/services/money/money";
import { listLedgerAccounts } from "@/services/accounting/ledger";
import { BalanceAdjustmentForm } from "@/features/money/BalanceAdjustmentForm";
import { BackLink } from "@/features/shell/BackLink";

/** Advanced Adjustments (P13 unbuilt-screens backlog, Step 09 §14, Step 01 §28, decision 232). Gated
 * `money.adjust`, the exact permission `record_balance_adjustment` itself checks -- `navigation.ts` nests
 * this under the Accounting section (parent-gated `accounting.view`) but declares no item-level permission
 * of its own, so this page is gated by the RPC's own check rather than the section's, the same "match the
 * RPC, not merely the nav section" discipline `/sales/refunds` already documented as an observation when
 * the two disagree; here every role holding `money.adjust` also holds `accounting.view` and `money.view`
 * (`20260920100100_p2_permission_catalog.sql`'s `accountant` template), so this never actually locks anyone
 * out who could otherwise reach it from the nav. `record_balance_adjustment` posts immediately -- there is
 * no draft, list or detail of its own, so this page is the form itself, not a List+New split. */
export default async function BalanceAdjustmentPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  const { membership } = await requirePermission("money.adjust", { entityCode: entity });

  const [accounts, ledgerAccounts] = await Promise.all([
    getMoneyControl(membership.entity_id),
    listLedgerAccounts(membership.entity_id),
  ]);

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <BackLink
          href={entity ? `/money/accounts?entity=${encodeURIComponent(entity)}` : "/money/accounts"}
        >
          ← Kembali ke daftar akun
        </BackLink>
      </p>
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Penyesuaian Saldo</p>
          <h1>Penyesuaian Lanjutan</h1>
        </div>
      </header>
      <section className="dashboard-section">
        <BalanceAdjustmentForm
          accounts={accounts}
          ledgerAccounts={ledgerAccounts}
          entityId={membership.entity_id}
          entity={entity}
        />
      </section>
    </div>
  );
}
