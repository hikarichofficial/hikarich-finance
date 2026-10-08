import Link from "next/link";
import { requirePermission } from "@/services/identity/access";
import { listContacts } from "@/services/contacts/contacts";
import { getWithholdingAgent } from "@/services/tax/tax";
import { listActiveCategories } from "@/services/accounting/categories";
import { listLineSuggestions } from "@/services/accounting/lineSuggestions";
import { listContactsByRole } from "@/domain/contacts/contactsList";
import { BillForm } from "@/features/purchases/BillForm";
import { todayInBusinessZone } from "@/lib/time";

/** Record Bill (Step 09 §12, decision 257), gated `bills.create` -- the permission `create_bill_draft`
 * itself checks. Only active vendors are offered. */
export default async function NewBillPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  const { membership } = await requirePermission("bills.create", { entityCode: entity });
  const [contacts, categories, suggestions, whtAgent] = await Promise.all([
    listContacts(membership.entity_id),
    listActiveCategories(membership.entity_id),
    listLineSuggestions(membership.entity_id, "bill"),
    getWithholdingAgent(membership.entity_id),
  ]);
  const vendors = listContactsByRole(contacts, "vendor").filter((c) => c.status === "active");
  const backHref = entity
    ? `/purchases/bills?entity=${encodeURIComponent(entity)}`
    : "/purchases/bills";

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={backHref}>← Kembali ke daftar tagihan</Link>
      </p>
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Tagihan Pembelian</p>
          <h1>Catat Tagihan</h1>
        </div>
      </header>
      <section className="dashboard-section">
        <BillForm
          vendors={vendors}
          categories={categories}
          whtAgent={whtAgent}
          suggestions={suggestions}
          entity={entity}
          today={todayInBusinessZone()}
        />
      </section>
    </div>
  );
}
