import Link from "next/link";
import { notFound } from "next/navigation";
import { requirePermission } from "@/services/identity/access";
import { getProduct } from "@/services/products/products";
import { listActiveCategories } from "@/services/accounting/categories";
import { getEntityBaseCurrency } from "@/services/accounting/ledger";
import { ProductForm } from "@/features/products/ProductForm";

/** Ubah Produk (task 95): the edit form on its own page, apart from the read-only detail. Gated
 * `products.edit` -- the permission the `products_update` RLS policy itself checks. Saving returns to the detail. */
export default async function EditProductPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string }>;
}) {
  const { id } = await params;
  const { entity } = await searchParams;
  const { membership } = await requirePermission("products.edit", { entityCode: entity });
  const [product, categories, baseCurrency] = await Promise.all([
    getProduct(membership.entity_id, id),
    listActiveCategories(membership.entity_id),
    getEntityBaseCurrency(membership.entity_id),
  ]);
  if (!product) notFound();
  const backHref = entity
    ? `/sales/products/${id}?entity=${encodeURIComponent(entity)}`
    : `/sales/products/${id}`;

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={backHref}>← Kembali ke detail produk</Link>
      </p>
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Produk &amp; Jasa</p>
          <h1>Ubah {product.name}</h1>
        </div>
      </header>
      <section className="dashboard-section">
        <ProductForm
          product={product}
          categories={categories.filter((c) => c.kind === "revenue")}
          baseCurrency={baseCurrency}
          entity={entity}
        />
      </section>
    </div>
  );
}
