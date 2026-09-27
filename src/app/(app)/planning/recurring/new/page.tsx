import Link from "next/link";
import { requirePermission } from "@/services/identity/access";
import { listActiveCategories } from "@/services/accounting/categories";
import {
  listActiveContacts,
  listActiveFinancialAccounts,
  listActivePaymentChannels,
} from "@/services/planning/planning";
import { RecurringRuleForm } from "@/features/planning/RecurringRuleForm";

/** Recurring Rule create form (P13 Part 3h, sixth increment, Step 09 §13, §18). Gated on
 * `planning.recurring_edit`, the exact permission `create_recurring_rule` itself checks -- the same
 * "gate the page on the create RPC's own permission" shape `NewTransferPage`/`NewBudgetPage` already
 * established. `kind` is chosen in the form itself (client-side, no page reload), so every picker every
 * kind might need is fetched here up front rather than lazily -- a handful of small, RLS-scoped reads, the
 * same "no RPC exists, direct table read" shape `listActiveCategories` already set (decision 187), now
 * reused for contacts/financial accounts/payment channels too (see `@/schemas/planning`'s own doc comment
 * on why this never hits a permission this page did not already require). */
export default async function NewRecurringRulePage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  const { membership } = await requirePermission("planning.recurring_edit", { entityCode: entity });
  const entityId = membership.entity_id;

  const [customers, vendors, accounts, channels, categories] = await Promise.all([
    listActiveContacts(entityId, "customer"),
    listActiveContacts(entityId, "vendor"),
    listActiveFinancialAccounts(entityId),
    listActivePaymentChannels(entityId),
    listActiveCategories(entityId),
  ]);

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link
          href={
            entity
              ? `/planning/recurring?entity=${encodeURIComponent(entity)}`
              : "/planning/recurring"
          }
        >
          ← Kembali ke daftar aturan berulang
        </Link>
      </p>
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Aturan Berulang</p>
          <h1>Buat Aturan Baru</h1>
        </div>
      </header>
      <section className="dashboard-section">
        <RecurringRuleForm
          mode="create"
          entityId={entityId}
          entity={entity}
          customers={customers}
          vendors={vendors}
          accounts={accounts}
          channels={channels}
          categories={categories}
        />
      </section>
    </div>
  );
}
