import "server-only";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { uuidResultSchema } from "@/schemas/accounting";
import { categoryListSchema, type CategoryRow } from "@/schemas/categories";

/**
 * Direct RLS-scoped read of `public.categories` (Step 02 §4, Step 03 §6, P13 Part 3h fifth increment) --
 * no RPC exists for a plain active-category listing, and none is needed: `categories_select` already scopes
 * to Entity membership alone (`20260920100200_p2_rls_policies.sql`), so a direct authenticated read is safe
 * and sufficient, the exact precedent `getEntityBaseCurrency` already set for `public.entities`
 * (`src/services/planning/planning.ts`, decisions 161/167/170/171/172/173). Not filtered by `kind` -- see
 * `@/schemas/categories`'s own note.
 */
export async function listActiveCategories(entityId: string): Promise<CategoryRow[]> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("categories")
    .select("id, entity_id, name, kind, sort_order")
    .eq("entity_id", uuidResultSchema.parse(entityId))
    .eq("is_active", true)
    .order("sort_order")
    .order("name");
  if (error) throw new Error("Gagal memuat daftar kategori.");
  const parsed = categoryListSchema.safeParse(data);
  if (!parsed.success) throw new Error("Respons daftar kategori tidak dikenali.");
  return parsed.data;
}
