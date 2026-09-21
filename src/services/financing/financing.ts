import "server-only";
import { z, type ZodType } from "zod";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { AuthzError, parseAuthzCode } from "@/domain/authz/errors";
import { isoDateSchema, uuidResultSchema } from "@/schemas/accounting";
import {
  activateLoanInputSchema,
  cancelEquityEventInputSchema,
  cancelLoanInputSchema,
  confirmEquityEventInputSchema,
  createEquityEventInputSchema,
  createLoanInputSchema,
  createObligationInputSchema,
  equityDetailSchema,
  equityFilterSchema,
  equityListSchema,
  equitySummarySchema,
  financingControlInputSchema,
  financingControlSchema,
  financingTaxReviewsSchema,
  loadOpeningLoansInputSchema,
  loanDetailSchema,
  loanDueInputSchema,
  loanDueSchema,
  loanFilterSchema,
  loanListSchema,
  loanScheduleInputSchema,
  loanScheduleSchema,
  loanSummarySchema,
  obligationDetailSchema,
  obligationFilterSchema,
  obligationListSchema,
  payDividendInputSchema,
  periodInputSchema,
  recordFinancingTaxReviewInputSchema,
  repayLoanInputSchema,
  restructureLoanInputSchema,
  reverseDividendPaymentInputSchema,
  reverseEquityEventInputSchema,
  reverseLoanPaymentInputSchema,
  reverseSettlementInputSchema,
  setLoanAssetInputSchema,
  settleObligationInputSchema,
  voidObligationInputSchema,
  writeOffLoanInputSchema,
  writeOffObligationInputSchema,
  type EquityDetail,
  type EquityRow,
  type EquitySummaryRow,
  type FinancingControlRow,
  type FinancingTaxReviewRow,
  type LoanDetail,
  type LoanDueRow,
  type LoanRow,
  type LoanScheduleRow,
  type LoanSummaryRow,
  type ObligationDetail,
  type ObligationRow,
} from "@/schemas/financing";

/**
 * Thin, typed wrappers over the financing RPCs (P8): other receivables/payables, loans and equity, plus their
 * control and tax-review queue. Every call runs as the signed-in person; the database decides who may do what per
 * Entity (`loans.*`, `equity.*`, `equity.approve`, `tax.confirm_facts`, step-up, maker-checker) and applies every
 * rule (schedules, allocation, posting, capacity, immutability, idempotency) inside the transaction. This layer
 * validates the input shape, maps the database's error prefixes to AuthzError without leaking detail, and
 * validates what comes back. It holds no accounting rule of its own (Step 15 §12, Step 16 §16-17, Step 13 §9).
 * Labels and the schedule preview live in `@/domain/financing`.
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
    throw new Error("Operasi pembiayaan gagal diproses.");
  }
  const parsed = schema.safeParse(data);
  if (!parsed.success) throw new Error("Respons pembiayaan tidak dikenali.");
  return parsed.data;
}

const uuid = (value: string) => uuidResultSchema.parse(value);
const dateArg = (value?: string) => (value ? isoDateSchema.parse(value) : null);
const nothing = z.null();
const uuidList = z.array(z.uuid());

// ================================================================ other receivables and payables
export async function createObligation(
  input: z.input<typeof createObligationInputSchema>,
): Promise<string> {
  const v = createObligationInputSchema.parse(input);
  return callRpc(
    "obligation_create",
    {
      p_entity: v.entity_id,
      p_key: v.idempotency_key,
      p_kind: v.kind,
      p_counterparty: v.counterparty,
      p_contact: v.contact_id ?? null,
      p_date: v.date,
      p_due: v.due_date ?? null,
      p_amount: v.amount,
      p_method: v.method,
      p_account: v.account_id ?? null,
      p_counter: v.counter_account_id ?? null,
      p_purpose: v.purpose,
      p_related: v.related_entity_id ?? null,
      p_basis: v.relationship_basis ?? null,
    },
    uuidResultSchema,
  );
}

export async function settleObligation(
  input: z.input<typeof settleObligationInputSchema>,
): Promise<string> {
  const v = settleObligationInputSchema.parse(input);
  return callRpc(
    "obligation_settle",
    {
      p_obligation: v.obligation_id,
      p_key: v.idempotency_key,
      p_date: v.date,
      p_account: v.account_id,
      p_principal: v.principal,
      p_interest: v.interest,
      p_fee: v.fee,
      p_note: v.note ?? null,
    },
    uuidResultSchema,
  );
}

/** Forgives part of what is owed (needs a fresh step-up); flagged for a tax review, never guessed. */
export async function writeOffObligation(
  input: z.input<typeof writeOffObligationInputSchema>,
): Promise<string> {
  const v = writeOffObligationInputSchema.parse(input);
  return callRpc(
    "obligation_write_off",
    {
      p_obligation: v.obligation_id,
      p_key: v.idempotency_key,
      p_date: v.date,
      p_amount: v.amount,
      p_reason: v.reason,
    },
    uuidResultSchema,
  );
}

