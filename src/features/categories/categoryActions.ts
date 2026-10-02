"use server";

import { revalidatePath } from "next/cache";
import { requirePermission } from "@/services/identity/access";
import {
  createCategory,
  setCategoryAccount,
  updateCategory,
} from "@/services/accounting/categories";

/** Server actions behind the Categories screen (decision 262). `categories` takes browser writes under RLS
 * (`categories.manage`); the tax key is one of the database's catalog keys or empty. */

export interface CategoryActionState {
  status: "idle" | "ok" | "error";
  message?: string;
}

const KINDS = ["revenue", "expense", "asset", "liability", "equity", "other"];

function text(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

export async function createCategoryAction(
  _previous: CategoryActionState,
  formData: FormData,
): Promise<CategoryActionState> {
  const name = text(formData, "name");
  const kind = text(formData, "kind");
  if (name.length < 1 || name.length > 120 || !KINDS.includes(kind)) {
    return { status: "error", message: "Isi nama kategori (maksimal 120 karakter) dan jenisnya." };
  }
  try {
    const { membership } = await requirePermission("categories.manage", {
      entityCode: text(formData, "entity"),
    });
    await createCategory({
      entity_id: membership.entity_id,
      name,
      kind,
      tax_category_key: text(formData, "tax_category_key") || null,
    });
  } catch {
    return {
      status: "error",
      message:
        "Kategori tidak dapat disimpan. Mungkin namanya sudah dipakai, atau Anda tidak berwenang.",
    };
  }
  revalidatePath("/accounting/categories");
  return { status: "ok", message: "Kategori tersimpan." };
}

export async function updateCategoryAction(
  _previous: CategoryActionState,
  formData: FormData,
): Promise<CategoryActionState> {
  try {
    await requirePermission("categories.manage", { entityCode: text(formData, "entity") });
    await updateCategory({
      id: text(formData, "id"),
      tax_category_key: text(formData, "tax_category_key") || null,
      is_active: text(formData, "is_active") === "on",
    });
  } catch {
    return { status: "error", message: "Perubahan tidak dapat disimpan." };
  }
  revalidatePath("/accounting/categories");
  return { status: "ok", message: "Tersimpan." };
}

/** Map a category to the ledger account it posts to from a date on (decision 265). */
export async function setCategoryAccountAction(
  _previous: CategoryActionState,
  formData: FormData,
): Promise<CategoryActionState> {
  try {
    const { membership } = await requirePermission("categories.manage", {
      entityCode: text(formData, "entity"),
    });
    await setCategoryAccount({
      entity_id: membership.entity_id,
      category_id: text(formData, "category_id"),
      account_id: text(formData, "account_id") || null,
      effective_from: text(formData, "effective_from"),
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : "";
    const match = /(?:INVALID|CONFLICT|FORBIDDEN):\s*([\s\S]+)$/.exec(message);
    return {
      status: "error",
      message: match?.[1]
        ? `Akun tidak dapat disimpan (${match[1].trim()})`
        : "Akun tidak dapat disimpan.",
    };
  }
  revalidatePath("/accounting/categories");
  return { status: "ok", message: "Tersimpan." };
}
