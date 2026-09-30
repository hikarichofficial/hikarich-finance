import { requirePermission } from "@/services/identity/access";
import { listContacts } from "@/services/contacts/contacts";
import {
  filterContactRows,
  listContactsByRole,
  parseContactFilter,
} from "@/domain/contacts/contactsList";
import { ContactsListScreen } from "@/features/contacts/ContactsListScreen";

/** Customers List (P13, Step 09 §11's own sitemap entry, Step 09 §9). `?status=` is one of
 * `CONTACT_FILTER_OPTIONS`' values; an absent or unknown value shows every customer, matching every other
 * List screen's own null-filter meaning. A contact recorded as `kind = 'both'` appears here too. */
export default async function CustomersListPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; status?: string; q?: string }>;
}) {
  const { entity, status, q } = await searchParams;
  const { membership } = await requirePermission("contacts.view", { entityCode: entity });
  const filter = parseContactFilter(status) ?? null;
  const query = q ?? "";

  const rows = await listContacts(membership.entity_id);
  const customers = listContactsByRole(rows, "customer");
  const visible = filterContactRows(customers, filter, query);

  return (
    <ContactsListScreen
      rows={visible}
      activeFilter={filter}
      query={query}
      entity={entity}
      basePath="/sales/customers"
      title="Pelanggan"
      searchPlaceholder="Cari nama, email, atau telepon…"
      emptyLabel="Belum ada pelanggan pada tampilan ini."
    />
  );
}