export async function reverseObligationSettlement(
  input: z.input<typeof reverseSettlementInputSchema>,
): Promise<string> {
  const v = reverseSettlementInputSchema.parse(input);
  return callRpc(
    "obligation_reverse_settlement",
    { p_settlement: v.settlement_id, p_key: v.idempotency_key, p_date: v.date, p_reason: v.reason },
    uuidResultSchema,
  );
}

export async function voidObligation(
  input: z.input<typeof voidObligationInputSchema>,
): Promise<string> {
  const v = voidObligationInputSchema.parse(input);
  return callRpc(
    "obligation_void",
    { p_obligation: v.obligation_id, p_key: v.idempotency_key, p_date: v.date, p_reason: v.reason },
    uuidResultSchema,
  );
}

export async function listObligations(
  input: z.input<typeof obligationFilterSchema>,
): Promise<ObligationRow[]> {
  const v = obligationFilterSchema.parse(input);
  return callRpc(
    "obligation_list",
    {
      p_entity: v.entity_id,
      p_kind: v.kind ?? null,
      p_status: v.status ?? null,
      p_limit: v.limit ?? 100,
    },
    obligationListSchema,
  );
}

export async function getObligation(obligationId: string): Promise<ObligationDetail> {
  return callRpc("obligation_detail", { p_obligation: uuid(obligationId) }, obligationDetailSchema);
}

// ================================================================ loans
export async function createLoan(input: z.input<typeof createLoanInputSchema>): Promise<string> {
  const v = createLoanInputSchema.parse(input);
  return callRpc(
    "loan_create",
    {
      p_entity: v.entity_id,
      p_key: v.idempotency_key,
      p_direction: v.direction,
      p_counterparty: v.counterparty,
      p_contact: v.contact_id ?? null,
      p_purpose: v.purpose,
      p_principal: v.principal,
      p_agreement: v.agreement_date,
      p_term_class: v.term_class ?? null,
      p_rate: v.rate_percent,
      p_method: v.method,
      p_installments: v.installments ?? null,
      p_step_months: v.step_months ?? null,
      p_first_due: v.first_due ?? null,
      p_items: v.items ?? null,
      p_asset: v.asset_id ?? null,
      p_related: v.related_entity_id ?? null,
      p_basis: v.relationship_basis ?? null,
    },
    uuidResultSchema,
  );
}

/** Moves the money and books the loan (Dr cash / Cr loan, or the reverse for a loan given). Returns the journal id. */
export async function activateLoan(
  input: z.input<typeof activateLoanInputSchema>,
): Promise<string> {
  const v = activateLoanInputSchema.parse(input);
  return callRpc(
    "loan_activate",
    { p_loan: v.loan_id, p_key: v.idempotency_key, p_date: v.date, p_account: v.account_id },
    uuidResultSchema,
  );
}

/** Records a payment; the database allocates it to the installments (arrears first). Returns the payment id. */
export async function repayLoan(input: z.input<typeof repayLoanInputSchema>): Promise<string> {
  const v = repayLoanInputSchema.parse(input);
  return callRpc(
    "loan_repay",
    {
      p_loan: v.loan_id,
      p_key: v.idempotency_key,
      p_date: v.date,
      p_account: v.account_id,
      p_principal: v.principal,
      p_interest: v.interest,
      p_fee: v.fee,
      p_note: v.note ?? null,
    },
    uuidResultSchema,
  );
}

/** Forgives principal (needs a fresh step-up); flagged for a tax review. */
export async function writeOffLoan(
  input: z.input<typeof writeOffLoanInputSchema>,
): Promise<string> {
  const v = writeOffLoanInputSchema.parse(input);
  return callRpc(
    "loan_write_off",
    {
      p_loan: v.loan_id,
      p_key: v.idempotency_key,
      p_date: v.date,
      p_amount: v.amount,
      p_reason: v.reason,
    },
    uuidResultSchema,
  );
}

