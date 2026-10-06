import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import { listPaymentLinks } from "@/services/sales/paymentLinks";
import { PaymentLinkCreateForm, PaymentLinkEditForm } from "@/features/sales/PaymentLinkForms";

/** Tautan Pembayaran (decision 307): the payment gateway pages an invoice can point its customer to. Viewing
 * needs `invoices.view` (the list itself is read with `money.view`, as the accounts of an invoice are);
 * adding or changing a link needs `invoices.create`, the permission the RPCs check. */
export default async function PaymentLinksPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  const { access, membership } = await requirePermission("invoices.view", { entityCode: entity });
  const canManage = can(access, membership.entity_id, "invoices.create");
  const links = await listPaymentLinks(membership.entity_id);

  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Tautan Pembayaran</h1>
          <p className="list-screen-summary">
            {links.length} tautan. Tautan dipilih di form Buat Invoice dan tampil di invoice sebagai
            tombol “Bayar sekarang” yang bisa diklik pelanggan.
          </p>
        </div>
      </header>

      {canManage ? (
        <section className="dashboard-section">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">Tambah Tautan</h2>
          </div>
          <PaymentLinkCreateForm entity={entity} />
        </section>
      ) : null}

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Daftar Tautan</h2>
        </div>
        {links.length === 0 ? (
          <p className="dashboard-empty">Belum ada tautan pembayaran.</p>
        ) : (
          <ul className="record-activity-list">
            {links.map((link) => (
              <li key={link.id} className="record-activity-item">
                <details>
                  <summary>
                    <strong>{link.name}</strong>{" "}
                    <span className="status-badge status-badge-neutral">
                      {link.is_active ? "Aktif" : "Nonaktif"}
                    </span>
                    <br />
                    <span className="record-activity-date">{link.payment_url}</span>
                  </summary>
                  {canManage ? <PaymentLinkEditForm entity={entity} link={link} /> : null}
                </details>
              </li>
            ))}
          </ul>
        )}
      </section>
    </div>
  );
}
