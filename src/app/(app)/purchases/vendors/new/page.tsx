import Link from "next/link";
import { requirePermission } from "@/services/identity/access";
import { ContactForm } from "@/features/contacts/ContactForm";

/** Tambah Vendor (decision 258), gated `contacts.create` -- the permission `create_contact` itself checks. */
export default async function NewContactPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  await requirePermission("contacts.create", { entityCode: entity });
  const backHref = entity ? `/purchases/vendors?entity=${encodeURIComponent(entity)}` : "/purchases/vendors";

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={backHref}>← Kembali ke daftar vendor</Link>
      </p>
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Pembelian</p>
          <h1>Tambah Vendor</h1>
        </div>
      </header>
      <section className="dashboard-section">
        <ContactForm role="vendor" entity={entity} />
      </section>
    </div>
  );
}