export async function reverseLoanPayment(
  input: z.input<typeof reverseLoanPaymentInputSchema>,
): Promise<string> {
  const v = reverseLoanPaymentInputSchema.parse(input);
  return callRpc(
    "loan_reverse_payment",
    { p_payment: v.payment_id, p_key: v.idempotency_key, p_date: v.date, p_reason: v.reason },
    uuidResultSchema,
  );
}

/** Replaces the schedule from a date, keeping the history of the old one (needs a fresh step-up). */
export async function restructureLoan(
  input: z.input<typeof restructureLoanInputSchema>,
): Promise<string> {
  const v = restructureLoanInputSchema.parse(input);
  return callRpc(
    "loan_restructure",
    {
      p_loan: v.loan_id,
      p_key: v.idempotency_key,
      p_effective: v.effective_date,
      p_rate: v.rate_percent,
      p_method: v.method,
      p_installments: v.installments ?? null,
      p_step_months: v.step_months ?? null,
      p_first_due: v.first_due ?? null,
      p_items: v.items ?? null,
      p_reason: v.reason,
    },
    uuidResultSchema,
  );
}

export async function cancelLoan(input: z.input<typeof cancelLoanInputSchema>): Promise<string> {
  const v = cancelLoanInputSchema.parse(input);
  return callRpc(
    "loan_cancel",
    { p_loan: v.loan_id, p_key: v.idempotency_key, p_reason: v.reason },
    uuidResultSchema,
  );
}

/** Links a loan received to the asset it paid for (information only: it posts nothing). */
export async function setLoanAsset(input: z.input<typeof setLoanAssetInputSchema>): Promise<void> {
  const v = setLoanAssetInputSchema.parse(input);
  await callRpc("loan_set_asset", { p_loan: v.loan_id, p_asset: v.asset_id }, nothing);
}

/** Loads loans at the cut-over (Step 15 §24). Returns the new loan ids in order. */
export async function loadOpeningLoans(
  input: z.input<typeof loadOpeningLoansInputSchema>,
): Promise<string[]> {
  const v = loadOpeningLoansInputSchema.parse(input);
  return callRpc(
    "loan_load_opening",
    { p_entity: v.entity_id, p_key: v.idempotency_key, p_loans: v.loans },
    uuidList,
  );
}

export async function listLoans(input: z.input<typeof loanFilterSchema>): Promise<LoanRow[]> {
  const v = loanFilterSchema.parse(input);
  return callRpc(
    "loan_list",
    {
      p_entity: v.entity_id,
      p_direction: v.direction ?? null,
      p_status: v.status ?? null,
      p_limit: v.limit ?? 100,
    },
    loanListSchema,
  );
}

export async function getLoan(loanId: string): Promise<LoanDetail> {
  return callRpc("loan_detail", { p_loan: uuid(loanId) }, loanDetailSchema);
}

/** The schedule in force, or a given version, with what each installment has been paid. */
export async function getLoanSchedule(
  input: z.input<typeof loanScheduleInputSchema>,
): Promise<LoanScheduleRow[]> {
  const v = loanScheduleInputSchema.parse(input);
  return callRpc(
    "loan_schedule",
    { p_loan: v.loan_id, p_version: v.version_no ?? null },
    loanScheduleSchema,
  );
}

/** Installments falling due (default: the next 30 days), overdue ones first by date. */
export async function loansDue(input: z.input<typeof loanDueInputSchema>): Promise<LoanDueRow[]> {
  const v = loanDueInputSchema.parse(input);
  return callRpc(
    "loan_due",
    { p_entity: v.entity_id, p_through: dateArg(v.through) },
    loanDueSchema,
  );
}

export async function loanSummary(
  input: z.input<typeof periodInputSchema>,
): Promise<LoanSummaryRow[]> {
  const v = periodInputSchema.parse(input);
  return callRpc(
    "loan_summary",
    { p_entity: v.entity_id, p_from: v.from, p_to: v.to },
    loanSummarySchema,
  );
}

// ================================================================ equity
export async function createEquityEvent(
  input: z.input<typeof createEquityEventInputSchema>,
): Promise<string> {
  const v = createEquityEventInputSchema.parse(input);
  return callRpc(
    "equity_create",
    {
      p_entity: v.entity_id,
      p_key: v.idempotency_key,
      p_kind: v.kind,
      p_date: v.date,
      p_amount: v.amount,
      p_counterparty: v.counterparty,
      p_contact: v.contact_id ?? null,
      p_purpose: v.purpose,
      p_class: v.equity_class ?? null,
      p_resolution: v.resolution_reference ?? null,
      p_related: v.related_entity_id ?? null,
      p_basis: v.relationship_basis ?? null,
    },
    uuidResultSchema,
  );
}

