import { notFound } from "next/navigation";
import { requirePermission } from "@/services/identity/access";
import { getContact } from "@/services/contacts/contacts";
import { matchesContactRole } from "@/domain/contacts/contactsList";
import { ContactDetailScreen } from "@/features/contacts/ContactDetailScreen";

/** Vendor Detail (P13, Step 09 §10/§12), the same generalized `ContactDetailScreen` Customer Detail uses,
 * scoped to `kind = 'vendor' | 'both'` instead. */
export default async function VendorDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string }>;
}) {
  const { id } = await params;
  const { entity } = await searchParams;
  const { membership } = await requirePermission("contacts.view", { entityCode: entity });

  const contact = await getContact(id);
  if (
    !contact ||
    contact.entity_id !== membership.entity_id ||
    !matchesContactRole(contact, "vendor")
  ) {
    notFound();
  }

  const backHref = entity
    ? `/purchases/vendors?entity=${encodeURIComponent(entity)}`
    : "/purchases/vendors";

  return (
    <ContactDetailScreen
      contact={contact}
      backHref={backHref}
      backLabel="Kembali ke daftar vendor"
    />
  );
}
