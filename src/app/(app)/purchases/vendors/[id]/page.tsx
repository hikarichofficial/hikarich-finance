import { notFound } from "next/navigation";
import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import { getContact, getContactTaxFacts } from "@/services/contacts/contacts";
import { matchesContactRole } from "@/domain/contacts/contactsList";
import { ContactDetailScreen } from "@/features/contacts/ContactDetailScreen";
import { todayInBusinessZone } from "@/lib/time";

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
  const { access, membership } = await requirePermission("contacts.view", { entityCode: entity });

  const contact = await getContact(id);
  if (
    !contact ||
    contact.entity_id !== membership.entity_id ||
    !matchesContactRole(contact, "vendor")
  ) {
    notFound();
  }

  const canSeeTax = can(access, membership.entity_id, "tax.view");
  const taxFacts = canSeeTax ? await getContactTaxFacts(id) : null;

  const backHref = entity
    ? `/purchases/vendors?entity=${encodeURIComponent(entity)}`
    : "/purchases/vendors";

  return (
    <ContactDetailScreen
      contact={contact}
      backHref={backHref}
      manage={
        can(access, membership.entity_id, "contacts.edit")
          ? {
              editHref: entity
                ? `/purchases/vendors/${id}/edit?entity=${encodeURIComponent(entity)}`
                : `/purchases/vendors/${id}/edit`,
              entity,
            }
          : undefined
      }
      backLabel="Kembali ke daftar vendor"
      tax={
        canSeeTax
          ? {
              facts: taxFacts,
              canRecord: can(access, membership.entity_id, "tax.confirm_facts"),
              today: todayInBusinessZone(),
            }
          : undefined
      }
    />
  );
}
