import { requirePermission } from "@/services/identity/access";
import { listContacts } from "@/services/contacts/contacts";
import {
  filterContactRows,
  listContactsByRole,
  parseContactFilter,
} from "@/domain/contacts/contactsList";
import { ContactsListScreen } from "@/features/contacts/ContactsListScreen";

/** Vendors List (P13, Step 09 §12's own sitemap entry, Step 09 §9), the exact same generalized
 * `ContactsListScreen` Customers uses (decision -- see `src/features/contacts/ContactsListScreen.tsx`'s
 * own doc comment), scoped to `kind = 'vendor' | 'both'` instead. */
export default async function VendorsListPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; status?: string; q?: string }>;
}) {
  const { entity, status, q } = await searchParams;
  const { membership } = await requirePermission("contacts.view", { entityCode: entity });
  const filter = parseContactFilter(status) ?? null;
  const query = q ?? "";

  const rows = await listContacts(membership.entity_id);
  const vendors = listContactsByRole(rows, "vendor");
  const visible = filterContactRows(vendors, filter, query);

  return (
    <ContactsListScreen
      rows={visible}
      activeFilter={filter}
      query={query}
      entity={entity}
      basePath="/purchases/vendors"
      title="Vendor"
      searchPlaceholder="Cari nama, email, atau telepon…"
      emptyLabel="Belum ada vendor pada tampilan ini."
    />
  );
}
