import { requirePermission } from "@/services/identity/access";
import { getMoneyControl } from "@/services/money/money";
import { listContacts } from "@/services/contacts/contacts";
import { listContactsByRole } from "@/domain/contacts/contactsList";
import { listIncomeCategories, listIncomeTextSuggestions } from "@/services/sales/income";
import { IncomeForm } from "@/features/sales/IncomeForms";
import { todayInBusinessZone } from "@/lib/time";
import { BackLink } from "@/features/shell/BackLink";

/** Catat Pendapatan, new entry (decision 350). Gated `invoices.issue`, the permission the RPC asks for first;
 * the RPC also needs `invoices.confirm_payment`, and says so in words when it is missing. */
export default async function NewIncomePage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  const { membership } = await requirePermission("invoices.issue", { entityCode: entity });
  const entityId = membership.entity_id;
  const [categories, accounts, contacts, suggestions] = await Promise.all([
    listIncomeCategories(entityId),
    getMoneyControl(entityId),
    listContacts(entityId),
    listIncomeTextSuggestions(entityId),
  ]);
  const customers = listContactsByRole(contacts, "customer").filter((c) => c.status === "active");
  const backHref = entity ? `/sales/income?entity=${encodeURIComponent(entity)}` : "/sales/income";

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <BackLink href={backHref}>← Kembali ke daftar pendapatan</BackLink>
      </p>
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Penjualan</p>
          <h1>Catat Pendapatan</h1>
        </div>
      </header>
      <section className="dashboard-section">
        <IncomeForm
          entity={entity}
          today={todayInBusinessZone()}
          categories={categories
            .filter((c) => c.available)
            .map((c) => ({
              id: c.id,
              name: c.name,
              accountName: c.account_name,
              inTurnover: c.in_turnover,
              taxRole: c.tax_role,
            }))}
          accounts={accounts
            .filter((a) => a.is_active)
            .map((a) => ({
              id: a.financial_account_id,
              label: `${a.name} (${a.currency})`,
              name: a.name,
              currency: a.currency,
            }))}
          customers={customers.map((c) => ({ id: c.id, display_name: c.display_name }))}
          referenceSuggestions={suggestions.references}
          noteSuggestions={suggestions.notes}
          personal={membership.entity_type === "personal"}
        />
      </section>
    </div>
  );
}
