import "server-only";
import { z, type ZodType } from "zod";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { AuthzError, parseAuthzCode } from "@/domain/authz/errors";
import { isoDateSchema, uuidResultSchema } from "@/schemas/accounting";
import { entityCurrencyRowSchema } from "@/schemas/dashboard";
import {
  activateEngineInputSchema,
  computeFinalTaxInputSchema,
  confirmLineInputSchema,
  discardRuleInputSchema,
  finalPreviewSchema,
  finalTaxInputSchema,
  linkTaxEvidenceInputSchema,
  listTaxEvidenceInputSchema,
  listTaxPaymentsInputSchema,
  periodPositionInputSchema,
  periodPositionSchema,
  previewDocumentInputSchema,
  publishRuleInputSchema,
  reconcileTaxPeriodInputSchema,
  recordAggregationFactInputSchema,
  recordContactFactsInputSchema,
  recordEntityProfileInputSchema,
  recordTaxFilingInputSchema,
  recordTaxPaymentInputSchema,
  reverseTaxPaymentInputSchema,
  reviewQueueSchema,
  ruleInForceSchema,
  saveRuleDraftInputSchema,
  setOverrideInputSchema,
  taxCalendarInputSchema,
  taxCalendarSchema,
  taxControlSchema,
  taxDeterminationRowsSchema,
  taxEvidenceSchema,
  taxLedgerInputSchema,
  taxLedgerSchema,
  taxOverviewSchema,
  taxPaymentListSchema,
  taxPreviewSchema,
  taxSourceTypeSchema,
  withdrawOverrideInputSchema,
  type FinalPreview,
  type ReviewQueueRow,
  type RuleInForceRow,
  type TaxCalendarRow,
  type TaxControlRow,
  type TaxDeterminationRow,
  type TaxEvidenceRow,
  type TaxLedgerRow,
  type TaxOverview,
  type TaxPaymentRow,
  type TaxPeriodPosition,
  type TaxPreview,
} from "@/schemas/tax";

/**
 * Thin, typed wrappers over the tax RPCs (P7). Every call runs as the signed-in person; the database decides who
 * may do what per Entity and applies every rule (the versioned rule master, the effective dates, the formulas,
 * NEEDS_REVIEW, overrides, posting, the tax ledger, payments, filings, reconciliation, the final-tax computation,
 * the calendar) inside the transaction. This layer validates the input shape, maps the database's error prefixes
 * to AuthzError without leaking detail, and validates what comes back. It holds no tax rule of its own
 * (Step 05, Step 15 §11, Step 16 §15, Step 13 §9). Labels and early-feedback checks live in `@/domain/tax`.
 */

async function callRpc<T>(
  name: string,
  args: Record<string, unknown>,
  schema: ZodType<T>,
): Promise<T> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc(name, args);
  if (error) {
    const code = parseAuthzCode(error.message);
    if (code) throw new AuthzError(code);
    throw new Error("Operasi pajak gagal diproses.");
  }
  const parsed = schema.safeParse(data);
  if (!parsed.success) throw new Error("Respons pajak tidak dikenali.");
  return parsed.data;
}

const nothing = z.null();

// ---- facts
export async function recordEntityProfile(
  input: z.input<typeof recordEntityProfileInputSchema>,
): Promise<string> {
  const v = recordEntityProfileInputSchema.parse(input);
  return callRpc(
    "tax_record_entity_profile",
    {
      p_entity: v.entity_id,
      p_key: v.idempotency_key,
      p_effective_from: v.effective_from,
      p_taxpayer_kind: v.taxpayer_kind,
      p_residency: v.residency,
      p_income_regime: v.income_regime,
      p_umkm_exclusion: v.umkm_exclusion,
      p_aggregation_status: v.aggregation_status,
      p_vat_status: v.vat_status,
      p_withholding_agent: v.withholding_agent,
      p_tax_identifier: v.tax_identifier ?? null,
      p_evidence_note: v.evidence_note ?? null,
    },
    uuidResultSchema,
  );
}

export async function recordContactFacts(
  input: z.input<typeof recordContactFactsInputSchema>,
): Promise<string> {
  const v = recordContactFactsInputSchema.parse(input);
  return callRpc(
    "tax_record_contact_facts",
    {
      p_contact: v.contact_id,
      p_key: v.idempotency_key,
      p_effective_from: v.effective_from,
      p_party_kind: v.party_kind,
      p_residency: v.residency,
      p_tax_id_status: v.tax_id_status,
      p_pkp_status: v.pkp_status,
      p_wht_exemption: v.wht_exemption,
      p_evidence_note: v.evidence_note ?? null,
    },
    uuidResultSchema,
  );
}

