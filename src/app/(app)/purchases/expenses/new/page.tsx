import Link from "next/link";
import { requirePermission } from "@/services/identity/access";
import { getMoneyControl } from "@/services/money/money";
import { listContacts } from "@/services/contacts/contacts";
import { listActiveCategories } from "@/services/accounting/categories";
import { listContactsByRole } from "@/domain/contacts/contactsList";
import { ExpenseForm } from "@/features/purchases/ExpenseForm";

/** Record Expense (Step 09 §12/§22, decision 245), gated `bills.create` -- the permission
 * `create_expense_draft` itself checks. Only active accounts and active vendors are offered. */
export default async function NewExpensePage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  const { membership } = await requirePermission("bills.create", { entityCode: entity });
  const [accounts, contacts, categories] = await Promise.all([
    getMoneyControl(membership.entity_id),
    listContacts(membership.entity_id),
    listActiveCategories(membership.entity_id),
  ]);
  const vendors = listContactsByRole(contacts, "vendor").filter((c) => c.status === "active");
  const backHref = entity
    ? `/purchases/expenses?entity=${encodeURIComponent(entity)}`
    : "/purchases/expenses";

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={backHref}>← Kembali ke daftar pengeluaran</Link>
      </p>
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Pengeluaran</p>
          <h1>Catat Pengeluaran</h1>
        </div>
      </header>
      <section className="dashboard-section">
        <ExpenseForm
          accounts={accounts.filter((a) => a.is_active)}
          vendors={vendors}
          categories={categories}
          entity={entity}
          today={new Date().toISOString().slice(0, 10)}
        />
      </section>
    </div>
  );
}
