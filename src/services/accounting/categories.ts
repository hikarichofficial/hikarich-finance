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
    .select("id, entity_id, name, kind, sort_order, tax_category_key")
    .eq("entity_id", uuidResultSchema.parse(entityId))
    .eq("is_active", true)
    .order("sort_order")
    .order("name");
  if (error) throw new Error("Gagal memuat daftar kategori.");
  const parsed = categoryListSchema.safeParse(data);
  if (!parsed.success) throw new Error("Respons daftar kategori tidak dikenali.");
  return parsed.data;
}

export interface CategoryAdminRow {
  id: string;
  name: string;
  kind: string;
  tax_category_key: string | null;
  personal_tax_role: string | null;
  is_active: boolean;
  version: number;
}

/** Every category of the Entity with its tax mapping, for the Categories screen (decision 262). */
export async function listCategoriesForAdmin(entityId: string): Promise<CategoryAdminRow[]> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("categories")
    .select("id, name, kind, tax_category_key, personal_tax_role, is_active, version")
    .eq("entity_id", uuidResultSchema.parse(entityId))
    .order("kind")
    .order("name");
  if (error) throw new Error("Gagal memuat daftar kategori.");
  return (data ?? []) as CategoryAdminRow[];
}

/** `categories` allows browser writes under RLS (`categories.manage`, P2): a plain insert, no RPC. */
export async function createCategory(input: {
  entity_id: string;
  name: string;
  kind: string;
  tax_category_key: string | null;
  personal_tax_role?: string | null;
}): Promise<{
  id: string;
  name: string;
  kind: string;
  personal_tax_role: string | null;
}> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("categories")
    .insert({
      entity_id: uuidResultSchema.parse(input.entity_id),
      name: input.name,
      kind: input.kind,
      tax_category_key: input.tax_category_key,
      personal_tax_role: input.personal_tax_role ?? null,
    })
    .select("id, name, kind, personal_tax_role")
    .single();
  if (error) throw new Error(error.message);
  return data as { id: string; name: string; kind: string; personal_tax_role: string | null };
}

export async function updateCategory(input: {
  id: string;
  /** Left out (undefined) when the form does not carry it, so the stored value stays as it is. */
  tax_category_key?: string | null;
  /** Only a Personal book carries this tag (decision 365). */
  personal_tax_role?: string | null;
  is_active: boolean;
}): Promise<void> {
  const supabase = await createSupabaseServerClient();
  const changes: Record<string, unknown> = { is_active: input.is_active };
  if (input.tax_category_key !== undefined) changes.tax_category_key = input.tax_category_key;
  if (input.personal_tax_role !== undefined) changes.personal_tax_role = input.personal_tax_role;
  const { error } = await supabase
    .from("categories")
    .update(changes)
    .eq("id", uuidResultSchema.parse(input.id));
  if (error) throw new Error(error.message);
}

/** The account each category posts to today (context "sales" for revenue, "purchases" for expense), by a
 * direct RLS-governed read (`accounting.view`); empty when the caller cannot see mappings. Decision 265. */
export async function listCurrentCategoryAccounts(
  entityId: string,
  today: string,
): Promise<Map<string, string>> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("category_account_mappings")
    .select(
      "category_id, context, debit_ledger_account_id, credit_ledger_account_id, effective_from, effective_to",
    )
    .eq("entity_id", uuidResultSchema.parse(entityId))
    .in("context", ["sales", "purchases"])
    .lte("effective_from", today);
  const map = new Map<string, string>();
  if (error || !data) return map;
  for (const row of data as {
    category_id: string;
    debit_ledger_account_id: string | null;
    credit_ledger_account_id: string | null;
    effective_to: string | null;
  }[]) {
    if (row.effective_to !== null && row.effective_to < today) continue;
    const account = row.credit_ledger_account_id ?? row.debit_ledger_account_id;
    if (account) map.set(row.category_id, account);
  }
  return map;
}

/** `set_category_account`: the mapping starts on the given date; `null` ends it (decision 265). */
export async function setCategoryAccount(input: {
  entity_id: string;
  category_id: string;
  account_id: string | null;
  effective_from: string;
}): Promise<void> {
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.rpc("set_category_account", {
    p_entity: uuidResultSchema.parse(input.entity_id),
    p_category: uuidResultSchema.parse(input.category_id),
    p_account: input.account_id ? uuidResultSchema.parse(input.account_id) : null,
    p_effective_from: input.effective_from,
  });
  if (error) throw new Error(error.message);
}
