import Link from "next/link";
import { requirePermission } from "@/services/identity/access";
import { listActiveCategories } from "@/services/accounting/categories";
import { getEntityBaseCurrency } from "@/services/accounting/ledger";
import { ProductForm } from "@/features/products/ProductForm";

/** New Product (decision 245), gated `products.create` -- the `products_insert` RLS permission. Only
 * revenue categories are offered as a product's default, since a product is what an invoice line sells. */
export default async function NewProductPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  const { membership } = await requirePermission("products.create", { entityCode: entity });
  const [categories, baseCurrency] = await Promise.all([
    listActiveCategories(membership.entity_id),
    getEntityBaseCurrency(membership.entity_id),
  ]);
  const backHref = entity
    ? `/sales/products?entity=${encodeURIComponent(entity)}`
    : "/sales/products";

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={backHref}>← Kembali ke daftar produk</Link>
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
        />
      </section>
    </div>
  );
}
