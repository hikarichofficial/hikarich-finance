import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import {
  PRODUCT_FILTER_OPTIONS,
  PRODUCT_KIND_LABELS,
  type ProductFilter,
} from "@/domain/products/productsList";
import type { ProductRow } from "@/schemas/products";

/** Products & Services List (Step 09 §3 Sales, decision 245). */

function buildHref(
  entity: string | undefined,
  filter: ProductFilter | undefined,
  q: string,
): string {
  const params = new URLSearchParams();
  if (entity) params.set("entity", entity);
  if (filter) params.set("filter", filter);
  if (q.trim()) params.set("q", q.trim());
  const qs = params.toString();
  return qs ? `/sales/products?${qs}` : "/sales/products";
}

function priceText(row: ProductRow, baseCurrency: string): string {
  if (row.default_unit_price === null) return "—";
  return formatMoney(String(row.default_unit_price), row.default_currency ?? baseCurrency);
}

export function ProductsListScreen({
  rows,
  activeFilter,
  query,
  entity,
  baseCurrency,
  canCreate,
}: {
  rows: readonly ProductRow[];
  activeFilter: ProductFilter | undefined;
  query: string;
  entity: string | undefined;
  baseCurrency: string;
  canCreate: boolean;
}) {
  const newHref = entity
    ? `/sales/products/new?entity=${encodeURIComponent(entity)}`
    : "/sales/products/new";

  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Produk &amp; Jasa</h1>
          <p className="list-screen-summary">{rows.length} item ditampilkan.</p>
        </div>
        {canCreate ? (
          <Link href={newHref} className="btn-primary">
            Tambah Produk
          </Link>
        ) : null}
      </header>

      <div className="list-screen-toolbar">
        <nav className="list-filter-tabs" aria-label="Saring produk">
          {PRODUCT_FILTER_OPTIONS.map((option) => (
            <Link
              key={option.label}
              href={buildHref(entity, option.value, query)}
              className={
                option.value === activeFilter
                  ? "list-filter-tab list-filter-tab-active"
                  : "list-filter-tab"
              }
            >
              {option.label}
            </Link>
          ))}
        </nav>
        <form method="get" className="list-search-form">
          {entity ? <input type="hidden" name="entity" value={entity} /> : null}
          {activeFilter ? <input type="hidden" name="filter" value={activeFilter} /> : null}
          <input
            type="search"
            name="q"
            defaultValue={query}
            placeholder="Cari nama, SKU atau deskripsi…"
            aria-label="Cari produk"
          />
          <button type="submit" className="btn-secondary">
            Cari
          </button>
        </form>
      </div>

      {rows.length === 0 ? (
        <div className="list-empty">
          <p>
            {activeFilter || query.trim()
              ? "Tidak ada produk yang cocok."
              : "Belum ada produk atau jasa. Tambahkan yang Anda jual agar faktur lebih cepat dibuat."}
          </p>
          {canCreate && !activeFilter && !query.trim() ? (
            <Link href={newHref} className="btn-primary list-empty-action">
              Tambah Produk
            </Link>
          ) : null}
        </div>
      ) : (
        <table className="record-table record-table-stacked">
          <thead>
            <tr>
              <th scope="col">Nama</th>
              <th scope="col">Jenis</th>
              <th scope="col">SKU</th>
              <th scope="col">Satuan</th>
              <th scope="col" className="num">
                Harga Bawaan
              </th>
              <th scope="col">Status</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => {
              const href = entity
                ? `/sales/products/${row.id}?entity=${encodeURIComponent(entity)}`
                : `/sales/products/${row.id}`;
              const tone = row.is_active ? "success" : "neutral";
              return (
                <tr key={row.id}>
                  <td>
                    <Link href={href}>{row.name}</Link>
                  </td>
                  <td data-label="Jenis">{PRODUCT_KIND_LABELS[row.kind]}</td>
                  <td data-label="SKU">{row.sku ?? "—"}</td>
                  <td data-label="Satuan">{row.unit}</td>
                  <td className="num" data-label="Harga Bawaan">
                    {priceText(row, baseCurrency)}
                  </td>
                  <td data-label="Status">
                    <span className={`status-badge status-badge-${tone}`}>
                      {row.is_active ? "Aktif" : "Nonaktif"}
                    </span>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
    </div>
  );
}
