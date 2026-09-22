import { z } from "zod";
import {
  idempotencyKeySchema,
  isoDateSchema,
  moneyTextSchema,
  signedDecimalTextSchema,
} from "@/schemas/accounting";

/**
 * Input and output contracts of the planning RPCs (P10, Step 01 #22/#23/#26, Step 15 Phase 10): recurring
 * rules (invoice/bill/expense templates and their generated occurrences) and budgets/revenue targets. Money
 * is exact decimal text; the database owns every rule (idempotent generation, pause/resume/end, who may
 * edit vs. run), computes Actual/Committed on read and decides authorization (`planning.*`). This layer
 * validates the input shape and what comes back; it holds no business rule of its own. Labels live in
 * `@/domain/planning`.
 */

export const recurringKindSchema = z.enum(["invoice", "bill", "expense"]);
export const recurringStatusSchema = z.enum(["active", "paused", "ended"]);
export const recurringFrequencySchema = z.enum(["weekly", "monthly", "custom_days"]);
export const recurringOccurrenceStatusSchema = z.enum(["generated", "failed"]);
export const planPeriodTypeSchema = z.enum(["annual", "monthly", "custom"]);
export const planStatusSchema = z.enum(["draft", "active", "closed"]);

const reasonSchema = z.string().trim().min(5).max(1000);
const optionalText = (max: number) => z.string().trim().max(max).optional();
const monthSchema = z
  .string()
  .regex(/^\d{4}-\d{2}-01$/, "Bulan harus berupa tanggal awal bulan (YYYY-MM-01)");

// ================================================================ recurring rule templates
/** Shared by every kind: the lines a generated document will carry (Step 15 Phase 10 "generate drafts by
 * default"). Full arithmetic/reference validation happens at generation time in the database, exactly like
 * a manually drafted document — this only shapes the request. */
const templateLineSchema = z
  .object({
    description: z.string().trim().min(1).max(500),
    quantity: z.string().optional(),
    unit_price: moneyTextSchema,
    category_id: z.uuid().optional(),
  })
  .catchall(z.unknown());

const recurringInvoiceTemplateSchema = z.object({
  customer_id: z.uuid(),
  currency: z.string().length(3).optional(),
  exchange_rate: z.string().optional(),
  payment_account_id: z.uuid().optional(),
  payment_channel_id: z.uuid().optional(),
  notes: optionalText(2000),
  terms: optionalText(4000),
  payment_note: optionalText(1000),
  internal_note: optionalText(2000),
  lines: z.array(templateLineSchema).min(1).max(200),
});

const recurringBillTemplateSchema = z.object({
  vendor_id: z.uuid(),
  vendor_reference: optionalText(100),
  currency: z.string().length(3).optional(),
  exchange_rate: z.string().optional(),
  notes: optionalText(2000),
  internal_note: optionalText(2000),
  lines: z.array(templateLineSchema).min(1).max(200),
});

const recurringExpenseTemplateSchema = z
  .object({
    account_id: z.uuid(),
    payee_id: z.uuid().optional(),
    payee_name: optionalText(200),
    receipt_reference: optionalText(100),
    exchange_rate: z.string().optional(),
    notes: optionalText(2000),
    internal_note: optionalText(2000),
    lines: z.array(templateLineSchema).min(1).max(200),
  })
  .superRefine((v, ctx) => {
    if (!v.payee_id && !v.payee_name) {
      ctx.addIssue({
        code: "custom",
        path: ["payee_name"],
        message: "Isi vendor atau nama penerima",
      });
    }
  });

export const recurringTemplateSchema = z.union([
  recurringInvoiceTemplateSchema,
  recurringBillTemplateSchema,
  recurringExpenseTemplateSchema,
]);

// ================================================================ recurring rule commands
export const createRecurringRuleInputSchema = z.object({
  entity_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  kind: recurringKindSchema,
  label: z.string().trim().min(2).max(200),
  frequency: recurringFrequencySchema,
  start_date: isoDateSchema,
  template: recurringTemplateSchema,
  interval_count: z.number().int().min(1).max(365).default(1),
  due_offset_days: z.number().int().min(0).max(365).default(0),
  end_date: isoDateSchema.optional(),
  note: optionalText(1000),
});

