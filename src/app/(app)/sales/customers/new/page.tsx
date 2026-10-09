import { requirePermission } from "@/services/identity/access";
import { ContactForm } from "@/features/contacts/ContactForm";
import { BackLink } from "@/features/shell/BackLink";

/** Tambah Pelanggan (decision 258), gated `contacts.create` -- the permission `create_contact` itself checks. */
export default async function NewContactPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  await requirePermission("contacts.create", { entityCode: entity });
  const backHref = entity
    ? `/sales/customers?entity=${encodeURIComponent(entity)}`
    : "/sales/customers";

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <BackLink href={backHref}>← Kembali ke daftar pelanggan</BackLink>
      </p>
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Penjualan</p>
          <h1>Tambah Pelanggan</h1>
        </div>
      </header>
      <section className="dashboard-section">
        <ContactForm contactRole="customer" entity={entity} />
      </section>
    </div>
  );
}
