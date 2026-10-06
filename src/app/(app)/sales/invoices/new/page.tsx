import Link from "next/link";
import { requirePermission } from "@/services/identity/access";
import { getMoneyControl } from "@/services/money/money";
import { listContacts } from "@/services/contacts/contacts";
import { listActiveCategories } from "@/services/accounting/categories";
import { listLineSuggestions } from "@/services/accounting/lineSuggestions";
import { listContactsByRole } from "@/domain/contacts/contactsList";
import { InvoiceForm } from "@/features/sales/InvoiceForm";
import { listPaymentLinks } from "@/services/sales/paymentLinks";
import { todayInBusinessZone } from "@/lib/time";

/** Create Invoice (Step 09 §11, decision 257), gated `invoices.create` -- the permission
 * `create_invoice_draft` itself checks. Only active customers and active accounts are offered. */
export default async function NewInvoicePage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  const { membership } = await requirePermission("invoices.create", { entityCode: entity });
  const [contacts, categories, accounts, suggestions, paymentLinks] = await Promise.all([
    listContacts(membership.entity_id),
    listActiveCategories(membership.entity_id),
    getMoneyControl(membership.entity_id),
    listLineSuggestions(membership.entity_id, "invoice"),
    listPaymentLinks(membership.entity_id),
  ]);
  const customers = listContactsByRole(contacts, "customer").filter((c) => c.status === "active");
  const backHref = entity
    ? `/sales/invoices?entity=${encodeURIComponent(entity)}`
    : "/sales/invoices";

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={backHref}>← Kembali ke daftar invoice</Link>
      </p>
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Penjualan</p>
          <h1>Buat Invoice</h1>
        </div>
      </header>
      <section className="dashboard-section">
        <InvoiceForm
          customers={customers}
          accounts={accounts.filter((a) => a.is_active)}
          categories={categories}
          suggestions={suggestions}
          paymentLinks={paymentLinks.filter((l) => l.is_active)}
          entity={entity}
          today={todayInBusinessZone()}
        />
      </section>
    </div>
  );
}
