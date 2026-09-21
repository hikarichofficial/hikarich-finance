import { z } from "zod";
import {
  idempotencyKeySchema,
  isoDateSchema,
  moneyTextSchema,
  signedDecimalTextSchema,
} from "@/schemas/accounting";

/**
 * Input and output contracts of the tax RPCs (P7): tax facts, the rule master, determination of the tax of
 * invoices, bills and expenses, overrides, payments, filings, evidence, reconciliation, the final-tax computation,
 * the calendar and the reports. The database applies every rule and recomputes every figure; this layer only
 * checks the shape of what goes in and what comes back (Step 13 §25). Money is exact decimal text.
 */

const optionalText = (max: number) => z.string().trim().max(max).optional();
const reasonSchema = z.string().trim().min(5).max(1000);
/** The first day of a month identifies a tax period. */
export const taxPeriodSchema = isoDateSchema.refine((v) => v.endsWith("-01"), {
  message: "Masa pajak adalah tanggal 1 pada bulan yang bersangkutan",
});

export const taxTypeSchema = z.enum(["vat", "wht_pph23", "wht_pph21", "final_umkm"]);
export const taxKindSchema = z.enum([
  "vat_output",
  "vat_input",
  "wht_pph23",
  "wht_pph21",
  "final_umkm",
]);
export const taxSourceTypeSchema = z.enum(["invoice", "bill", "expense"]);

// ---- classification vocabulary (the catalog lives in the database)
export const vatTreatmentSchema = z.enum([
  "vat_taxable",
  "vat_taxable_full_dpp",
  "vat_exempt",
  "vat_not_object",
  "vat_special",
  "vat_digital_pmse",
]);
export const whtObjectSchema = z.enum([
  "wht_none",
  "wht_rent_movable",
  "wht_service_technical",
  "wht_service_management",
  "wht_service_construction",
  "wht_service_consulting",
  "wht_service_other_listed",
  "wht_royalty",
  "wht_interest",
  "wht_prize",
  "wht_review",
]);

// ---- facts of the taxpayer and of counterparties
export const taxpayerKindSchema = z.enum([
  "individual",
  "perseroan_perorangan",
  "company",
  "cooperative",
  "other",
  "unknown",
]);
const residencySchema = z.enum(["resident", "non_resident", "unknown"]);
const incomeRegimeSchema = z.enum(["final_umkm", "general", "unknown"]);
const umkmExclusionSchema = z.enum(["none", "excluded", "unknown"]);
const aggregationStatusSchema = z.enum(["none", "applies", "unknown"]);
const vatStatusSchema = z.enum(["pkp", "non_pkp", "unknown"]);
const yesNoUnknownSchema = z.enum(["yes", "no", "unknown"]);

export const recordEntityProfileInputSchema = z.object({
  entity_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  effective_from: isoDateSchema,
  taxpayer_kind: taxpayerKindSchema,
  residency: residencySchema,
  income_regime: incomeRegimeSchema,
  umkm_exclusion: umkmExclusionSchema,
  aggregation_status: aggregationStatusSchema,
  vat_status: vatStatusSchema,
  withholding_agent: yesNoUnknownSchema,
  /** The taxpayer's own identifier (NPWP); kept encrypted by the database and never returned in lists. */
  tax_identifier: z.string().trim().max(40).nullable().optional(),
  evidence_note: optionalText(1000),
});

export const recordContactFactsInputSchema = z.object({
  contact_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  effective_from: isoDateSchema,
  party_kind: z.enum(["individual", "company", "government", "unknown"]),
  residency: residencySchema,
  tax_id_status: z.enum(["has_npwp", "no_npwp", "unknown"]),
  pkp_status: vatStatusSchema,
  wht_exemption: z.enum(["none", "certificate", "unknown"]),
  evidence_note: optionalText(1000),
});

export const recordAggregationFactInputSchema = z.object({
  entity_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  tax_year: z.number().int().min(2000).max(2100),
  /** Turnover earned outside this system that counts toward the annual ceiling. */
  amount: moneyTextSchema,
  description: z.string().trim().min(3).max(500),
  evidence_note: optionalText(1000),
});

export const activateEngineInputSchema = z.object({
  entity_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  /** The date from which the engine recognises tax; earlier documents are never re-evaluated. */
  from: isoDateSchema,
});