export async function recordAggregationFact(
  input: z.input<typeof recordAggregationFactInputSchema>,
): Promise<string> {
  const v = recordAggregationFactInputSchema.parse(input);
  return callRpc(
    "tax_record_aggregation_fact",
    {
      p_entity: v.entity_id,
      p_key: v.idempotency_key,
      p_tax_year: v.tax_year,
      p_amount: v.amount,
      p_description: v.description,
      p_evidence_note: v.evidence_note ?? null,
    },
    uuidResultSchema,
  );
}

/** Returns the date from which the engine recognises tax for the Entity. */
export async function activateTaxEngine(
  input: z.input<typeof activateEngineInputSchema>,
): Promise<string> {
  const v = activateEngineInputSchema.parse(input);
  return callRpc(
    "tax_engine_activate",
    { p_entity: v.entity_id, p_key: v.idempotency_key, p_from: v.from },
    isoDateSchema,
  );
}

// ---- rule master
export async function saveRuleDraft(
  input: z.input<typeof saveRuleDraftInputSchema>,
): Promise<string> {
  const v = saveRuleDraftInputSchema.parse(input);
  return callRpc(
    "tax_rule_draft_save",
    {
      p_key: v.idempotency_key,
      p_rule: v.rule_id ?? null,
      p_family: v.family,
      p_code: v.code,
      p_effective_from: v.effective_from,
      p_is_repeal: v.is_repeal,
      p_params: v.params,
      p_source_title: v.source_title,
      p_source_ref: v.source_ref ?? null,
      p_source_url: v.source_url ?? null,
      p_verified_on: v.verified_on ?? null,
      p_verification_status: v.verification_status,
      p_notes: v.notes ?? null,
    },
    uuidResultSchema,
  );
}

export async function publishRule(input: z.input<typeof publishRuleInputSchema>): Promise<string> {
  const v = publishRuleInputSchema.parse(input);
  return callRpc(
    "tax_rule_publish",
    { p_rule: v.rule_id, p_key: v.idempotency_key },
    uuidResultSchema,
  );
}

export async function discardRule(input: z.input<typeof discardRuleInputSchema>): Promise<void> {
  const v = discardRuleInputSchema.parse(input);
  await callRpc("tax_rule_discard", { p_rule: v.rule_id, p_reason: v.reason }, nothing);
}

/** The rule versions of a code in force on a date (with their legal source), for display beside a result. */
export async function listRulesInForce(code: string, date: string): Promise<RuleInForceRow[]> {
  const v = z
    .object({ code: z.string().trim().min(2).max(80), date: isoDateSchema })
    .parse({ code, date });
  return callRpc("tax_rule_in_force", { p_code: v.code, p_date: v.date }, ruleInForceSchema);
}

// ---- determination of a document
/** What the engine would decide for a document today; nothing is recorded. */
export async function previewDocumentTax(
  input: z.input<typeof previewDocumentInputSchema>,
): Promise<TaxPreview> {
  const v = previewDocumentInputSchema.parse(input);
  return callRpc(
    "tax_preview_document",
    { p_source_type: v.source_type, p_source_id: v.source_id },
    taxPreviewSchema,
  );
}

/** A tax reviewer settles a line the drafter was unsure about; only for a document not yet recognised. */
export async function confirmTaxLine(input: z.input<typeof confirmLineInputSchema>): Promise<void> {
  const v = confirmLineInputSchema.parse(input);
  await callRpc(
    "tax_confirm_line",
    {
      p_source_type: v.source_type,
      p_source_id: v.source_id,
      p_line_no: v.line_no,
      p_treatment: v.treatment,
    },
    nothing,
  );
}

/** OWNER only, with a recent step-up: replaces the engine's result for a document that is not yet recognised. */
export async function setTaxOverride(
  input: z.input<typeof setOverrideInputSchema>,
): Promise<string> {
  const v = setOverrideInputSchema.parse(input);
  return callRpc(
    "tax_override_set",
    {
      p_source_type: v.source_type,
      p_source_id: v.source_id,
      p_key: v.idempotency_key,
      p_kind: v.kind,
      p_amount: v.amount,
      p_reason: v.reason,
      p_evidence_note: v.evidence_note,
      p_evidence_document: v.evidence_document_id ?? null,
    },
    uuidResultSchema,
  );
}

export async function withdrawTaxOverride(
  input: z.input<typeof withdrawOverrideInputSchema>,
): Promise<void> {
  const v = withdrawOverrideInputSchema.parse(input);
  await callRpc(
    "tax_override_withdraw",
    { p_override: v.override_id, p_reason: v.reason },
    nothing,
  );
}

/** Documents that wait for a tax review, oldest first. */
export async function listTaxReviewQueue(entityId: string): Promise<ReviewQueueRow[]> {
  return callRpc(
    "tax_review_queue",
    { p_entity: uuidResultSchema.parse(entityId) },
    reviewQueueSchema,
  );
}

