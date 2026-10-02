import { notFound } from "next/navigation";
import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import { getContact, getContactTaxFacts } from "@/services/contacts/contacts";
import { matchesContactRole } from "@/domain/contacts/contactsList";
import { ContactDetailScreen } from "@/features/contacts/ContactDetailScreen";

/** Customer Detail (P13, Step 09 §10/§11). Permission is read off the currently active Entity (`?entity=`),
 * the same per-page pattern every other screen uses (decision 158). A contact belonging to a different
 * Entity, one recorded only as `vendor` (never `customer`/`both`), or one the caller cannot see
 * (`contacts.view` failed already, above) all land here as "not found" -- the same no-existence-leak shape
 * `AccountDetailPage` already established (decision 169). */
export default async function CustomerDetailPage({
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
    !matchesContactRole(contact, "customer")
  ) {
    notFound();
  }

  const canSeeTax = can(access, membership.entity_id, "tax.view");
  const taxFacts = canSeeTax ? await getContactTaxFacts(id) : null;

  const backHref = entity
    ? `/sales/customers?entity=${encodeURIComponent(entity)}`
    : "/sales/customers";

  return (
    <ContactDetailScreen
      contact={contact}
      backHref={backHref}
      backLabel="Kembali ke daftar pelanggan"
      tax={
        canSeeTax
          ? {
              facts: taxFacts,
              canRecord: can(access, membership.entity_id, "tax.confirm_facts"),
              today: new Date().toISOString().slice(0, 10),
            }
          : undefined
      }
    />
  );
}
