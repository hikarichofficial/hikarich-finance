import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import {
  getEntityLogo,
  getEntitySettingsOverview,
  getInvoiceLayout,
} from "@/services/settings/settings";
import { InvoiceLayoutEditor } from "@/features/settings/InvoiceLayoutEditor";
import { sampleInvoiceDocument } from "@/features/settings/sampleInvoiceDocument";

/** Tampilan Invoice (decision 310): arrange the invoice document by dragging its blocks. Viewing needs
 * `settings.view`; saving needs `system.entity_config` (the RPC re-checks it and a recent step-up). */
export default async function InvoiceLayoutPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  const { access, membership } = await requirePermission("settings.view", { entityCode: entity });
  const entityId = membership.entity_id;
  const canEdit = can(access, entityId, "system.entity_config");
  const [overview, layout, logo] = await Promise.all([
    getEntitySettingsOverview(entityId),
    getInvoiceLayout(entityId),
    getEntityLogo(entityId),
  ]);
  const here = entity
    ? `/admin/invoice-layout?entity=${encodeURIComponent(entity)}`
    : "/admin/invoice-layout";
  const profile = overview.profile;
  const sample = sampleInvoiceDocument({
    legal_name: overview.entity.legal_name,
    brand_name: overview.entity.brand_name,
    address_line: profile?.address_line ?? null,
    city: profile?.city ?? null,
    province: profile?.province ?? null,
    postal_code: profile?.postal_code ?? null,
    contact_email: profile?.contact_email ?? null,
    contact_phone: profile?.contact_phone ?? null,
  });

  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Tampilan Invoice</h1>
          <p className="list-screen-summary">
            Atur letak logo, nama perusahaan, tabel, total, dan bagian lain pada invoice dengan
            menyeretnya. Berlaku untuk invoice yang diterbitkan setelah disimpan.
          </p>
        </div>
      </header>
      {canEdit ? (
        <InvoiceLayoutEditor
          entity={entity}
          saved={layout}
          logo={logo}
          sample={sample}
          stepUpHref={`/auth/step-up?next=${encodeURIComponent(here)}`}
        />
      ) : (
        <p className="dashboard-empty">
          Hanya pemilik yang dapat mengubah tampilan invoice. Anda dapat melihat halaman ini, tetapi
          tidak dapat menyimpan perubahan.
        </p>
      )}
    </div>
  );
}
