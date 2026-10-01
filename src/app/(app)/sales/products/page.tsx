import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import { listProducts } from "@/services/products/products";
import { getEntityBaseCurrency } from "@/services/accounting/ledger";
import { filterProducts, parseProductFilter } from "@/domain/products/productsList";
import { ProductsListScreen } from "@/features/products/ProductsListScreen";

/** Products & Services (Step 09 §3, decision 245). Gated `products.view`, the `products_select` RLS
 * permission and `navigation.ts`'s own declared one. */
export default async function ProductsListPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; filter?: string; q?: string }>;
}) {
  const { entity, filter, q } = await searchParams;
  const { access, membership } = await requirePermission("products.view", { entityCode: entity });
  const activeFilter = parseProductFilter(filter);
  const query = q ?? "";

  const [rows, baseCurrency] = await Promise.all([
    listProducts(membership.entity_id),
    getEntityBaseCurrency(membership.entity_id),
  ]);

  return (
    <ProductsListScreen
      rows={filterProducts(rows, activeFilter, query)}
      activeFilter={activeFilter}
      query={query}
      entity={entity}
      baseCurrency={baseCurrency}
      canCreate={can(access, membership.entity_id, "products.create")}
    />
  );
}
