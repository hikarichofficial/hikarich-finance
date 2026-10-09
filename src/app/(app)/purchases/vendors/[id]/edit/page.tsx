import { notFound } from "next/navigation";
import { requirePermission } from "@/services/identity/access";
import { getContact } from "@/services/contacts/contacts";
import { matchesContactRole } from "@/domain/contacts/contactsList";
import { ContactEditForm } from "@/features/contacts/ContactEditForm";
import { BackLink } from "@/features/shell/BackLink";

/** Ubah Vendor (finding #90), gated `contacts.edit` -- the permission the update policy itself checks. */
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
    !matchesContactRole(contact, "vendor")
  ) {
    notFound();
  }
  const backHref = entity
    ? `/purchases/vendors/${id}?entity=${encodeURIComponent(entity)}`
    : `/purchases/vendors/${id}`;

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <BackLink href={backHref}>← Kembali ke detail vendor</BackLink>
      </p>
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Pembelian</p>
          <h1>Ubah Vendor</h1>
        </div>
      </header>
      <section className="dashboard-section">
        <ContactEditForm contact={contact} contactRole="vendor" entity={entity} />
      </section>
    </div>
  );
}
