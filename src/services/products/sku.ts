import "server-only";
import { z } from "zod";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import {
  skuHistoryRowSchema,
  skuMasterRowSchema,
  skuPreviewSchema,
  skuSettingsSchema,
  type SkuHistoryRow,
  type SkuMasterKind,
  type SkuMasterRow,
  type SkuPreview,
  type SkuSettings,
} from "@/schemas/sku";

/**
 * The SKU generator (decision 324). Reads go straight to the tables under their RLS read policy
 * (`products.view`); every write goes through a database function that checks `products.sku_settings` (or
 * `products.sku_override`) itself. The numbering and the composition of a SKU live in the database, atomic with
 * the product insert, so nothing here can hand out a number.
 */

/** A refusal from a SKU database function, carrying the raw message for `describeSkuError`. */
export class SkuError extends Error {
  readonly sqlState: string | undefined;
  constructor(message: string, sqlState?: string) {
    super(message);
    this.sqlState = sqlState;
  }
}

const TABLES: Readonly<Record<SkuMasterKind, string>> = {
  brand: "product_brands",
  type: "product_types",
  variant: "product_variants",
};

export async function getSkuSettings(entityId: string): Promise<SkuSettings | null> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("sku_settings")
    .select(
      "entity_id, auto_generate, components, separator, prefix, suffix, empty_handling, empty_placeholder, number_digits, number_start, number_step, number_scope",
    )
    .eq("entity_id", entityId)
    .maybeSingle();
  if (error) throw new Error("Gagal memuat pengaturan SKU.");
  if (!data) return null;
  const parsed = skuSettingsSchema.safeParse(data);
  if (!parsed.success) throw new Error("Pengaturan SKU tidak dikenali.");
  return parsed.data;
}

const MASTER_COLUMNS =
  "id, name, code, description, is_active, archived_at, sort_order, created_at, updated_at, version";

export async function listSkuMasters(
  kind: SkuMasterKind,
  entityId: string,
): Promise<SkuMasterRow[]> {
  const supabase = await createSupabaseServerClient();
  const columns =
    kind === "variant" ? `${MASTER_COLUMNS}, variant_type, validity_days` : MASTER_COLUMNS;
  const { data, error } = await supabase
    .from(TABLES[kind])
    .select(columns)
    .eq("entity_id", entityId)
    .order("sort_order", { ascending: true })
    .order("name", { ascending: true });
  if (error) throw new Error("Gagal memuat data SKU.");
  const parsed = z.array(skuMasterRowSchema).safeParse(data);
  if (!parsed.success) throw new Error("Data SKU tidak dikenali.");
  return parsed.data;
}

/** The ids of brands / types / variants that any product already uses (those can only be archived). */
export async function listUsedSkuMasterIds(entityId: string): Promise<Set<string>> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("products")
    .select("brand_id, product_type_id, variant_id")
    .eq("entity_id", entityId)
    .or("brand_id.not.is.null,product_type_id.not.is.null,variant_id.not.is.null");
  if (error) return new Set();
  const used = new Set<string>();
  for (const row of data ?? []) {
    for (const key of ["brand_id", "product_type_id", "variant_id"] as const) {
      const value = row[key];
      if (typeof value === "string") used.add(value);
    }
  }
  return used;
}

export async function listSkuHistory(
  entityId: string,
  options: { productId?: string; limit?: number } = {},
): Promise<(SkuHistoryRow & { product_name: string | null })[]> {
  const supabase = await createSupabaseServerClient();
  let query = supabase
    .from("product_sku_history")
    .select("id, product_id, old_sku, new_sku, source, reason, changed_at")
    .eq("entity_id", entityId)
    .order("changed_at", { ascending: false })
    .limit(options.limit ?? 100);
  if (options.productId) query = query.eq("product_id", options.productId);
  const { data, error } = await query;
  if (error) throw new Error("Gagal memuat riwayat SKU.");
  const parsed = z.array(skuHistoryRowSchema).safeParse(data);
  if (!parsed.success) throw new Error("Riwayat SKU tidak dikenali.");
  const ids = [...new Set(parsed.data.map((row) => row.product_id))];
  const names = new Map<string, string>();
  if (ids.length > 0) {
    const { data: products } = await supabase.from("products").select("id, name").in("id", ids);
    for (const p of products ?? []) names.set(String(p.id), String(p.name));
  }
  return parsed.data.map((row) => ({ ...row, product_name: names.get(row.product_id) ?? null }));
}

