import "server-only";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import {
  productListSchema,
  productRowSchema,
  type ProductInput,
  type ProductRow,
} from "@/schemas/products";

/**
 * Products & Services (decision 245). Reads and writes go straight to `public.products`; its P2 RLS
 * policies decide every row the caller may see (`products.view`), insert (`products.create`) or update
 * (`products.edit`), so no check here can be weaker than the database's own. Updates carry the row's
 * `version` and match on it, so two people editing the same product cannot silently overwrite each other.
 */

const PRODUCT_COLUMNS =
  "id, entity_id, kind, sku, name, description, unit, default_unit_price::text, default_currency, default_category_id, is_active, version, brand_id, product_type_id, sku_number, parent_product_id, variant_id, sku_manual";

export class ProductConflictError extends Error {
  constructor() {
    super("Produk telah diubah orang lain. Muat ulang halaman lalu coba lagi.");
  }
}

export async function listProducts(entityId: string): Promise<ProductRow[]> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("products")
    .select(PRODUCT_COLUMNS)
    .eq("entity_id", entityId)
    .order("name", { ascending: true });
  if (error) throw new Error("Gagal memuat produk.");
  const parsed = productListSchema.safeParse(data);
  if (!parsed.success) throw new Error("Respons produk tidak dikenali.");
  return parsed.data;
}

export async function getProduct(entityId: string, productId: string): Promise<ProductRow | null> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("products")
    .select(PRODUCT_COLUMNS)
    .eq("entity_id", entityId)
    .eq("id", productId)
    .maybeSingle();
  if (error) throw new Error("Gagal memuat produk.");
  if (!data) return null;
  const parsed = productRowSchema.safeParse(data);
  if (!parsed.success) throw new Error("Respons produk tidak dikenali.");
  return parsed.data;
}

/** Returns the new product's id. */
export async function createProduct(entityId: string, input: ProductInput): Promise<string> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("products")
    .insert({ entity_id: entityId, ...input })
    .select("id")
    .single();
  if (error || !data) throw new ProductSaveError(error?.message ?? "", error?.code);
  return String(data.id);
}

/** A refusal from the database while saving a product (duplicate SKU, no right to type a SKU, ...). */
export class ProductSaveError extends Error {
  readonly sqlState: string | undefined;
  constructor(message: string, sqlState?: string) {
    super(message);
    this.sqlState = sqlState;
  }
}

export async function updateProduct(
  entityId: string,
  productId: string,
  expectedVersion: number,
  input: ProductInput,
): Promise<void> {
  const supabase = await createSupabaseServerClient();
  // The SKU, brand and type are never changed by this form: a SKU changes only through `set_product_sku`
  // (Owner), brand and type stay as they were when the SKU was made (decision 324).
  const { sku: _sku, brand_id: _brand, product_type_id: _type, ...editable } = input;
  void _sku;
  void _brand;
  void _type;
  const { data, error } = await supabase
    .from("products")
    .update(editable)
    .eq("entity_id", entityId)
    .eq("id", productId)
    .eq("version", expectedVersion)
    .select("id");
  if (error) throw new ProductSaveError(error.message, error.code);
  if (!data || data.length === 0) throw new ProductConflictError();
}