// ---- payments, filings, evidence, reconciliation
export async function recordTaxPayment(
  input: z.input<typeof recordTaxPaymentInputSchema>,
): Promise<string> {
  const v = recordTaxPaymentInputSchema.parse(input);
  return callRpc(
    "tax_record_payment",
    {
      p_entity: v.entity_id,
      p_key: v.idempotency_key,
      p_tax_type: v.tax_type,
      p_period: v.period,
      p_date: v.payment_date,
      p_account: v.account_id ?? null,
      p_payable: v.payable,
      p_asset_offset: v.asset_offset ?? "0",
      p_penalty: v.penalty ?? "0",
      p_reference: v.reference ?? null,
      p_note: v.note ?? null,
    },
    uuidResultSchema,
  );
}

export async function reverseTaxPayment(
  input: z.input<typeof reverseTaxPaymentInputSchema>,
): Promise<string> {
  const v = reverseTaxPaymentInputSchema.parse(input);
  return callRpc(
    "tax_reverse_payment",
    { p_payment: v.payment_id, p_key: v.idempotency_key, p_date: v.date, p_reason: v.reason },
    uuidResultSchema,
  );
}

/** Records a filing as filed; a period that is already filed takes an amendment (`amendment: true` and a note). */
export async function recordTaxFiling(
  input: z.input<typeof recordTaxFilingInputSchema>,
): Promise<string> {
  const v = recordTaxFilingInputSchema.parse(input);
  return callRpc(
    "tax_record_filing",
    {
      p_entity: v.entity_id,
      p_key: v.idempotency_key,
      p_tax_type: v.tax_type,
      p_period: v.period,
      p_filed_date: v.filed_date,
      p_reference: v.reference,
      p_reported_base: v.reported_base,
      p_reported_tax: v.reported_tax,
      p_reported_credit: v.reported_credit ?? "0",
      p_amendment: v.amendment ?? false,
      p_note: v.note ?? null,
    },
    uuidResultSchema,
  );
}

/** Attaches a registered document to a filing or a payment. Tax evidence is part of the record and stays. */
export async function linkTaxEvidence(
  input: z.input<typeof linkTaxEvidenceInputSchema>,
): Promise<string> {
  const v = linkTaxEvidenceInputSchema.parse(input);
  return callRpc(
    "tax_link_evidence",
    {
      p_document: v.document_id,
      p_target_type: v.target_type,
      p_target_id: v.target_id,
      p_purpose: v.purpose ?? null,
    },
    uuidResultSchema,
  );
}

export async function listTaxEvidence(
  input: z.input<typeof listTaxEvidenceInputSchema>,
): Promise<TaxEvidenceRow[]> {
  const v = listTaxEvidenceInputSchema.parse(input);
  return callRpc(
    "tax_list_evidence",
    { p_entity: v.entity_id, p_target_type: v.target_type, p_target_id: v.target_id },
    taxEvidenceSchema,
  );
}

/** Records a snapshot of the period's ledger, payments and filing; differences need a written note. */
export async function reconcileTaxPeriod(
  input: z.input<typeof reconcileTaxPeriodInputSchema>,
): Promise<string> {
  const v = reconcileTaxPeriodInputSchema.parse(input);
  return callRpc(
    "tax_reconcile_period",
    {
      p_entity: v.entity_id,
      p_key: v.idempotency_key,
      p_tax_type: v.tax_type,
      p_period: v.period,
      p_note: v.note ?? null,
    },
    uuidResultSchema,
  );
}

// ---- PPh Final UMKM
export async function previewFinalTax(
  input: z.input<typeof finalTaxInputSchema>,
): Promise<FinalPreview> {
  const v = finalTaxInputSchema.parse(input);
  return callRpc(
    "tax_final_preview",
    { p_entity: v.entity_id, p_period: v.period },
    finalPreviewSchema,
  );
}

/** Computes (or recomputes) the month's final tax; only the difference to an earlier result is posted. */
export async function computeFinalTax(
  input: z.input<typeof computeFinalTaxInputSchema>,
): Promise<string> {
  const v = computeFinalTaxInputSchema.parse(input);
  return callRpc(
    "tax_final_compute",
    { p_entity: v.entity_id, p_key: v.idempotency_key, p_period: v.period },
    uuidResultSchema,
  );
}

// ---- reading
export async function getTaxPeriodPosition(
  input: z.input<typeof periodPositionInputSchema>,
): Promise<TaxPeriodPosition> {
  const v = periodPositionInputSchema.parse(input);
  return callRpc(
    "tax_period_position",
    {
      p_entity: v.entity_id,
      p_tax_type: v.tax_type,
      p_period: v.period,
      p_as_of: v.as_of ?? null,
    },
    periodPositionSchema,
  );
}

