"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { setFlash } from "@/lib/flash";
import { requirePermission } from "@/services/identity/access";
import {
  createProduct,
  ProductConflictError,
  ProductSaveError,
  updateProduct,
} from "@/services/products/products";
import { getSkuSettings } from "@/services/products/sku";
import { describeSkuError } from "@/domain/products/sku";
import { can } from "@/domain/authz/access";
import { productInputSchema } from "@/schemas/products";

/**
 * Server actions behind the Product create/edit form (decision 245). The permission is checked here for a
 * clean error message, and again by the `products_insert`/`products_update` RLS policies, which are the
 * real boundary.
 */

export interface ProductFormState {
  status: "idle" | "error";
  message?: string;
}

function text(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value : "";
}

function readInput(formData: FormData) {
  return productInputSchema.safeParse({
    kind: text(formData, "kind"),
    name: text(formData, "name"),
    // Only an Owner (or a role given `products.sku_override`) may type a SKU, and only by ticking the box.
    sku: formData.get("manual_sku") === "on" ? text(formData, "sku") : "",
    brand_id: text(formData, "brand_id"),
    product_type_id: text(formData, "product_type_id"),
    description: text(formData, "description"),
    unit: text(formData, "unit"),
    default_unit_price: text(formData, "default_unit_price").trim(),
    default_currency: text(formData, "default_currency").trim().toUpperCase(),
    default_category_id: text(formData, "default_category_id"),
    is_active: formData.get("is_active") === "on",
  });
}

function detailHref(productId: string, entity: string): string {
  return entity
    ? `/sales/products/${productId}?entity=${encodeURIComponent(entity)}`
    : `/sales/products/${productId}`;
}

export async function saveProductAction(
  _previous: ProductFormState,
  formData: FormData,
): Promise<ProductFormState> {
  const entity = text(formData, "entity");
  const productId = text(formData, "product_id");
  const parsed = readInput(formData);
  if (!parsed.success) {
    return { status: "error", message: parsed.error.issues[0]?.message ?? "Isian tidak valid." };
  }

  let savedId = productId;
  try {
    if (productId) {
      const { membership } = await requirePermission("products.edit", { entityCode: entity });
      const version = Number(text(formData, "version"));
      await updateProduct(membership.entity_id, productId, version, parsed.data);
    } else {
      const { access, membership } = await requirePermission("products.create", {
        entityCode: entity,
      });
      if (parsed.data.sku && !can(access, membership.entity_id, "products.sku_override")) {
        return { status: "error", message: describeSkuError("SKU_OVERRIDE_FORBIDDEN") };
      }
      if (!parsed.data.sku && parsed.data.kind) {
        const settings = await getSkuSettings(membership.entity_id);
        if (settings?.auto_generate && (!parsed.data.brand_id || !parsed.data.product_type_id)) {
          return {
            status: "error",
            message: "Pilih Brand dan Jenis Produk agar SKU dibuat otomatis.",
          };
        }
      }
      savedId = await createProduct(membership.entity_id, parsed.data);
    }
  } catch (error) {
    if (error instanceof ProductConflictError) return { status: "error", message: error.message };
    if (error instanceof ProductSaveError) {
      return { status: "error", message: describeSkuError(error.message, error.sqlState) };
    }
    return { status: "error", message: "Produk tidak dapat disimpan." };
  }

  revalidatePath("/sales/products");
  revalidatePath(`/sales/products/${savedId}`);
  await setFlash("Produk tersimpan.");
  redirect(detailHref(savedId, entity));
}
