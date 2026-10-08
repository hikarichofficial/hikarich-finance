"use server";

import { revalidatePath } from "next/cache";
import { AuthzError, describeAuthzError } from "@/domain/authz/errors";
import { describeSkuError, SKU_PARTS } from "@/domain/products/sku";
import { requirePermission } from "@/services/identity/access";
import { getProduct } from "@/services/products/products";
import {
  previewProductSku,
  saveSkuMaster,
  listSkuMasters,
  saveSkuSettings,
  setProductSku,
  setSkuMasterState,
  SkuError,
} from "@/services/products/sku";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { moneyTextSchema } from "@/schemas/accounting";
import { skuComponentSchema, skuMasterKindSchema, type SkuPreview } from "@/schemas/sku";
import type { QuickCreateSkuMasterState } from "./skuActionsState";
import { z } from "zod";

/**
 * Server actions of the SKU generator (decision 324). Each checks the permission for a clean message, and the
 * database function re-checks it (`products.sku_settings`, or `products.sku_override` for a hand-typed SKU).
 */

export interface SkuActionState {
  status: "idle" | "error" | "ok";
  message?: string;
}

function text(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function failure(error: unknown): SkuActionState {
  if (error instanceof AuthzError) return { status: "error", message: describeAuthzError(error) };
  if (error instanceof SkuError) {
    return { status: "error", message: describeSkuError(error.message, error.sqlState) };
  }
  if (error instanceof z.ZodError) {
    return { status: "error", message: "Isian tidak valid. Periksa kembali." };
  }
  return { status: "error", message: "Perubahan SKU tidak dapat disimpan." };
}

function refresh() {
  revalidatePath("/admin/sku");
  revalidatePath("/sales/products");
}

export async function saveSkuSettingsAction(
  _previous: SkuActionState,
  formData: FormData,
): Promise<SkuActionState> {
  try {
    const { membership } = await requirePermission("products.sku_settings", {
      entityCode: text(formData, "entity"),
    });
    const components = z
      .array(skuComponentSchema)
      .length(4)
      .parse(JSON.parse(text(formData, "components") || "[]"));
    if (new Set(components.map((c) => c.key)).size !== SKU_PARTS.length) {
      return { status: "error", message: "Setiap bagian SKU harus muncul satu kali." };
    }
    await saveSkuSettings(membership.entity_id, {
      auto_generate: formData.get("auto_generate") === "on",
      components,
      separator: formData.get("separator") === null ? "-" : String(formData.get("separator")),
      prefix: text(formData, "prefix"),
      suffix: text(formData, "suffix"),
      empty_handling: text(formData, "empty_handling") === "placeholder" ? "placeholder" : "skip",
      empty_placeholder: text(formData, "empty_placeholder") || "XX",
      number_digits: Number(text(formData, "number_digits") || 3),
      number_start: Number(text(formData, "number_start") || 1),
      number_step: Number(text(formData, "number_step") || 1),
      number_scope: z
        .enum(["global", "brand", "brand_type"])
        .parse(text(formData, "number_scope") || "brand_type"),
    });
  } catch (error) {
    return failure(error);
  }
  refresh();
  return { status: "ok", message: "Format SKU tersimpan. Berlaku untuk SKU baru." };
}

export async function saveSkuMasterAction(
  _previous: SkuActionState,
  formData: FormData,
): Promise<SkuActionState> {
  try {
    const kind = skuMasterKindSchema.parse(text(formData, "kind"));
    const { membership } = await requirePermission("products.sku_settings", {
      entityCode: text(formData, "entity"),
    });
    const validity = text(formData, "validity_days");
    await saveSkuMaster({
      kind,
      entityId: membership.entity_id,
      id: text(formData, "id") || null,
      name: text(formData, "name"),
      code: text(formData, "code").toUpperCase(),
      description: text(formData, "description") || null,
      sortOrder: Number(text(formData, "sort_order") || 0),
      variantType: text(formData, "variant_type") || "validity",
      validityDays: validity === "" ? null : Number(validity),
      expectedVersion: text(formData, "version") === "" ? null : Number(text(formData, "version")),
    });
  } catch (error) {
    return failure(error);
  }
  refresh();
  return { status: "ok", message: "Tersimpan." };
}

export async function skuMasterStateAction(
  _previous: SkuActionState,
  formData: FormData,
): Promise<SkuActionState> {
  try {
    const kind = skuMasterKindSchema.parse(text(formData, "kind"));
    const action = z
      .enum(["activate", "deactivate", "archive", "restore", "delete"])
      .parse(text(formData, "action"));
    const { membership } = await requirePermission("products.sku_settings", {
      entityCode: text(formData, "entity"),
    });
    await setSkuMasterState(kind, membership.entity_id, text(formData, "id"), action);
  } catch (error) {
    return failure(error);
  }
  refresh();
  return { status: "ok", message: "Tersimpan." };
}

/** Live SKU preview for the product form: read-only, never takes a number. */
export async function previewSkuAction(input: {
  entity: string;
  brandId: string;
  typeId: string;
  variantId?: string;
  parentId?: string;
}): Promise<SkuPreview> {
  try {
    const { membership } = await requirePermission("products.view", { entityCode: input.entity });
    return await previewProductSku(membership.entity_id, input);
  } catch {
    return { error: "preview" };
  }
}

/** Owner / `products.sku_override`: change the SKU of an existing product by hand, with an optional reason. */
export async function setProductSkuAction(
  _previous: SkuActionState,
  formData: FormData,
): Promise<SkuActionState> {
  try {
    await requirePermission("products.sku_override", { entityCode: text(formData, "entity") });
    const sku = text(formData, "sku");
    if (!sku) return { status: "error", message: "SKU wajib diisi." };
    await setProductSku(text(formData, "product_id"), sku, text(formData, "reason"));
  } catch (error) {
    return failure(error);
  }
  revalidatePath("/sales/products");
  return { status: "ok", message: "SKU diubah. Dokumen lama tetap memakai SKU sebelumnya." };
}

/** Adds a variant (its own sellable row with its own SKU, price and status) to a main product. */
export async function addVariantAction(
  _previous: SkuActionState,
  formData: FormData,
): Promise<SkuActionState> {
  try {
    const { membership } = await requirePermission("products.create", {
      entityCode: text(formData, "entity"),
    });
    const parent = await getProduct(membership.entity_id, text(formData, "parent_id"));
    if (!parent || parent.parent_product_id) {
      return { status: "error", message: "Produk utama tidak ditemukan." };
    }
    const variantId = text(formData, "variant_id");
    const supabase = await createSupabaseServerClient();
    const { data: variant } = await supabase
      .from("product_variants")
      .select("name")
      .eq("entity_id", membership.entity_id)
      .eq("id", variantId)
      .maybeSingle();
    if (!variant) return { status: "error", message: "Pilih variant." };
    const price = text(formData, "price");
    if (price !== "" && !moneyTextSchema.safeParse(price).success) {
      return { status: "error", message: "Harga harus berupa angka (maks. 4 desimal)." };
    }
    const { error } = await supabase.from("products").insert({
      entity_id: membership.entity_id,
      kind: parent.kind,
      name: `${parent.name} – ${String(variant.name)}`,
      description: parent.description,
      unit: parent.unit,
      default_unit_price: price === "" ? parent.default_unit_price : price,
      default_currency: parent.default_currency,
      default_category_id: parent.default_category_id,
      is_active: true,
      parent_product_id: parent.id,
      variant_id: variantId,
    });
    if (error) throw new SkuError(error.message, error.code);
  } catch (error) {
    return failure(error);
  }
  revalidatePath("/sales/products");
  return { status: "ok", message: "Variant ditambahkan." };
}

/** Add a brand, product type or variant from inside the product form (decision 351): the new row is handed back
 * so the field can select it in place, and nothing redirects. Same permission as the SKU admin screen. */
export async function quickCreateSkuMasterAction(
  _previous: QuickCreateSkuMasterState,
  formData: FormData,
): Promise<QuickCreateSkuMasterState> {
  try {
    const kind = skuMasterKindSchema.parse(text(formData, "kind"));
    const { membership } = await requirePermission("products.sku_settings", {
      entityCode: text(formData, "entity"),
    });
    const name = text(formData, "name");
    const code = text(formData, "code").toUpperCase();
    if (name === "" || name.length > 120) {
      return { status: "error", message: "Isi nama (maksimal 120 karakter)." };
    }
    if (!/^[A-Z0-9]{1,12}$/.test(code)) {
      return { status: "error", message: "Kode hanya huruf dan angka, 1 sampai 12 karakter." };
    }
    const existing = await listSkuMasters(kind, membership.entity_id);
    const nextSort = existing.reduce((max, row) => Math.max(max, row.sort_order), 0) + 10;
    const validity = text(formData, "validity_days");
    const id = await saveSkuMaster({
      kind,
      entityId: membership.entity_id,
      id: null,
      name,
      code,
      description: null,
      sortOrder: nextSort,
      variantType: text(formData, "variant_type") || "validity",
      validityDays: validity === "" ? null : Number(validity),
      expectedVersion: null,
    });
    refresh();
    return { status: "ok", item: { id, name, code } };
  } catch (error) {
    const failed = failure(error);
    return { status: "error", message: failed.message };
  }
}
