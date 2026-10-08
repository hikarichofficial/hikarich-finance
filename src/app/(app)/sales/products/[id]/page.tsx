import Link from "next/link";
import { notFound } from "next/navigation";
import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import { getProduct } from "@/services/products/products";
import { listActiveCategories } from "@/services/accounting/categories";
import { getEntityBaseCurrency } from "@/services/accounting/ledger";
import { formatMoney } from "@/domain/money/format";
import { PRODUCT_KIND_LABELS } from "@/domain/products/productsList";
import { ExpandableText } from "@/features/shared/ExpandableText";
import {
  listProductVariants,
  listSkuHistory,
  listSkuMasters,
  productUsedOnDocuments,
} from "@/services/products/sku";
import { AddVariantForm, ChangeSkuForm } from "@/features/products/ProductSkuPanel";

/** Product Detail (decision 245, compact in task 95): a read-only summary for everyone with `products.view`;
 * the edit form is its own page (`./edit`, `products.edit`) so viewing and editing are never stacked. Archiving (`products.archive` maps to a hard delete policy) is deliberately not offered:
 * a product may already be referenced by invoice lines, so it is deactivated instead. */
export default async function ProductDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string }>;
}) {
  const { id } = await params;
  const { entity } = await searchParams;
  const { access, membership } = await requirePermission("products.view", { entityCode: entity });
  const [product, categories, baseCurrency] = await Promise.all([
    getProduct(membership.entity_id, id),
    listActiveCategories(membership.entity_id),
    getEntityBaseCurrency(membership.entity_id),
  ]);
  if (!product) notFound();

  const entityId = membership.entity_id;
  const canOverride = can(access, entityId, "products.sku_override");
  const canCreate = can(access, entityId, "products.create");
  const canAddVariants = can(access, entityId, "products.sku_settings");
  const isVariant = product.parent_product_id !== null;
  const [variantRows, variantMasters, brands, types, history, usedOnDocuments, parent] =
    await Promise.all([
      isVariant ? Promise.resolve([]) : listProductVariants(entityId, id),
      listSkuMasters("variant", entityId),
      product.brand_id ? listSkuMasters("brand", entityId) : Promise.resolve([]),
      product.product_type_id ? listSkuMasters("type", entityId) : Promise.resolve([]),
      listSkuHistory(entityId, { productId: id, limit: 20 }),
      canOverride ? productUsedOnDocuments(id) : Promise.resolve(false),
      product.parent_product_id ? getProduct(entityId, product.parent_product_id) : null,
    ]);
  const brand = brands.find((b) => b.id === product.brand_id);
  const type = types.find((t) => t.id === product.product_type_id);
  const variantName = variantMasters.find((v) => v.id === product.variant_id)?.name;
  const takenVariantIds = new Set(
    variantRows.map((row) => row.variant_id).filter((v): v is string => v !== null),
  );
  const offered = variantMasters.filter(
    (v) => !v.archived_at && v.is_active && !takenVariantIds.has(v.id),
  );
  const withEntity = (path: string) =>
    entity ? `${path}?entity=${encodeURIComponent(entity)}` : path;

  const canEdit = can(access, membership.entity_id, "products.edit");
  const backHref = entity
    ? `/sales/products?entity=${encodeURIComponent(entity)}`
    : "/sales/products";
  const editHref = entity
    ? `/sales/products/${id}/edit?entity=${encodeURIComponent(entity)}`
    : `/sales/products/${id}/edit`;
  const category = categories.find((c) => c.id === product.default_category_id);
  const price =
    product.default_unit_price === null
      ? "—"
      : formatMoney(String(product.default_unit_price), product.default_currency ?? baseCurrency);

  return (
    <div className="record-detail record-detail-compact">
      <p className="record-detail-back">
        <Link href={backHref}>← Kembali ke daftar produk</Link>
      </p>
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">{PRODUCT_KIND_LABELS[product.kind]}</p>
          <h1>{product.name}</h1>
        </div>
        <div className="record-detail-header-end">
          <span
            className={`status-badge status-badge-${product.is_active ? "success" : "neutral"}`}
          >
            {product.is_active ? "Aktif" : "Nonaktif"}
          </span>
          <p className="record-detail-amount">{price}</p>
          {canEdit ? (
            <Link href={editHref} className="btn-secondary">
              Ubah
            </Link>
          ) : null}
        </div>
      </header>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Ringkasan</h2>
        </div>
        <dl className="record-summary-grid record-summary-compact">
          <div>
            <dt>SKU</dt>
            <dd>{product.sku ?? "—"}</dd>
          </div>
          {brand ? (
            <div>
              <dt>Brand</dt>
              <dd>
                {brand.name} ({brand.code})
              </dd>
            </div>
          ) : null}
          {type ? (
            <div>
              <dt>Jenis Produk</dt>
              <dd>
                {type.name} ({type.code})
              </dd>
            </div>
          ) : null}
          {product.sku_number !== null ? (
            <div>
              <dt>Nomor Produk</dt>
              <dd>{product.sku_number}</dd>
            </div>
          ) : null}
          {variantName ? (
            <div>
              <dt>Variant</dt>
              <dd>{variantName}</dd>
            </div>
          ) : null}
          {parent ? (
            <div>
              <dt>Produk Utama</dt>
              <dd>
                <Link href={withEntity(`/sales/products/${parent.id}`)}>{parent.name}</Link>
              </dd>
            </div>
          ) : null}
          <div>
            <dt>Satuan</dt>
            <dd>{product.unit}</dd>
          </div>
          <div>
            <dt>Kategori Bawaan</dt>
            <dd>{category?.name ?? "—"}</dd>
          </div>
          <div className="record-summary-wide">
            <dt>Deskripsi</dt>
            <dd>
              {product.description ? (
                <ExpandableText text={product.description} limit={220} />
              ) : (
                "—"
              )}
            </dd>
          </div>
        </dl>
      </section>

      {!isVariant && (variantRows.length > 0 || canCreate) ? (
        <section className="dashboard-section">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">Variant</h2>
          </div>
          {variantRows.length === 0 ? (
            <p className="hint">
              Belum ada variant. Tambahkan variant (mis. 1 Bulan, 3 Bulan) bila produk ini dijual
              dalam beberapa pilihan; tiap variant punya SKU, harga, dan status sendiri.
            </p>
          ) : (
            <table className="record-table record-table-stacked">
              <thead>
                <tr>
                  <th scope="col">Variant</th>
                  <th scope="col">SKU</th>
                  <th scope="col">Harga</th>
                  <th scope="col">Status</th>
                </tr>
              </thead>
              <tbody>
                {variantRows.map((row) => (
                  <tr key={row.id}>
                    <td>
                      <Link href={withEntity(`/sales/products/${row.id}`)}>{row.name}</Link>
                    </td>
                    <td data-label="SKU">{row.sku ?? "—"}</td>
                    <td data-label="Harga">
                      {row.price === null
                        ? "—"
                        : formatMoney(row.price, product.default_currency ?? baseCurrency)}
                    </td>
                    <td data-label="Status">{row.is_active ? "Aktif" : "Nonaktif"}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
          {canCreate && product.sku && (offered.length > 0 || canAddVariants) ? (
            <AddVariantForm
              entity={entity}
              parentId={id}
              variants={offered}
              canAddVariants={canAddVariants}
            />
          ) : null}
        </section>
      ) : null}

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Riwayat SKU</h2>
        </div>
        {history.length === 0 ? (
          <p className="hint">Belum ada riwayat SKU.</p>
        ) : (
          <ul className="hint">
            {history.map((row) => (
              <li key={row.id}>
                {row.changed_at.slice(0, 10)} · {row.old_sku ?? "—"} → {row.new_sku ?? "—"} (
                {row.source === "generated"
                  ? "otomatis"
                  : row.source === "manual"
                    ? "manual"
                    : "diubah"}
                {row.reason ? `: ${row.reason}` : ""})
              </li>
            ))}
          </ul>
        )}
        {canOverride ? (
          <ChangeSkuForm
            entity={entity}
            productId={id}
            currentSku={product.sku}
            usedOnDocuments={usedOnDocuments}
          />
        ) : null}
      </section>
    </div>
  );
}
