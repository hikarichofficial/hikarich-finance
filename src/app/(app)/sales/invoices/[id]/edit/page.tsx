import Link from "next/link";
import { notFound } from "next/navigation";
import { requirePermission } from "@/services/identity/access";
import { getMoneyControl } from "@/services/money/money";
import { listContacts } from "@/services/contacts/contacts";
import { listActiveCategories } from "@/services/accounting/categories";
import { listLineSuggestions } from "@/services/accounting/lineSuggestions";
import { getInvoiceDraftForEdit } from "@/services/sales/sales";
import { listContactsByRole } from "@/domain/contacts/contactsList";
import { InvoiceForm } from "@/features/sales/InvoiceForm";

/** Edit a DRAFT invoice (Step 09 §11, decision 261), gated `invoices.edit` -- the permission
 * `update_invoice_draft` checks. An issued invoice is "not found" here: it is corrected instead. */
export default async function EditInvoicePage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string }>;
}) {
  const { id } = await params;
  const { entity } = await searchParams;
  const { membership } = await requirePermission("invoices.edit", { entityCode: entity });
  const draft = await getInvoiceDraftForEdit(id);
  if (!draft || draft.entity_id !== membership.entity_id) notFound();
  const [contacts, categories, accounts, suggestions] = await Promise.all([
    listContacts(membership.entity_id),
    listActiveCategories(membership.entity_id),
    getMoneyControl(membership.entity_id),
    listLineSuggestions(membership.entity_id, "invoice"),
  ]);
  const customers = listContactsByRole(contacts, "customer").filter(
    (c) => c.status === "active" || c.id === draft.customer_id,
  );
  const backHref = entity
    ? `/sales/invoices/${id}?entity=${encodeURIComponent(entity)}`
    : `/sales/invoices/${id}`;

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={backHref}>← Kembali ke invoice</Link>
      </p>
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Penjualan</p>
          <h1>Ubah Draf Invoice</h1>
        </div>
      </header>
      <section className="dashboard-section">
        <InvoiceForm
          customers={customers}
          accounts={accounts.filter((a) => a.is_active)}
          categories={categories}
          suggestions={suggestions}
          entity={entity}
          today={new Date().toISOString().slice(0, 10)}
          initial={draft}
        />
      </section>
    </div>
  );
}
