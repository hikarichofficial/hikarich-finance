import Link from "next/link";
import { requirePermission } from "@/services/identity/access";
import {
  getSkuSettings,
  listSkuHistory,
  listSkuMasters,
  listUsedSkuMasterIds,
} from "@/services/products/sku";
import { SkuFormatForm } from "@/features/products/SkuFormatForm";
import { SkuMasterManager } from "@/features/products/SkuMasterManager";
import { formatShortDate } from "@/features/sales/format";

/** Konfigurasi SKU (decision 324): the Owner sets the SKU format, brands, product types, variants and numbering
 * here. Needs `products.sku_settings` (the Owner holds it; no other role is given it by default). */
const TABS = [
  { key: "format", label: "Format & Nomor" },
  { key: "brand", label: "Brand" },
  { key: "type", label: "Jenis Produk" },
  { key: "variant", label: "Variant" },
  { key: "history", label: "Riwayat" },
] as const;
type Tab = (typeof TABS)[number]["key"];

export default async function SkuConfigurationPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; tab?: string }>;
}) {
  const { entity, tab: tabParam } = await searchParams;
  const { membership } = await requirePermission("products.sku_settings", { entityCode: entity });
  const entityId = membership.entity_id;
  const tab: Tab = TABS.some((t) => t.key === tabParam) ? (tabParam as Tab) : "format";
  const href = (key: Tab) => {
    const params = new URLSearchParams();
    if (entity) params.set("entity", entity);
    if (key !== "format") params.set("tab", key);
    const qs = params.toString();
    return qs ? `/admin/sku?${qs}` : "/admin/sku";
  };

  const [settings, brands, types, variants, used] = await Promise.all([
    getSkuSettings(entityId),
    listSkuMasters("brand", entityId),
    listSkuMasters("type", entityId),
    listSkuMasters("variant", entityId),
    listUsedSkuMasterIds(entityId),
  ]);
  const history = tab === "history" ? await listSkuHistory(entityId) : [];
  const usedIds = [...used];
  const firstLive = <T extends { archived_at: string | null; is_active: boolean; code: string }>(
    rows: readonly T[],
    fallback: string,
  ) => rows.find((r) => !r.archived_at && r.is_active)?.code ?? fallback;

  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Konfigurasi SKU</h1>
          <p className="list-screen-summary">
            Atur bagaimana SKU produk dibuat otomatis: format, brand, jenis produk, variant, dan
            nomor urut. Berlaku untuk SKU baru; dokumen dan transaksi lama tidak berubah.
          </p>
        </div>
      </header>

      <nav className="list-filter-tabs" aria-label="Bagian konfigurasi SKU">
        {TABS.map((t) => (
          <Link
            key={t.key}
            href={href(t.key)}
            className={t.key === tab ? "list-filter-tab list-filter-tab-active" : "list-filter-tab"}
          >
            {t.label}
          </Link>
        ))}
      </nav>

      {tab === "format" ? (
        settings ? (
          <SkuFormatForm
            settings={settings}
            entity={entity}
            sample={{
              brand: firstLive(brands, "KEA"),
              type: firstLive(types, "EA"),
              variant: firstLive(variants, "1B"),
            }}
          />
        ) : (
          <p className="hint">Pengaturan SKU untuk entitas ini belum tersedia.</p>
        )
      ) : null}
      {tab === "brand" ? (
        <SkuMasterManager kind="brand" rows={brands} usedIds={usedIds} entity={entity} />
      ) : null}
      {tab === "type" ? (
        <SkuMasterManager kind="type" rows={types} usedIds={usedIds} entity={entity} />
      ) : null}
      {tab === "variant" ? (
        <SkuMasterManager kind="variant" rows={variants} usedIds={usedIds} entity={entity} />
      ) : null}
      {tab === "history" ? (
        history.length === 0 ? (
          <p className="hint">Belum ada riwayat SKU.</p>
        ) : (
          <table className="record-table record-table-stacked">
            <thead>
              <tr>
                <th scope="col">Tanggal</th>
                <th scope="col">Produk</th>
                <th scope="col">SKU Lama</th>
                <th scope="col">SKU Baru</th>
                <th scope="col">Cara</th>
                <th scope="col">Alasan</th>
              </tr>
            </thead>
            <tbody>
              {history.map((row) => (
                <tr key={row.id}>
                  <td data-label="Tanggal">{formatShortDate(row.changed_at.slice(0, 10))}</td>
                  <td data-label="Produk">
                    <Link
                      href={`/sales/products/${row.product_id}${entity ? `?entity=${encodeURIComponent(entity)}` : ""}`}
                    >
                      {row.product_name ?? "Produk"}
                    </Link>
                  </td>
                  <td data-label="SKU Lama">{row.old_sku ?? "—"}</td>
                  <td data-label="SKU Baru">{row.new_sku ?? "—"}</td>
                  <td data-label="Cara">
                    {row.source === "generated"
                      ? "Otomatis"
                      : row.source === "manual"
                        ? "Manual"
                        : "Diubah"}
                  </td>
                  <td data-label="Alasan">{row.reason ?? "—"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )
      ) : null}
    </div>
  );
}