export async function listTaxPayments(
  input: z.input<typeof listTaxPaymentsInputSchema>,
): Promise<TaxPaymentRow[]> {
  const v = listTaxPaymentsInputSchema.parse(input);
  return callRpc(
    "tax_list_payments",
    {
      p_entity: v.entity_id,
      p_tax_type: v.tax_type ?? null,
      p_period: v.period ?? null,
      p_limit: v.limit ?? 100,
    },
    taxPaymentListSchema,
  );
}

export async function getTaxControl(entityId: string, asOf?: string): Promise<TaxControlRow[]> {
  return callRpc(
    "tax_control_report",
    {
      p_entity: uuidResultSchema.parse(entityId),
      p_as_of: asOf ? isoDateSchema.parse(asOf) : null,
    },
    taxControlSchema,
  );
}

export async function listTaxLedger(
  input: z.input<typeof taxLedgerInputSchema>,
): Promise<TaxLedgerRow[]> {
  const v = taxLedgerInputSchema.parse(input);
  return callRpc(
    "tax_ledger_report",
    {
      p_entity: v.entity_id,
      p_from: v.from ?? null,
      p_to: v.to ?? null,
      p_tax_type: v.tax_type ?? null,
      p_limit: v.limit ?? 200,
    },
    taxLedgerSchema,
  );
}

/** The steps (calculate, pay, file, evidence) of each tax period with their nominal dates and state. */
export async function getTaxCalendar(
  input: z.input<typeof taxCalendarInputSchema>,
): Promise<TaxCalendarRow[]> {
  const v = taxCalendarInputSchema.parse(input);
  return callRpc(
    "tax_calendar",
    { p_entity: v.entity_id, p_from: v.from ?? null, p_to: v.to ?? null },
    taxCalendarSchema,
  );
}

export async function getTaxOverview(entityId: string): Promise<TaxOverview> {
  return callRpc("tax_overview", { p_entity: uuidResultSchema.parse(entityId) }, taxOverviewSchema);
}

// ---- direct read (P13 Part 3e): no RPC reads a stored determination back -- `tax_preview_document` is a live,
// unconfirmed recomputation of a document's tax (useful before it is posted), a different concept from reading
// what was actually recorded (Step 05 §14). This is a plain `.from(table).select(...)` covered by
// `tax_determinations`' own pre-existing `tax.view`-gated RLS policy, extending the direct-table-read pattern
// (decisions 161/167/170/171/172) to `public.tax_determinations`.

const TAX_DETERMINATION_COLUMNS =
  "id, entity_id, tax_kind, tax_type, source_type, source_id, event_date, tax_period, status, currency, base_amount, rate, tax_amount, direction, rules, facts, trace, components, consequence, computed_tax_amount, override_id, journal_id, confirmed, revision, supersedes_id, superseded_at, superseded_reason, created_at, updated_at";

/** Every determination ever made for one document, newest first -- a document can carry more than one
 * `tax_kind` at once (a bill can owe both input VAT and PPh 23 withholding), and a superseded row stays as
 * visible history rather than being deleted or edited (Step 05 §12, §15; the table is append-only). Only
 * `invoice`/`bill`/`expense` are accepted: `period` determinations (PPh Final UMKM's own monthly result,
 * `source_id` null) belong to the Tax Calendar / PPh Final family of screens, deferred to a later increment. */
export async function listTaxDeterminations(
  sourceType: z.infer<typeof taxSourceTypeSchema>,
  sourceId: string,
): Promise<TaxDeterminationRow[]> {
  const v = z
    .object({ sourceType: taxSourceTypeSchema, sourceId: uuidResultSchema })
    .parse({ sourceType, sourceId });
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("tax_determinations")
    .select(TAX_DETERMINATION_COLUMNS)
    .eq("source_type", v.sourceType)
    .eq("source_id", v.sourceId)
    .order("created_at", { ascending: false });
  if (error) throw new Error("Gagal memuat penentuan pajak.");
  const parsed = taxDeterminationRowsSchema.safeParse(data);
  if (!parsed.success) throw new Error("Respons penentuan pajak tidak dikenali.");
  return parsed.data;
}

/** Every tax amount this layer reads is base-currency (Step 04 §14, as `tax_ledger_report`/`tax_overview`
 * already assume in booking each accrual) -- the same direct read decision 161 established for the Dashboard,
 * repeated here per that decision's own precedent of each service module reading it independently rather than
 * sharing a cross-module accessor. */
export async function getEntityBaseCurrency(entityId: string): Promise<string> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("entities")
    .select("base_currency")
    .eq("id", uuidResultSchema.parse(entityId))
    .single();
  if (error) throw new Error("Gagal memuat mata uang dasar Entity.");
  const parsed = entityCurrencyRowSchema.safeParse(data);
  if (!parsed.success) throw new Error("Respons mata uang dasar Entity tidak dikenali.");
  return parsed.data.base_currency;
}