async function rpc(name: string, args: Record<string, unknown>): Promise<unknown> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw new SkuError(error.message, error.code);
  return data;
}

export async function previewProductSku(
  entityId: string,
  input: { brandId?: string; typeId?: string; variantId?: string; parentId?: string },
): Promise<SkuPreview> {
  const data = await rpc("preview_product_sku", {
    p_entity: entityId,
    p_brand: input.brandId || null,
    p_type: input.typeId || null,
    p_variant: input.variantId || null,
    p_parent: input.parentId || null,
  });
  const parsed = skuPreviewSchema.safeParse(data);
  if (!parsed.success) throw new Error("Pratinjau SKU tidak dikenali.");
  return parsed.data;
}

export async function saveSkuMaster(input: {
  kind: SkuMasterKind;
  entityId: string;
  id: string | null;
  name: string;
  code: string;
  description: string | null;
  sortOrder: number;
  variantType?: string;
  validityDays?: number | null;
  expectedVersion?: number | null;
}): Promise<string> {
  const data = await rpc("save_sku_master", {
    p_kind: input.kind,
    p_entity: input.entityId,
    p_id: input.id,
    p_name: input.name,
    p_code: input.code,
    p_description: input.description,
    p_sort: input.sortOrder,
    p_variant_type: input.variantType ?? "validity",
    p_validity_days: input.validityDays ?? null,
    p_expected_version: input.expectedVersion ?? null,
  });
  return z.uuid().parse(data);
}

export async function setSkuMasterState(
  kind: SkuMasterKind,
  entityId: string,
  id: string,
  action: "activate" | "deactivate" | "archive" | "restore" | "delete",
): Promise<void> {
  await rpc("set_sku_master_state", {
    p_kind: kind,
    p_entity: entityId,
    p_id: id,
    p_action: action,
  });
}

export async function saveSkuSettings(
  entityId: string,
  s: Omit<SkuSettings, "entity_id">,
): Promise<void> {
  await rpc("save_sku_settings", {
    p_entity: entityId,
    p_auto: s.auto_generate,
    p_components: s.components,
    p_separator: s.separator,
    p_prefix: s.prefix,
    p_suffix: s.suffix,
    p_empty_handling: s.empty_handling,
    p_empty_placeholder: s.empty_placeholder,
    p_digits: s.number_digits,
    p_start: s.number_start,
    p_step: s.number_step,
    p_scope: s.number_scope,
  });
}

export async function setProductSku(productId: string, sku: string, reason: string): Promise<void> {
  await rpc("set_product_sku", { p_product: productId, p_sku: sku, p_reason: reason || null });
}

export async function productUsedOnDocuments(productId: string): Promise<boolean> {
  try {
    return z.boolean().parse(await rpc("product_used_on_documents", { p_product: productId }));
  } catch {
    return false;
  }
}

/** The variants (sellable rows) that belong to one main product. */
export async function listProductVariants(
  entityId: string,
  parentId: string,
): Promise<
  {
    id: string;
    name: string;
    sku: string | null;
    variant_id: string | null;
    price: string | null;
    is_active: boolean;
  }[]
> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("products")
    .select("id, name, sku, variant_id, default_unit_price::text, is_active")
    .eq("entity_id", entityId)
    .eq("parent_product_id", parentId)
    .order("created_at", { ascending: true });
  if (error) return [];
  return (data ?? []).map((row) => ({
    id: String(row.id),
    name: String(row.name),
    sku: row.sku === null ? null : String(row.sku),
    variant_id: row.variant_id === null ? null : String(row.variant_id),
    price: row.default_unit_price === null ? null : String(row.default_unit_price),
    is_active: Boolean(row.is_active),
  }));
}