// ---- rule master (owner-managed reference data)
export const ruleFamilySchema = z.enum([
  "ppn",
  "pph23",
  "pph_final_umkm",
  "pph4_2",
  "pph26",
  "pph21",
  "corporate_income",
  "personal_income",
  "deadline",
  "fiscal_depreciation",
  "other",
]);

export const saveRuleDraftInputSchema = z.object({
  idempotency_key: idempotencyKeySchema,
  rule_id: z.uuid().nullable().optional(),
  family: z.string().trim().min(2).max(40),
  code: z.string().trim().min(2).max(80),
  effective_from: isoDateSchema,
  is_repeal: z.boolean().default(false),
  params: z.record(z.string(), z.unknown()),
  source_title: z.string().trim().min(3).max(300),
  source_ref: optionalText(200),
  source_url: optionalText(500),
  verified_on: isoDateSchema.nullable().optional(),
  verification_status: z.enum(["verified", "needs_review"]),
  notes: optionalText(2000),
});

export const publishRuleInputSchema = z.object({
  rule_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
});

export const discardRuleInputSchema = z.object({ rule_id: z.uuid(), reason: reasonSchema });

// ---- determination, confirmation and override of a document
export const previewDocumentInputSchema = z.object({
  source_type: taxSourceTypeSchema,
  source_id: z.uuid(),
});

export const confirmLineInputSchema = z.object({
  source_type: taxSourceTypeSchema,
  source_id: z.uuid(),
  line_no: z.number().int().positive(),
  /** A VAT treatment for an invoice line, a withholding object for a bill or expense line. */
  treatment: z.union([vatTreatmentSchema, whtObjectSchema]),
});

export const setOverrideInputSchema = z.object({
  source_type: taxSourceTypeSchema,
  source_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  kind: taxKindSchema,
  /** The tax the OWNER decides applies instead of the engine's result (never above the base). */
  amount: moneyTextSchema,
  reason: z.string().trim().min(10).max(1000),
  evidence_note: z.string().trim().min(5).max(1000),
  evidence_document_id: z.uuid().optional(),
});

export const withdrawOverrideInputSchema = z.object({
  override_id: z.uuid(),
  reason: z.string().trim().min(5).max(500),
});

// ---- payments, filings, evidence, reconciliation
export const recordTaxPaymentInputSchema = z.object({
  entity_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  tax_type: taxTypeSchema,
  period: taxPeriodSchema,
  payment_date: isoDateSchema,
  /** A base-currency account; omitted only when the whole payment is offset against input VAT. */
  account_id: z.uuid().nullable().optional(),
  payable: moneyTextSchema,
  asset_offset: moneyTextSchema.optional(),
  penalty: moneyTextSchema.optional(),
  reference: optionalText(200),
  note: optionalText(1000),
});

export const reverseTaxPaymentInputSchema = z.object({
  payment_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  date: isoDateSchema,
  reason: reasonSchema,
});

export const recordTaxFilingInputSchema = z.object({
  entity_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  tax_type: taxTypeSchema,
  period: taxPeriodSchema,
  filed_date: isoDateSchema,
  /** The receipt number of the filing (3 to 200 characters). */
  reference: z.string().trim().min(3).max(200),
  reported_base: moneyTextSchema,
  reported_tax: moneyTextSchema,
  /** Input VAT credited on a VAT return; other returns have none. */
  reported_credit: moneyTextSchema.optional(),
  amendment: z.boolean().optional(),
  /** Required for an amendment: what changed. */
  note: optionalText(1000),
});

export const evidencePurposeSchema = z.enum([
  "filing_receipt",
  "payment_proof",
  "withholding_slip",
  "tax_invoice",
  "other",
]);
export const taxEvidenceTargetSchema = z.enum(["tax_filing", "tax_payment"]);

export const linkTaxEvidenceInputSchema = z.object({
  document_id: z.uuid(),
  target_type: taxEvidenceTargetSchema,
  target_id: z.uuid(),
  purpose: evidencePurposeSchema.optional(),
});

export const listTaxEvidenceInputSchema = z.object({
  entity_id: z.uuid(),
  target_type: taxEvidenceTargetSchema,
  target_id: z.uuid(),
});

