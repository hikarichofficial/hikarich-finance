import { z } from "zod";

/**
 * Settings screen rows (decision 243), each read directly from its own table under that table's existing
 * RLS policy: `entities`/`entity_profiles` (membership), `numbering_sequences`/`approval_rules`/
 * `entity_settings` (`settings.view`), `roles` (any active user).
 */
export const entitySummaryRowSchema = z.object({
  id: z.uuid(),
  code: z.string(),
  entity_type: z.enum(["company", "personal", "other"]),
  legal_name: z.string(),
  brand_name: z.string().nullable(),
  base_currency: z.string(),
  timezone: z.string(),
  fiscal_year_start_month: z.number().int().min(1).max(12),
  status: z.enum(["active", "disabled"]),
});
export type EntitySummaryRow = z.infer<typeof entitySummaryRowSchema>;

export const entityProfileRowSchema = z.object({
  address_line: z.string().nullable(),
  city: z.string().nullable(),
  province: z.string().nullable(),
  postal_code: z.string().nullable(),
  country_code: z.string(),
  contact_email: z.string().nullable(),
  contact_phone: z.string().nullable(),
  website: z.string().nullable(),
});
export type EntityProfileRow = z.infer<typeof entityProfileRowSchema>;

export const numberingScopeSchema = z.enum([
  "invoice",
  "payment_receipt",
  "refund_receipt",
  "bill",
  "journal",
  "other",
]);
export type NumberingScope = z.infer<typeof numberingScopeSchema>;

export const numberingSequenceRowSchema = z.object({
  id: z.uuid(),
  scope: numberingScopeSchema,
  prefix: z.string(),
  separator: z.enum(["-", "/", ".", ""]),
  include_year: z.boolean(),
  padding: z.number().int().min(1).max(10),
  reset_policy: z.enum(["yearly", "never"]),
  is_active: z.boolean(),
});
export const numberingSequenceListSchema = z.array(numberingSequenceRowSchema);
export type NumberingSequenceRow = z.infer<typeof numberingSequenceRowSchema>;

export const approvalRuleRowSchema = z.object({
  id: z.uuid(),
  module: z.string(),
  action: z.string(),
  min_amount: z.union([z.string(), z.number()]).nullable(),
  requires_approval: z.boolean(),
  approver_role_id: z.uuid().nullable(),
  allow_self_approval: z.boolean(),
  effective_from: z.string(),
  effective_to: z.string().nullable(),
});
export const approvalRuleListSchema = z.array(approvalRuleRowSchema);
export type ApprovalRuleRow = z.infer<typeof approvalRuleRowSchema>;

export const roleNameRowSchema = z.object({ id: z.uuid(), name: z.string() });
export const roleNameListSchema = z.array(roleNameRowSchema);

export const entitySettingRowSchema = z.object({
  setting_key: z.string(),
  setting_value: z.unknown(),
});
export const entitySettingListSchema = z.array(entitySettingRowSchema);
export type EntitySettingRow = z.infer<typeof entitySettingRowSchema>;
