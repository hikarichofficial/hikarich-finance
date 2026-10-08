import Link from "next/link";
import { notFound } from "next/navigation";
import { requirePermission } from "@/services/identity/access";
import { listContacts } from "@/services/contacts/contacts";
import { getWithholdingAgent } from "@/services/tax/tax";
import { listActiveCategories } from "@/services/accounting/categories";
import { listLineSuggestions } from "@/services/accounting/lineSuggestions";
import { getBillDraftForEdit } from "@/services/purchases/purchases";
import { listContactsByRole } from "@/domain/contacts/contactsList";
import { BillForm } from "@/features/purchases/BillForm";
import { todayInBusinessZone } from "@/lib/time";

/** Edit a DRAFT bill (Step 09 §12, decision 261), gated `bills.edit` -- the permission `update_bill_draft`
 * checks. Anything that is no longer a draft is "not found" here: a recognised bill is corrected instead. */
export default async function EditBillPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string }>;
}) {
  const { id } = await params;
  const { entity } = await searchParams;
  const { membership } = await requirePermission("bills.edit", { entityCode: entity });
  const draft = await getBillDraftForEdit(id);
  if (!draft || draft.entity_id !== membership.entity_id) notFound();
  const [contacts, categories, suggestions, whtAgent] = await Promise.all([
    listContacts(membership.entity_id),
    listActiveCategories(membership.entity_id),
    listLineSuggestions(membership.entity_id, "bill"),
    getWithholdingAgent(membership.entity_id),
  ]);
  const vendors = listContactsByRole(contacts, "vendor").filter(
    (c) => c.status === "active" || c.id === draft.vendor_id,
  );
  const backHref = entity
    ? `/purchases/bills/${id}?entity=${encodeURIComponent(entity)}`
    : `/purchases/bills/${id}`;

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={backHref}>← Kembali ke tagihan</Link>
      </p>
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Tagihan Pembelian</p>
          <h1>Ubah Draf Tagihan</h1>
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
          initial={draft}
        />
      </section>
    </div>
  );
}
