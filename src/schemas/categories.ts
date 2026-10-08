import { z } from "zod";

/**
 * Read contract for `public.categories` (Step 02 §4, Step 03 §6). No RPC exists for a plain listing of an
 * Entity's categories -- this schema backs a direct RLS-scoped table read (`categories_select` requires only
 * `app_authz.is_member(entity_id)`, `20260920100200_p2_rls_policies.sql`), the same shape
 * `getEntityBaseCurrency` already uses for `public.entities` (decisions 161/167/170/171/172/173). Used by the
 * Budget "set lines" grid's category picker (P13 Part 3h, fifth increment). Deliberately not filtered by
 * `kind`: neither `budget_lines`'s own category FK nor `set_budget_lines` restricts a line's category by
 * kind, so this layer does not invent that restriction either.
 */

export const categoryKindSchema = z.enum([
  "revenue",
  "expense",
  "asset",
  "liability",
  "equity",
  "other",
]);

export const categoryRowSchema = z.object({
  id: z.uuid(),
  entity_id: z.uuid(),
  name: z.string(),
  kind: categoryKindSchema,
  sort_order: z.number().int(),
  /** The withholding / VAT classification the category starts its lines with; empty when it depends on the line. */
  tax_category_key: z.string().nullable().optional(),
});
export const categoryListSchema = z.array(categoryRowSchema);
export type CategoryRow = z.infer<typeof categoryRowSchema>;