export const reconcileTaxPeriodInputSchema = z.object({
  entity_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  tax_type: taxTypeSchema,
  period: taxPeriodSchema,
  /** Required (10+ characters) when the period still shows differences. */
  note: optionalText(1000),
});

export const finalTaxInputSchema = z.object({ entity_id: z.uuid(), period: taxPeriodSchema });

export const computeFinalTaxInputSchema = z.object({
  entity_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  period: taxPeriodSchema,
});

export const periodPositionInputSchema = z.object({
  entity_id: z.uuid(),
  tax_type: taxTypeSchema,
  period: taxPeriodSchema,
  as_of: isoDateSchema.optional(),
});

export const taxCalendarInputSchema = z.object({
  entity_id: z.uuid(),
  from: isoDateSchema.optional(),
  to: isoDateSchema.optional(),
});

export const listTaxPaymentsInputSchema = z.object({
  entity_id: z.uuid(),
  tax_type: taxTypeSchema.optional(),
  period: taxPeriodSchema.optional(),
  limit: z.number().int().min(1).max(500).optional(),
});

export const taxLedgerInputSchema = z.object({
  entity_id: z.uuid(),
  from: isoDateSchema.optional(),
  to: isoDateSchema.optional(),
  tax_type: taxTypeSchema.optional(),
  limit: z.number().int().min(1).max(1000).optional(),
});

// ---- RPC results
export const determinationStatusSchema = z.enum([
  "auto_determined",
  "owner_confirmed",
  "overridden",
  "needs_review",
  "not_configured",
  "not_applicable",
]);

/** One result of the engine for a document (`results[]` of a preview). Unlisted fields are kept as they are. */
export const taxResultSchema = z.looseObject({
  kind: taxKindSchema,
  status: determinationStatusSchema,
  tax: z.string(),
});

export const taxPreviewSchema = z.looseObject({
  source_type: taxSourceTypeSchema,
  source_id: z.uuid(),
  event_date: isoDateSchema,
  tax_period: isoDateSchema,
  status: determinationStatusSchema,
  reasons: z.array(z.string()),
  results: z.array(taxResultSchema),
  vat_output_total: signedDecimalTextSchema,
  withheld_total: signedDecimalTextSchema,
  vat_input_creditable: signedDecimalTextSchema,
  vat_input_cost: signedDecimalTextSchema,
});
export type TaxPreview = z.infer<typeof taxPreviewSchema>;

export const finalPreviewSchema = z.looseObject({
  status: z.enum(["auto_determined", "needs_review", "not_applicable", "not_configured"]),
  reasons: z.array(z.string()),
  tax: signedDecimalTextSchema,
  base: signedDecimalTextSchema.optional(),
});
export type FinalPreview = z.infer<typeof finalPreviewSchema>;

export const reviewQueueRowSchema = z.object({
  source_type: taxSourceTypeSchema,
  source_id: z.uuid(),
  reference: z.string().nullable(),
  event_date: isoDateSchema,
  status: z.string(),
  reasons: z.array(z.string()),
});
export const reviewQueueSchema = z.array(reviewQueueRowSchema);
export type ReviewQueueRow = z.infer<typeof reviewQueueRowSchema>;

export const differenceSchema = z.object({
  code: z.enum([
    "filing_missing",
    "filed_tax_differs",
    "filed_credit_differs",
    "filed_base_differs",
    "unpaid",
    "overpaid",
  ]),
  text: z.string(),
  amount: signedDecimalTextSchema.nullable(),
});
export type TaxDifference = z.infer<typeof differenceSchema>;

export const periodPositionSchema = z.looseObject({
  tax_type: taxTypeSchema,
  tax_period: isoDateSchema,
  as_of: isoDateSchema,
  base: signedDecimalTextSchema,
  accrued_payable: signedDecimalTextSchema,
  paid_payable: signedDecimalTextSchema,
  outstanding_payable: signedDecimalTextSchema,
  accrued_asset: signedDecimalTextSchema,
  applied_asset: signedDecimalTextSchema,
  asset_available: signedDecimalTextSchema,
  penalty_paid: signedDecimalTextSchema,
  cash_paid: signedDecimalTextSchema,
  filing_id: z.uuid().nullable(),
  filed_reference: z.string().nullable(),
  differences: z.array(differenceSchema),
  evidence_count: z.number().int().nonnegative(),
});
export type TaxPeriodPosition = z.infer<typeof periodPositionSchema>;

