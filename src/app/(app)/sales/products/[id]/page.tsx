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
    </div>
  );
}
