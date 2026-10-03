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
  version: z.number().int().positive(),
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
  "bill_payment",
  "expense",
  "journal",
  "transfer",
  "tax_payment",
  "asset",
  "loan",
  "loan_payment",
  "other_receivable",
  "other_payable",
  "obligation_settlement",
  "equity",
  "employee",
  "payroll_run",
  "payroll_payment",
  "payslip",
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

/** Input of `update_entity_time_settings` (decision 248). The database validates the timezone name,
 * the month range, the reason and the "fiscal year locked once periods exist" rule itself. */
export const entityTimeSettingsInputSchema = z.object({
  entity_id: z.uuid(),
  timezone: z.string().trim().min(1).max(64),
  fiscal_year_start_month: z.coerce.number().int().min(1).max(12),
  expected_version: z.coerce.number().int().positive(),
  reason: z.string().trim().min(5).max(500),
});
export type EntityTimeSettingsInput = z.infer<typeof entityTimeSettingsInputSchema>;

/** Input of `update_entity_identity` (decision 272): the Entity's names, address and contact details.
 * Empty text clears an optional field; the database validates lengths and the email again. */
export const entityIdentityInputSchema = z.object({
  entity_id: z.uuid(),
  legal_name: z.string().trim().min(1).max(200),
  brand_name: z.string().trim().max(200),
  address_line: z.string().trim().max(300),
  city: z.string().trim().max(100),
  province: z.string().trim().max(100),
  postal_code: z.string().trim().max(20),
  contact_email: z.string().trim().max(200),
  contact_phone: z.string().trim().max(40),
  website: z.string().trim().max(200),
  expected_version: z.coerce.number().int().positive(),
});
export type EntityIdentityInput = z.infer<typeof entityIdentityInputSchema>;

/** Input of `create_entity` (decision 276): an OWNER adds an Entity. The database validates again. */
export const createEntityInputSchema = z.object({
  code: z
    .string()
    .trim()
    .toLowerCase()
    .regex(/^[a-z][a-z0-9_-]{1,30}$/),
  entity_type: z.enum(["company", "personal"]),
  legal_name: z.string().trim().min(1).max(200),
  brand_name: z.string().trim().max(200),
});
export type CreateEntityInput = z.infer<typeof createEntityInputSchema>;