export const updateRecurringRuleInputSchema = z.object({
  rule_id: z.uuid(),
  expected_version: z.number().int().min(1).optional(),
  patch: z.object({
    label: z.string().trim().min(2).max(200).optional(),
    template: recurringTemplateSchema.optional(),
    interval_count: z.number().int().min(1).max(365).optional(),
    due_offset_days: z.number().int().min(0).max(365).optional(),
    end_date: isoDateSchema.nullable().optional(),
    note: z.string().trim().max(1000).nullable().optional(),
  }),
});

export const pauseRecurringRuleInputSchema = z.object({ rule_id: z.uuid(), reason: reasonSchema });
export const resumeRecurringRuleInputSchema = z.object({ rule_id: z.uuid() });
export const endRecurringRuleInputSchema = z.object({ rule_id: z.uuid(), reason: reasonSchema });

export const listRecurringRulesInputSchema = z.object({
  entity_id: z.uuid(),
  status: recurringStatusSchema.optional(),
});

export const recurringRuleRowSchema = z.object({
  id: z.uuid(),
  entity_id: z.uuid(),
  kind: recurringKindSchema,
  label: z.string(),
  status: recurringStatusSchema,
  frequency: recurringFrequencySchema,
  interval_count: z.number().int(),
  due_offset_days: z.number().int(),
  start_date: isoDateSchema,
  end_date: isoDateSchema.nullable(),
  next_occurrence_date: isoDateSchema,
  last_generated_date: isoDateSchema.nullable(),
  template: z.unknown(),
  note: z.string().nullable(),
  paused_at: z.string().nullable(),
  paused_reason: z.string().nullable(),
  ended_at: z.string().nullable(),
  ended_reason: z.string().nullable(),
  version: z.number().int(),
});
export const recurringRuleListSchema = z.array(recurringRuleRowSchema);
export type RecurringRuleRow = z.infer<typeof recurringRuleRowSchema>;

export const listRecurringOccurrencesInputSchema = z.object({
  rule_id: z.uuid(),
  limit: z.number().int().min(1).max(200).optional(),
});

export const recurringOccurrenceRowSchema = z.object({
  id: z.uuid(),
  recurring_rule_id: z.uuid(),
  occurrence_date: isoDateSchema,
  status: recurringOccurrenceStatusSchema,
  generated_table: z.enum(["invoices", "bills", "expenses"]).nullable(),
  generated_id: z.uuid().nullable(),
  attempts: z.number().int(),
  last_attempted_at: z.string(),
  last_error: z.string().nullable(),
});
export const recurringOccurrenceListSchema = z.array(recurringOccurrenceRowSchema);
export type RecurringOccurrenceRow = z.infer<typeof recurringOccurrenceRowSchema>;

/** The manual "generate now" action (`planning.recurring_run`); the scheduled path calls the same RPC with
 * the service key and no signed-in user (Step 15 Phase 10 / DECISIONS 136). */
export const runDueRecurringOccurrencesInputSchema = z.object({
  entity_id: z.uuid(),
  as_of: isoDateSchema.optional(),
});

// ================================================================ budgets
export const createBudgetInputSchema = z
  .object({
    entity_id: z.uuid(),
    idempotency_key: idempotencyKeySchema,
    name: z.string().trim().min(2).max(200),
    period_type: planPeriodTypeSchema,
    start_date: isoDateSchema,
    end_date: isoDateSchema,
    fiscal_year: z.number().int().min(2000).max(2100).optional(),
    note: optionalText(1000),
  })
  .refine((v) => v.end_date >= v.start_date, {
    path: ["end_date"],
    message: "Tanggal akhir sebelum tanggal mulai",
  });

export const budgetLineInputSchema = z.object({
  category_id: z.uuid(),
  period_month: monthSchema,
  budgeted_amount: moneyTextSchema,
});

export const setBudgetLinesInputSchema = z.object({
  budget_id: z.uuid(),
  expected_version: z.number().int().min(1).optional(),
  lines: z.array(budgetLineInputSchema).max(2000),
});

export const activateBudgetInputSchema = z.object({ budget_id: z.uuid() });
export const closeBudgetInputSchema = z.object({ budget_id: z.uuid() });

export const listBudgetsInputSchema = z.object({
  entity_id: z.uuid(),
  status: planStatusSchema.optional(),
});