/** Confirms and posts the event. A capital return and a dividend need `equity.approve` and a fresh step-up. */
export async function confirmEquityEvent(
  input: z.input<typeof confirmEquityEventInputSchema>,
): Promise<string> {
  const v = confirmEquityEventInputSchema.parse(input);
  return callRpc(
    "equity_confirm",
    { p_event: v.event_id, p_key: v.idempotency_key, p_account: v.account_id ?? null },
    uuidResultSchema,
  );
}

export async function payDividend(input: z.input<typeof payDividendInputSchema>): Promise<string> {
  const v = payDividendInputSchema.parse(input);
  return callRpc(
    "equity_pay_dividend",
    {
      p_event: v.event_id,
      p_key: v.idempotency_key,
      p_date: v.date,
      p_account: v.account_id,
      p_amount: v.amount,
      p_note: v.note ?? null,
    },
    uuidResultSchema,
  );
}

export async function reverseEquityEvent(
  input: z.input<typeof reverseEquityEventInputSchema>,
): Promise<string> {
  const v = reverseEquityEventInputSchema.parse(input);
  return callRpc(
    "equity_reverse",
    { p_event: v.event_id, p_key: v.idempotency_key, p_date: v.date, p_reason: v.reason },
    uuidResultSchema,
  );
}

export async function reverseDividendPayment(
  input: z.input<typeof reverseDividendPaymentInputSchema>,
): Promise<string> {
  const v = reverseDividendPaymentInputSchema.parse(input);
  return callRpc(
    "equity_reverse_payment",
    { p_payment: v.payment_id, p_key: v.idempotency_key, p_date: v.date, p_reason: v.reason },
    uuidResultSchema,
  );
}

export async function cancelEquityEvent(
  input: z.input<typeof cancelEquityEventInputSchema>,
): Promise<string> {
  const v = cancelEquityEventInputSchema.parse(input);
  return callRpc(
    "equity_cancel",
    { p_event: v.event_id, p_key: v.idempotency_key, p_reason: v.reason },
    uuidResultSchema,
  );
}

export async function listEquityEvents(
  input: z.input<typeof equityFilterSchema>,
): Promise<EquityRow[]> {
  const v = equityFilterSchema.parse(input);
  return callRpc(
    "equity_list",
    {
      p_entity: v.entity_id,
      p_kind: v.kind ?? null,
      p_status: v.status ?? null,
      p_limit: v.limit ?? 100,
    },
    equityListSchema,
  );
}

export async function getEquityEvent(eventId: string): Promise<EquityDetail> {
  return callRpc("equity_detail", { p_event: uuid(eventId) }, equityDetailSchema);
}

export async function equitySummary(
  input: z.input<typeof periodInputSchema>,
): Promise<EquitySummaryRow[]> {
  const v = periodInputSchema.parse(input);
  return callRpc(
    "equity_summary",
    { p_entity: v.entity_id, p_from: v.from, p_to: v.to },
    equitySummarySchema,
  );
}

// ================================================================ control and tax review
/** Loans, other receivables/payables and dividends payable against their accounts in the General Ledger. */
export async function financingControl(
  input: z.input<typeof financingControlInputSchema>,
): Promise<FinancingControlRow[]> {
  const v = financingControlInputSchema.parse(input);
  return callRpc(
    "financing_control_report",
    { p_entity: v.entity_id, p_as_of: dateArg(v.as_of) },
    financingControlSchema,
  );
}

/** Loan interest, write-offs, dividends and capital returns that wait for a tax decision. */
export async function listFinancingTaxReviews(entityId: string): Promise<FinancingTaxReviewRow[]> {
  return callRpc("financing_tax_reviews", { p_entity: uuid(entityId) }, financingTaxReviewsSchema);
}

/** Records who looked at the tax treatment and what they concluded (needs `tax.confirm_facts`). */
export async function recordFinancingTaxReview(
  input: z.input<typeof recordFinancingTaxReviewInputSchema>,
): Promise<void> {
  const v = recordFinancingTaxReviewInputSchema.parse(input);
  await callRpc(
    "financing_tax_review",
    { p_entity: v.entity_id, p_source: v.source, p_id: v.source_id, p_note: v.note },
    nothing,
  );
}
