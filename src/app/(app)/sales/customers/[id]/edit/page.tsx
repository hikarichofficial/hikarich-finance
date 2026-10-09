import { notFound } from "next/navigation";
import { requirePermission } from "@/services/identity/access";
import { getContact } from "@/services/contacts/contacts";
import { matchesContactRole } from "@/domain/contacts/contactsList";
import { ContactEditForm } from "@/features/contacts/ContactEditForm";
import { BackLink } from "@/features/shell/BackLink";

/** Ubah Pelanggan (finding #90), gated `contacts.edit` -- the permission the update policy itself checks. */
export default async function EditContactPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string }>;
}) {
  const { id } = await params;
  const { entity } = await searchParams;
  const { membership } = await requirePermission("contacts.edit", { entityCode: entity });
  const contact = await getContact(id);
  if (
    !contact ||
    contact.entity_id !== membership.entity_id ||
    !matchesContactRole(contact, "customer")
  ) {
    notFound();
  }
  const backHref = entity
    ? `/sales/customers/${id}?entity=${encodeURIComponent(entity)}`
    : `/sales/customers/${id}`;

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <BackLink href={backHref}>← Kembali ke detail pelanggan</BackLink>
      </p>
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Penjualan</p>
          <h1>Ubah Pelanggan</h1>
        </div>
      </header>
      <section className="dashboard-section">
        <ContactEditForm contact={contact} contactRole="customer" entity={entity} />
      </section>
    </div>
  );
}
