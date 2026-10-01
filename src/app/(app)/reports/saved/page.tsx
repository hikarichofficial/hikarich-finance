import Link from "next/link";
import { requirePermission } from "@/services/identity/access";
import { listSavedReports } from "@/services/reports/reports";
import { savedReportHref } from "@/domain/reports/salesPurchase";
import { DeleteSavedReportForm } from "@/features/reports/SavedReportForms";
import { formatShortDate } from "@/features/documents/format";

/** Saved Reports (Step 09 §19 "Saved Reports preserve filters/layout", decision 252): the caller's own
 * named report views in the active Entity. Gated `reports.view`, as the table's RLS policy. */
export default async function SavedReportsPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  const { membership } = await requirePermission("reports.view", { entityCode: entity });
  const rows = await listSavedReports(membership.entity_id);

  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Laporan Tersimpan</h1>
          <p className="list-screen-summary">
            Laporan dengan filter yang Anda simpan. Buka laporan mana pun lalu pilih &quot;Simpan laporan
            ini&quot; untuk menambahkannya.
          </p>
        </div>
      </header>
      {rows.length === 0 ? (
        <div className="list-empty">
          <p>Belum ada laporan tersimpan.</p>
        </div>
      ) : (
        <table className="record-table record-table-stacked">
          <thead>
            <tr>
              <th scope="col">Nama</th>
              <th scope="col">Disimpan</th>
              <th scope="col">Tindakan</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.id}>
                <td>
                  <Link href={savedReportHref(r, entity)}>{r.name}</Link>
                </td>
                <td data-label="Disimpan">{formatShortDate(r.created_at)}</td>
                <td data-label="Tindakan">
                  <DeleteSavedReportForm id={r.id} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}