export const budgetRowSchema = z.object({
  id: z.uuid(),
  entity_id: z.uuid(),
  name: z.string(),
  fiscal_year: z.number().int().nullable(),
  period_type: planPeriodTypeSchema,
  start_date: isoDateSchema,
  end_date: isoDateSchema,
  status: planStatusSchema,
  note: z.string().nullable(),
  version: z.number().int(),
});
export const budgetListSchema = z.array(budgetRowSchema);
export type BudgetRow = z.infer<typeof budgetRowSchema>;

export const budgetLineRowSchema = z.object({
  id: z.uuid(),
  budget_id: z.uuid(),
  category_id: z.uuid(),
  period_month: isoDateSchema,
  budgeted_amount: signedDecimalTextSchema,
});
export const budgetLineListSchema = z.array(budgetLineRowSchema);

/** `forecast_amount` is always null (DECISIONS 139): no locked spec defines a projection methodology, so
 * this is filed as an open OWNER question rather than guessed. */
export const budgetReportRowSchema = z.object({
  category_id: z.uuid(),
  category_name: z.string(),
  period_month: isoDateSchema,
  budgeted_amount: signedDecimalTextSchema,
  actual_amount: signedDecimalTextSchema,
  committed_amount: signedDecimalTextSchema,
  remaining_amount: signedDecimalTextSchema,
  pct_used: signedDecimalTextSchema.nullable(),
  variance_amount: signedDecimalTextSchema,
  forecast_amount: signedDecimalTextSchema.nullable(),
});
export const budgetReportSchema = z.array(budgetReportRowSchema);
export type BudgetReportRow = z.infer<typeof budgetReportRowSchema>;

// ================================================================ revenue targets
export const createRevenueTargetInputSchema = z
  .object({
    entity_id: z.uuid(),
    idempotency_key: idempotencyKeySchema,
    name: z.string().trim().min(2).max(200),
    period_type: planPeriodTypeSchema,
    start_date: isoDateSchema,
    end_date: isoDateSchema,
    fiscal_year: z.number().int().min(2000).max(2100).optional(),
    note: optionalText(1000),
  })
  .refine((v) => v.end_date >= v.start_date, {
    path: ["end_date"],
    message: "Tanggal akhir sebelum tanggal mulai",
  });

export const revenueTargetLineInputSchema = z.object({
  period_month: monthSchema,
  target_amount: moneyTextSchema,
});

export const setRevenueTargetLinesInputSchema = z.object({
  target_id: z.uuid(),
  expected_version: z.number().int().min(1).optional(),
  lines: z.array(revenueTargetLineInputSchema).max(120),
});

export const activateRevenueTargetInputSchema = z.object({ target_id: z.uuid() });
export const closeRevenueTargetInputSchema = z.object({ target_id: z.uuid() });

export const listRevenueTargetsInputSchema = z.object({
  entity_id: z.uuid(),
  status: planStatusSchema.optional(),
});

export const revenueTargetRowSchema = z.object({
  id: z.uuid(),
  entity_id: z.uuid(),
  name: z.string(),
  fiscal_year: z.number().int().nullable(),
  period_type: planPeriodTypeSchema,
  start_date: isoDateSchema,
  end_date: isoDateSchema,
  status: planStatusSchema,
  note: z.string().nullable(),
  version: z.number().int(),
});
export const revenueTargetListSchema = z.array(revenueTargetRowSchema);
export type RevenueTargetRow = z.infer<typeof revenueTargetRowSchema>;

export const revenueTargetLineRowSchema = z.object({
  id: z.uuid(),
  target_id: z.uuid(),
  period_month: isoDateSchema,
  target_amount: signedDecimalTextSchema,
});
export const revenueTargetLineListSchema = z.array(revenueTargetLineRowSchema);

export const revenueTargetReportRowSchema = z.object({
  period_month: isoDateSchema,
  target_amount: signedDecimalTextSchema,
  actual_amount: signedDecimalTextSchema,
  ar_outstanding_amount: signedDecimalTextSchema,
  variance_amount: signedDecimalTextSchema,
  forecast_amount: signedDecimalTextSchema.nullable(),
});
export const revenueTargetReportSchema = z.array(revenueTargetReportRowSchema);
export type RevenueTargetReportRow = z.infer<typeof revenueTargetReportRowSchema>;
