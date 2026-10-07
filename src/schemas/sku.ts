import { z } from "zod";

/** The SKU generator's rows (decision 324), read straight from the tables under their RLS read policies. */
export const skuComponentSchema = z.object({
  key: z.enum(["brand", "type", "seq", "variant"]),
  enabled: z.boolean(),
  required: z.boolean(),
});

export const skuSettingsSchema = z.object({
  entity_id: z.uuid(),
  auto_generate: z.boolean(),
  components: z.array(skuComponentSchema).length(4),
  separator: z.string(),
  prefix: z.string(),
  suffix: z.string(),
  empty_handling: z.enum(["skip", "placeholder"]),
  empty_placeholder: z.string(),
  number_digits: z.number().int(),
  number_start: z.number().int(),
  number_step: z.number().int(),
  number_scope: z.enum(["global", "brand", "brand_type"]),
});
export type SkuSettings = z.infer<typeof skuSettingsSchema>;

export const skuMasterKindSchema = z.enum(["brand", "type", "variant"]);
export type SkuMasterKind = z.infer<typeof skuMasterKindSchema>;

export const skuMasterRowSchema = z.object({
  id: z.uuid(),
  name: z.string(),
  code: z.string(),
  description: z.string().nullable(),
  is_active: z.boolean(),
  archived_at: z.string().nullable(),
  sort_order: z.number().int(),
  created_at: z.string(),
  updated_at: z.string(),
  version: z.number().int(),
  // variants only
  variant_type: z.string().optional(),
  validity_days: z.number().int().nullable().optional(),
});
export type SkuMasterRow = z.infer<typeof skuMasterRowSchema>;

export const skuHistoryRowSchema = z.object({
  id: z.uuid(),
  product_id: z.uuid(),
  old_sku: z.string().nullable(),
  new_sku: z.string().nullable(),
  source: z.enum(["generated", "manual", "changed"]),
  reason: z.string().nullable(),
  changed_at: z.string(),
});
export type SkuHistoryRow = z.infer<typeof skuHistoryRowSchema>;

export const skuPreviewSchema = z.object({
  auto: z.boolean().optional(),
  base_sku: z.string().nullable().optional(),
  sku: z.string().nullable().optional(),
  number: z.number().int().nullable().optional(),
  error: z.string().optional(),
});
export type SkuPreview = z.infer<typeof skuPreviewSchema>;
