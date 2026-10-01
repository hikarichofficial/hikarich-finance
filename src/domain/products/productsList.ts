import type { ProductKind, ProductRow } from "@/schemas/products";

/** Pure helpers for the Products & Services screens (decision 245). Nothing here calls the database. */

export const PRODUCT_KIND_LABELS: Readonly<Record<ProductKind, string>> = {
  product: "Produk",
  service: "Jasa",
};

export type ProductFilter = "active" | "inactive" | "product" | "service";

export const PRODUCT_FILTER_OPTIONS: readonly {
  readonly value: ProductFilter | undefined;
  readonly label: string;
}[] = [
  { value: undefined, label: "Semua" },
  { value: "active", label: "Aktif" },
  { value: "inactive", label: "Nonaktif" },
  { value: "product", label: "Produk" },
  { value: "service", label: "Jasa" },
];

const FILTERS: ReadonlySet<string> = new Set(["active", "inactive", "product", "service"]);

export function parseProductFilter(value: string | undefined): ProductFilter | undefined {
  return value !== undefined && FILTERS.has(value) ? (value as ProductFilter) : undefined;
}

export function matchesProductFilter(row: ProductRow, filter: ProductFilter | undefined): boolean {
  switch (filter) {
    case undefined:
      return true;
    case "active":
      return row.is_active;
    case "inactive":
      return !row.is_active;
    default:
      return row.kind === filter;
  }
}

export function matchesProductQuery(row: ProductRow, query: string): boolean {
  const q = query.trim().toLowerCase();
  if (!q) return true;
  return (
    row.name.toLowerCase().includes(q) ||
    (row.sku ?? "").toLowerCase().includes(q) ||
    (row.description ?? "").toLowerCase().includes(q)
  );
}

export function filterProducts(
  rows: readonly ProductRow[],
  filter: ProductFilter | undefined,
  query: string,
): ProductRow[] {
  return rows.filter((row) => matchesProductFilter(row, filter) && matchesProductQuery(row, query));
}