export const taxPaymentRowSchema = z.object({
  payment_id: z.uuid(),
  payment_number: z.string(),
  status: z.enum(["confirmed", "reversed"]),
  tax_type: taxTypeSchema,
  tax_period: isoDateSchema,
  payment_date: isoDateSchema,
  payable_applied: signedDecimalTextSchema,
  asset_applied: signedDecimalTextSchema,
  penalty_amount: signedDecimalTextSchema,
  cash_amount: signedDecimalTextSchema,
  financial_account_id: z.uuid().nullable(),
  reference: z.string().nullable(),
  journal_id: z.uuid().nullable(),
  reversal_journal_id: z.uuid().nullable(),
});
export const taxPaymentListSchema = z.array(taxPaymentRowSchema);
export type TaxPaymentRow = z.infer<typeof taxPaymentRowSchema>;

export const taxControlRowSchema = z.object({
  account_key: z.string(),
  sub_ledger: signedDecimalTextSchema,
  ledger_workflow: signedDecimalTextSchema,
  ledger_other: signedDecimalTextSchema,
  ledger_total: signedDecimalTextSchema,
  difference: signedDecimalTextSchema,
});
export const taxControlSchema = z.array(taxControlRowSchema);
export type TaxControlRow = z.infer<typeof taxControlRowSchema>;

export const taxLedgerRowSchema = z.object({
  entry_id: z.uuid(),
  entry_date: isoDateSchema,
  tax_period: isoDateSchema,
  tax_kind: taxKindSchema,
  tax_type: taxTypeSchema,
  direction: z.enum(["payable", "asset"]),
  entry_kind: z.enum(["accrual", "reversal"]),
  amount: signedDecimalTextSchema,
  source_type: z.string(),
  source_id: z.uuid(),
  determination_status: z.string(),
  journal_id: z.uuid().nullable(),
  description: z.string().nullable(),
});
export const taxLedgerSchema = z.array(taxLedgerRowSchema);
export type TaxLedgerRow = z.infer<typeof taxLedgerRowSchema>;

export const taxEvidenceRowSchema = z.object({
  link_id: z.uuid(),
  document_id: z.uuid(),
  file_name: z.string(),
  mime_type: z.string(),
  size_bytes: z.coerce.number().int().positive(),
  sha256: z.string(),
  purpose: evidencePurposeSchema,
  created_at: z.string(),
});
export const taxEvidenceSchema = z.array(taxEvidenceRowSchema);
export type TaxEvidenceRow = z.infer<typeof taxEvidenceRowSchema>;

export const taxCalendarRowSchema = z.object({
  tax_type: taxTypeSchema,
  tax_period: isoDateSchema,
  step: z.enum(["calculate", "pay", "file", "evidence"]),
  due_date: isoDateSchema.nullable(),
  state: z.enum(["done", "due", "overdue", "upcoming", "not_applicable", "no_rule"]),
  outstanding: signedDecimalTextSchema.nullable(),
  rule_code: z.string().nullable(),
  rule_version: z.number().int().nullable(),
  detail: z.string().nullable(),
});
export const taxCalendarSchema = z.array(taxCalendarRowSchema);
export type TaxCalendarRow = z.infer<typeof taxCalendarRowSchema>;

export const taxOverviewSchema = z.looseObject({
  entity_id: z.uuid(),
  as_of: isoDateSchema,
  engine_active_from: isoDateSchema.nullable(),
  needs_review_count: z.number().int().nonnegative(),
  outstanding: z.record(z.string(), signedDecimalTextSchema),
});
export type TaxOverview = z.infer<typeof taxOverviewSchema>;

export const ruleInForceRowSchema = z.object({
  rule_id: z.uuid(),
  family: z.string(),
  code: z.string(),
  rule_version: z.number().int(),
  effective_from: isoDateSchema,
  params: z.record(z.string(), z.unknown()),
  source_title: z.string(),
  source_ref: z.string().nullable(),
  source_url: z.string().nullable(),
  verified_on: isoDateSchema.nullable(),
});
export const ruleInForceSchema = z.array(ruleInForceRowSchema);
export type RuleInForceRow = z.infer<typeof ruleInForceRowSchema>;
