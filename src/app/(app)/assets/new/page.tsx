import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import { requirePermission } from "@/services/identity/access";
import { getEntityBaseCurrency, listPendingAssetLines } from "@/services/assets/assets";
import { RegisterPendingAssetForm } from "@/features/assets/AssetForms";
import { formatShortDate } from "@/features/assets/format";

/** Daftarkan Aset, gated `assets.manage` -- the permission `asset_register_pending` itself checks. An
 * asset is never typed in: it is registered from an approved bill line or a confirmed expense line that
 * was marked as an asset and still waits (`asset_pending_lines`). The new asset starts as a draft and is
 * activated on its own detail screen. */
export default async function NewAssetPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  const { membership } = await requirePermission("assets.manage", { entityCode: entity });
  const [lines, currency] = await Promise.all([
    listPendingAssetLines(membership.entity_id),
    getEntityBaseCurrency(membership.entity_id),
  ]);
  const qs = entity ? `?entity=${encodeURIComponent(entity)}` : "";

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={`/assets${qs}`}>← Kembali ke daftar aset</Link>
      </p>
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Aset</p>
          <h1>Daftarkan Aset</h1>
        </div>
      </header>
      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Pembelian yang Menunggu Didaftarkan</h2>
        </div>
        <p className="hint">
          Aset didaftarkan dari baris tagihan atau pengeluaran yang ditandai sebagai aset dan sudah
          disetujui. Setelah didaftarkan, aktifkan aset di halaman detailnya.
        </p>
        {lines.length === 0 ? (
          <p className="dashboard-empty">Tidak ada pembelian aset yang menunggu didaftarkan.</p>
        ) : (
          <table className="record-table record-table-stacked">
            <thead>
              <tr>
                <th scope="col">Keterangan</th>
                <th scope="col">Sumber</th>
                <th scope="col">Tanggal</th>
                <th scope="col" className="num">
                  Nilai
                </th>
                <th scope="col">Tindakan</th>
              </tr>
            </thead>
            <tbody>
              {lines.map((line) => (
                <tr key={`${line.source_type}-${line.line_id}`}>
                  <td>{line.description}</td>
                  <td data-label="Sumber">
                    {line.source_type === "bill_line" ? "Tagihan" : "Pengeluaran"}
                    {line.document_number ? ` ${line.document_number}` : ""}
                  </td>
                  <td data-label="Tanggal">{formatShortDate(line.document_date)}</td>
                  <td className="num" data-label="Nilai">
                    {formatMoney(line.base_amount, currency)}
                  </td>
                  <td data-label="Tindakan">
                    <RegisterPendingAssetForm
                      entity={entity}
                      next={`/assets/new${qs}`}
                      kind={line.source_type}
                      lineId={line.line_id}
                    />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>
    </div>
  );
}
