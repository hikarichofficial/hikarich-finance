import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import { getSkuSettings, listSkuMasters } from "@/services/products/sku";
import { listActiveCategories } from "@/services/accounting/categories";
import { getEntityBaseCurrency } from "@/services/accounting/ledger";
import { ProductForm } from "@/features/products/ProductForm";
import { BackLink } from "@/features/shell/BackLink";

/** New Product (decision 245), gated `products.create` -- the `products_insert` RLS permission. Only
 * revenue categories are offered as a product's default, since a product is what an invoice line sells. */
export default async function NewProductPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  const { access, membership } = await requirePermission("products.create", {
    entityCode: entity,
  });
  const [categories, baseCurrency, settings, brands, types] = await Promise.all([
    listActiveCategories(membership.entity_id),
    getEntityBaseCurrency(membership.entity_id),
    getSkuSettings(membership.entity_id),
    listSkuMasters("brand", membership.entity_id),
    listSkuMasters("type", membership.entity_id),
  ]);
  const live = <T extends { archived_at: string | null; is_active: boolean }>(rows: readonly T[]) =>
    rows.filter((row) => !row.archived_at && row.is_active);
  const backHref = entity
    ? `/sales/products?entity=${encodeURIComponent(entity)}`
    : "/sales/products";

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <BackLink href={backHref}>← Kembali ke daftar produk</BackLink>
      </p>
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Produk &amp; Jasa</p>
          <h1>Tambah Produk</h1>
        </div>
      </header>
      <section className="dashboard-section">
        <ProductForm
          product={null}
          categories={categories.filter((c) => c.kind === "revenue")}
          baseCurrency={baseCurrency}
          entity={entity}
          brands={live(brands)}
          types={live(types)}
          autoGenerate={settings?.auto_generate ?? false}
          canOverride={can(access, membership.entity_id, "products.sku_override")}
          canAddMasters={can(access, membership.entity_id, "products.sku_settings")}
          canAddCategories={can(access, membership.entity_id, "categories.manage")}
        />
      </section>
    </div>
  );
}
