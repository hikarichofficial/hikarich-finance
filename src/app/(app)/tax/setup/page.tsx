import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import { getTaxOverview } from "@/services/tax/tax";
import { formatShortDate } from "@/features/tax/format";
import { TaxEngineForm, TaxProfileForm } from "@/features/tax/TaxSetupForms";

/** Tax Setup (decision 258, Step 05 §3-§4): the Entity's tax profile and the engine switch. Viewing needs
 * `tax.view`; the forms appear with `tax.confirm_facts` (the profile RPC's own check). The engine switch is
 * additionally OWNER-only with a recent step-up, which the database enforces and the form explains. */
export default async function TaxSetupPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  const { access, membership } = await requirePermission("tax.view", { entityCode: entity });
  const overview = await getTaxOverview(membership.entity_id);
  const canRecord = can(access, membership.entity_id, "tax.confirm_facts");
  const today = new Date().toISOString().slice(0, 10);
  const next = entity ? `/tax/setup?entity=${encodeURIComponent(entity)}` : "/tax/setup";
  const p = overview.profile;

  return (
    <div className="record-detail">
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Pajak</p>
          <h1>Pengaturan Pajak</h1>
        </div>
      </header>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Profil Pajak Entitas</h2>
        </div>
        <p className="hint">
          {p
            ? `Profil yang berlaku tercatat sejak ${formatShortDate(p.effective_from)}. Untuk perubahan (mis. menjadi PKP), simpan lagi dengan tanggal mulai berlakunya; riwayat lama tetap tersimpan.`
            : "Belum ada profil pajak. Tanpa profil, pajak tidak dihitung otomatis."}
        </p>
        {canRecord ? (
          <TaxProfileForm entity={entity} profile={p} today={today} next={next} />
        ) : null}
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Mesin Pajak</h2>
        </div>
        <p className="hint">
          {overview.engine_active_from
            ? `Aktif sejak ${formatShortDate(overview.engine_active_from)}. Dokumen bertanggal sebelum itu tidak dihitung pajaknya.`
            : "Belum aktif. Setelah profil pajak diisi, aktifkan supaya invoice, tagihan dan pengeluaran dihitung pajaknya otomatis."}
        </p>
        {canRecord && p && !overview.engine_active_from ? (
          <TaxEngineForm entity={entity} today={today} next={next} />
        ) : null}
      </section>
    </div>
  );
}
