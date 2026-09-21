import { z } from "zod";
import {
  idempotencyKeySchema,
  isoDateSchema,
  moneyTextSchema,
  signedDecimalTextSchema,
} from "@/schemas/accounting";

/**
 * Input and output contracts of the financing RPCs (P8, Step 15 §12, Step 16 §16-17): other receivables and
 * payables, loans (received and given), equity (contributions, capital returns, dividends, and the Personal
 * investment events) and their controls. Money is exact decimal text; the database computes every schedule and
 * allocation, posts every entry and decides who may act (`loans.*`, `equity.*`, `equity.approve`, step-up).
 */

const reasonSchema = z.string().trim().min(5).max(1000);
const optionalText = (max: number) => z.string().trim().max(max).optional();
/** A percentage such as "12" or "9.75"; the database rejects anything above 100. */
const ratePercentSchema = z.string().regex(/^\d{1,3}(\.\d{1,4})?$/, "Bunga harus berupa persen");
const stepMonthsSchema = z.union([z.literal(1), z.literal(3), z.literal(6), z.literal(12)]);

export const taxReviewStatusSchema = z.enum(["not_applicable", "needs_review", "reviewed"]);
export const obligationKindSchema = z.enum(["receivable", "payable"]);
export const obligationStatusSchema = z.enum(["open", "settled", "void"]);
export const loanDirectionSchema = z.enum(["borrowed", "lent"]);
export const loanStatusSchema = z.enum(["draft", "active", "closed", "cancelled"]);
export const loanMethodSchema = z.enum(["annuity", "flat", "interest_only", "manual"]);
export const termClassSchema = z.enum(["short", "long"]);
export const equityKindSchema = z.enum([
  "contribution",
  "capital_return",
  "dividend",
  "investment_contribution",
  "investment_return",
  "distribution_received",
]);
export const equityStatusSchema = z.enum(["draft", "confirmed", "reversed", "cancelled"]);
export const equityClassSchema = z.enum(["capital", "additional"]);

// ================================================================ other receivables and payables
export const createObligationInputSchema = z
  .object({
    entity_id: z.uuid(),
    idempotency_key: idempotencyKeySchema,
    kind: obligationKindSchema,
    counterparty: z.string().trim().min(1).max(200),
    contact_id: z.uuid().optional(),
    date: isoDateSchema,
    due_date: isoDateSchema.optional(),
    amount: moneyTextSchema,
    /** `cash`: money moved now (an account is needed); `offset`: a non-cash origin with its counter account. */
    method: z.enum(["cash", "offset"]),
    account_id: z.uuid().optional(),
    counter_account_id: z.uuid().optional(),
    purpose: z.string().trim().min(3).max(500),
    related_entity_id: z.uuid().optional(),
    relationship_basis: optionalText(300),
  })
  .superRefine((v, ctx) => {
    if (v.method === "cash" && !v.account_id) {
      ctx.addIssue({ code: "custom", path: ["account_id"], message: "Pilih akun kas/bank" });
    }
    if (v.method === "offset" && !v.counter_account_id) {
      ctx.addIssue({ code: "custom", path: ["counter_account_id"], message: "Pilih akun lawan" });
    }
    if (v.due_date && v.due_date < v.date) {
      ctx.addIssue({ code: "custom", path: ["due_date"], message: "Jatuh tempo sebelum tanggal" });
    }
    if (v.related_entity_id && !v.relationship_basis) {
      ctx.addIssue({
        code: "custom",
        path: ["relationship_basis"],
        message: "Isi dasar hubungan dengan entitas terkait",
      });
    }
  });

export const settleObligationInputSchema = z.object({
  obligation_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  date: isoDateSchema,
  account_id: z.uuid(),
  principal: moneyTextSchema,
  interest: moneyTextSchema.default("0"),
  fee: moneyTextSchema.default("0"),
  /** Needed when interest or a fee is paid: what it is. */
  note: optionalText(1000),
});

export const writeOffObligationInputSchema = z.object({
  obligation_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  date: isoDateSchema,
  amount: moneyTextSchema,
  reason: reasonSchema,
});

export const reverseSettlementInputSchema = z.object({
  settlement_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  date: isoDateSchema,
  reason: reasonSchema,
});

export const voidObligationInputSchema = z.object({
  obligation_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  date: isoDateSchema,
  reason: reasonSchema,
});

export const obligationFilterSchema = z.object({
  entity_id: z.uuid(),
  kind: obligationKindSchema.optional(),
  status: obligationStatusSchema.optional(),
  limit: z.number().int().min(1).max(500).optional(),
});

export const obligationRowSchema = z.object({
  obligation_id: z.uuid(),
  obligation_number: z.string(),
  kind: obligationKindSchema,
  status: obligationStatusSchema,
  counterparty_name: z.string(),
  purpose: z.string(),
  obligation_date: isoDateSchema,
  due_date: isoDateSchema.nullable(),
  principal: signedDecimalTextSchema,
  outstanding: signedDecimalTextSchema,
  overdue: z.boolean(),
  source_type: z.enum(["manual", "asset_disposal"]),
  related_entity_id: z.uuid().nullable(),
  journal_id: z.uuid().nullable(),
});
export const obligationListSchema = z.array(obligationRowSchema);
export type ObligationRow = z.infer<typeof obligationRowSchema>;

const obligationSettlementSchema = z.object({
  id: z.uuid(),
  number: z.string(),
  kind: z.enum(["cash", "write_off"]),
  status: z.enum(["active", "reversed"]),
  date: isoDateSchema,
  principal: signedDecimalTextSchema,
  interest: signedDecimalTextSchema,
  fee: signedDecimalTextSchema,
  tax_status: taxReviewStatusSchema,
  journal_id: z.uuid(),
  reversal_journal_id: z.uuid().nullable(),
  note: z.string().nullable(),
});
export const obligationDetailSchema = z.object({
  id: z.uuid(),
  number: z.string(),
  kind: obligationKindSchema,
  status: obligationStatusSchema,
  counterparty: z.string(),
  contact_id: z.uuid().nullable(),
  purpose: z.string(),
  date: isoDateSchema,
  due_date: isoDateSchema.nullable(),
  principal: signedDecimalTextSchema,
  outstanding: signedDecimalTextSchema,
  recognition: z.enum(["cash", "offset", "asset_disposal"]),
  financial_account_id: z.uuid().nullable(),
  counter_account_id: z.uuid().nullable(),
  source_type: z.enum(["manual", "asset_disposal"]),
  source_id: z.uuid().nullable(),
  journal_id: z.uuid().nullable(),
  reversal_journal_id: z.uuid().nullable(),
  related_entity_id: z.uuid().nullable(),
  relationship_basis: z.string().nullable(),
  settlements: z.array(obligationSettlementSchema),
});
export type ObligationDetail = z.infer<typeof obligationDetailSchema>;

// ================================================================ loans
/** One installment of a manual schedule (or of a restructured one). Amounts default to zero. */
export const loanItemInputSchema = z.object({
  due_date: isoDateSchema,
  principal: moneyTextSchema.optional(),
  interest: moneyTextSchema.optional(),
  fee: moneyTextSchema.optional(),
});

export const createLoanInputSchema = z
  .object({
    entity_id: z.uuid(),
    idempotency_key: idempotencyKeySchema,
    direction: loanDirectionSchema,
    counterparty: z.string().trim().min(1).max(200),
    contact_id: z.uuid().optional(),
    purpose: z.string().trim().min(3).max(500),
    principal: moneyTextSchema,
    agreement_date: isoDateSchema,
    /** A company's loan received is short- or long-term; a loan given and a Personal loan have none. */
    term_class: termClassSchema.optional(),
    rate_percent: ratePercentSchema.default("0"),
    method: loanMethodSchema,
    installments: z.number().int().min(1).max(600).optional(),
    step_months: stepMonthsSchema.optional(),
    first_due: isoDateSchema.optional(),
    /** A manual schedule lists its installments; they add up to the principal. */
    items: z.array(loanItemInputSchema).min(1).max(600).optional(),
    asset_id: z.uuid().optional(),
    related_entity_id: z.uuid().optional(),
    relationship_basis: optionalText(300),
  })
  .superRefine((v, ctx) => {
    if (v.method === "manual") {
      if (!v.items)
        ctx.addIssue({ code: "custom", path: ["items"], message: "Isi daftar cicilan" });
    } else if (!v.installments || !v.first_due) {
      ctx.addIssue({
        code: "custom",
        path: ["installments"],
        message: "Isi jumlah cicilan dan tanggal pertama",
      });
    } else if (v.first_due < v.agreement_date) {
      ctx.addIssue({
        code: "custom",
        path: ["first_due"],
        message: "Cicilan pertama sebelum perjanjian",
      });
    }
    if (v.related_entity_id && !v.relationship_basis) {
      ctx.addIssue({
        code: "custom",
        path: ["relationship_basis"],
        message: "Isi dasar hubungan dengan entitas terkait",
      });
    }
  });

export const activateLoanInputSchema = z.object({
  loan_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  date: isoDateSchema,
  /** The cash or bank account the money moves through (received or paid out). */
  account_id: z.uuid(),
});

export const repayLoanInputSchema = z.object({
  loan_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  date: isoDateSchema,
  account_id: z.uuid(),
  principal: moneyTextSchema.default("0"),
  interest: moneyTextSchema.default("0"),
  fee: moneyTextSchema.default("0"),
  /** Needed when interest or a fee is paid: what it is. */
  note: optionalText(1000),
});

export const writeOffLoanInputSchema = z.object({
  loan_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  date: isoDateSchema,
  amount: moneyTextSchema,
  reason: reasonSchema,
});

export const reverseLoanPaymentInputSchema = z.object({
  payment_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  date: isoDateSchema,
  reason: reasonSchema,
});

export const restructureLoanInputSchema = z.object({
  loan_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  effective_date: isoDateSchema,
  rate_percent: ratePercentSchema.default("0"),
  method: loanMethodSchema,
  installments: z.number().int().min(1).max(600).optional(),
  step_months: stepMonthsSchema.optional(),
  first_due: isoDateSchema.optional(),
  items: z.array(loanItemInputSchema).min(1).max(600).optional(),
  reason: reasonSchema,
});

export const cancelLoanInputSchema = z.object({
  loan_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  reason: reasonSchema,
});

export const setLoanAssetInputSchema = z.object({
  loan_id: z.uuid(),
  asset_id: z.uuid().nullable(),
});

export const openingLoanSchema = z.object({
  direction: loanDirectionSchema,
  counterparty: z.string().trim().min(1).max(200),
  purpose: optionalText(500),
  agreement_date: isoDateSchema,
  cutover_date: isoDateSchema,
  /** What is still owed at the cut-over; the original principal defaults to it. */
  outstanding: moneyTextSchema,
  principal: moneyTextSchema.optional(),
  term_class: termClassSchema.optional(),
  method: loanMethodSchema.optional(),
  rate: ratePercentSchema.optional(),
  installments: z.number().int().min(1).max(600).optional(),
  step_months: stepMonthsSchema.optional(),
  first_due: isoDateSchema.optional(),
  items: z.array(loanItemInputSchema).max(600).optional(),
  asset: z.uuid().optional(),
});
export const loadOpeningLoansInputSchema = z.object({
  entity_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  loans: z.array(openingLoanSchema).min(1).max(500),
});

export const loanFilterSchema = z.object({
  entity_id: z.uuid(),
  direction: loanDirectionSchema.optional(),
  status: loanStatusSchema.optional(),
  limit: z.number().int().min(1).max(500).optional(),
});

export const loanRowSchema = z.object({
  loan_id: z.uuid(),
  loan_number: z.string(),
  direction: loanDirectionSchema,
  status: loanStatusSchema,
  counterparty_name: z.string(),
  purpose: z.string(),
  principal: signedDecimalTextSchema,
  outstanding: signedDecimalTextSchema,
  rate: signedDecimalTextSchema.nullable(),
  maturity_date: isoDateSchema.nullable(),
  next_due_date: isoDateSchema.nullable(),
  next_due_amount: signedDecimalTextSchema.nullable(),
  overdue_amount: signedDecimalTextSchema.nullable(),
  overdue: z.boolean(),
  term_class: termClassSchema.nullable(),
  asset_id: z.uuid().nullable(),
  related_entity_id: z.uuid().nullable(),
  source_type: z.enum(["proceeds", "opening"]),
});
export const loanListSchema = z.array(loanRowSchema);
export type LoanRow = z.infer<typeof loanRowSchema>;

export const scheduleItemStateSchema = z.enum(["paid", "partially_paid", "due", "scheduled"]);
export const loanScheduleRowSchema = z.object({
  version_no: z.number().int().positive(),
  seq: z.number().int().positive(),
  due_date: isoDateSchema,
  principal_due: signedDecimalTextSchema,
  interest_due: signedDecimalTextSchema,
  fee_due: signedDecimalTextSchema,
  paid_principal: signedDecimalTextSchema,
  paid_interest: signedDecimalTextSchema,
  paid_fee: signedDecimalTextSchema,
  outstanding: signedDecimalTextSchema,
  state: scheduleItemStateSchema,
  overdue: z.boolean(),
});
export const loanScheduleSchema = z.array(loanScheduleRowSchema);
export type LoanScheduleRow = z.infer<typeof loanScheduleRowSchema>;

export const loanScheduleInputSchema = z.object({
  loan_id: z.uuid(),
  version_no: z.number().int().positive().optional(),
});

const loanPaymentSchema = z.object({
  id: z.uuid(),
  number: z.string(),
  kind: z.enum(["repayment", "write_off"]),
  status: z.enum(["active", "reversed"]),
  date: isoDateSchema,
  principal: signedDecimalTextSchema,
  interest: signedDecimalTextSchema,
  fee: signedDecimalTextSchema,
  tax_status: taxReviewStatusSchema,
  journal_id: z.uuid(),
  reversal_journal_id: z.uuid().nullable(),
  note: z.string().nullable(),
  schedule_version_id: z.uuid(),
  allocations: z.array(
    z.object({
      item_id: z.uuid().nullable(),
      seq: z.number().int().nullable(),
      principal: signedDecimalTextSchema,
      interest: signedDecimalTextSchema,
      fee: signedDecimalTextSchema,
    }),
  ),
});
export const loanDetailSchema = z.object({
  id: z.uuid(),
  number: z.string(),
  direction: loanDirectionSchema,
  status: loanStatusSchema,
  counterparty: z.string(),
  contact_id: z.uuid().nullable(),
  purpose: z.string(),
  principal: signedDecimalTextSchema,
  funded_principal: signedDecimalTextSchema,
  outstanding: signedDecimalTextSchema,
  source_type: z.enum(["proceeds", "opening"]),
  agreement_date: isoDateSchema,
  effective_date: isoDateSchema.nullable(),
  closed_date: isoDateSchema.nullable(),
  term_class: termClassSchema.nullable(),
  principal_account_id: z.uuid(),
  financial_account_id: z.uuid().nullable(),
  proceeds_journal_id: z.uuid().nullable(),
  asset_id: z.uuid().nullable(),
  related_entity_id: z.uuid().nullable(),
  relationship_basis: z.string().nullable(),
  cancel_reason: z.string().nullable(),
  versions: z.array(
    z.object({
      id: z.uuid(),
      version_no: z.number().int().positive(),
      status: z.enum(["draft", "active", "superseded"]),
      method: loanMethodSchema,
      rate: signedDecimalTextSchema,
      installments: z.number().int().nullable(),
      step_months: z.number().int().nullable(),
      effective_from: isoDateSchema.nullable(),
      principal_basis: signedDecimalTextSchema,
      maturity_date: isoDateSchema.nullable(),
      reason: z.string().nullable(),
    }),
  ),
  payments: z.array(loanPaymentSchema),
});
export type LoanDetail = z.infer<typeof loanDetailSchema>;

export const loanDueInputSchema = z.object({
  entity_id: z.uuid(),
  through: isoDateSchema.optional(),
});
export const loanDueRowSchema = z.object({
  loan_id: z.uuid(),
  loan_number: z.string(),
  direction: loanDirectionSchema,
  counterparty_name: z.string(),
  seq: z.number().int().positive(),
  due_date: isoDateSchema,
  principal_outstanding: signedDecimalTextSchema,
  interest_outstanding: signedDecimalTextSchema,
  fee_outstanding: signedDecimalTextSchema,
  state: scheduleItemStateSchema,
  overdue: z.boolean(),
  days_overdue: z.number().int().nonnegative(),
});
export const loanDueSchema = z.array(loanDueRowSchema);
export type LoanDueRow = z.infer<typeof loanDueRowSchema>;

export const periodInputSchema = z
  .object({ entity_id: z.uuid(), from: isoDateSchema, to: isoDateSchema })
  .refine((v) => v.to >= v.from, { path: ["to"], message: "Periode tidak valid" });

export const loanSummaryRowSchema = z.object({
  loan_id: z.uuid(),
  loan_number: z.string(),
  direction: loanDirectionSchema,
  counterparty_name: z.string(),
  opening_principal: signedDecimalTextSchema,
  proceeds: signedDecimalTextSchema,
  principal_repaid: signedDecimalTextSchema,
  principal_written_off: signedDecimalTextSchema,
  closing_principal: signedDecimalTextSchema,
  interest_paid: signedDecimalTextSchema,
  fees_paid: signedDecimalTextSchema,
});
export const loanSummarySchema = z.array(loanSummaryRowSchema);
export type LoanSummaryRow = z.infer<typeof loanSummaryRowSchema>;

// ================================================================ equity
export const createEquityEventInputSchema = z
  .object({
    entity_id: z.uuid(),
    idempotency_key: idempotencyKeySchema,
    kind: equityKindSchema,
    date: isoDateSchema,
    amount: moneyTextSchema,
    counterparty: z.string().trim().min(1).max(200),
    contact_id: z.uuid().optional(),
    purpose: z.string().trim().min(3).max(500),
    /** `capital` (paid-in) or `additional` (share premium and the like); for contributions and capital returns. */
    equity_class: equityClassSchema.optional(),
    /** The shareholders' resolution (RUPS) that approved a capital return or dividend. */
    resolution_reference: optionalText(200),
    related_entity_id: z.uuid().optional(),
    relationship_basis: optionalText(300),
  })
  .superRefine((v, ctx) => {
    if (v.related_entity_id && !v.relationship_basis) {
      ctx.addIssue({
        code: "custom",
        path: ["relationship_basis"],
        message: "Isi dasar hubungan dengan entitas terkait",
      });
    }
  });

/** Cash events name the cash or bank account; a dividend is only declared here and paid with `payDividend`. */
export const confirmEquityEventInputSchema = z.object({
  event_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  account_id: z.uuid().optional(),
});

export const payDividendInputSchema = z.object({
  event_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  date: isoDateSchema,
  account_id: z.uuid(),
  amount: moneyTextSchema,
  note: optionalText(1000),
});

export const reverseEquityEventInputSchema = z.object({
  event_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  date: isoDateSchema,
  reason: reasonSchema,
});

export const reverseDividendPaymentInputSchema = z.object({
  payment_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  date: isoDateSchema,
  reason: reasonSchema,
});

export const cancelEquityEventInputSchema = z.object({
  event_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  reason: reasonSchema,
});

export const equityFilterSchema = z.object({
  entity_id: z.uuid(),
  kind: equityKindSchema.optional(),
  status: equityStatusSchema.optional(),
  limit: z.number().int().min(1).max(500).optional(),
});

export const equityRowSchema = z.object({
  event_id: z.uuid(),
  event_number: z.string(),
  kind: equityKindSchema,
  status: equityStatusSchema,
  event_date: isoDateSchema,
  amount: signedDecimalTextSchema,
  counterparty_name: z.string(),
  purpose: z.string(),
  equity_class: equityClassSchema.nullable(),
  resolution_reference: z.string().nullable(),
  /** For a dividend: what is declared but not yet paid. */
  outstanding: signedDecimalTextSchema.nullable(),
  /** A dividend beyond the profit available is allowed, but flagged. */
  exceeds_retained_earnings: z.boolean().nullable(),
  tax_status: taxReviewStatusSchema,
  related_entity_id: z.uuid().nullable(),
  journal_id: z.uuid().nullable(),
});
export const equityListSchema = z.array(equityRowSchema);
export type EquityRow = z.infer<typeof equityRowSchema>;

export const equityDetailSchema = z.object({
  id: z.uuid(),
  number: z.string(),
  kind: equityKindSchema,
  status: equityStatusSchema,
  date: isoDateSchema,
  amount: signedDecimalTextSchema,
  equity_class: equityClassSchema.nullable(),
  counterparty: z.string(),
  contact_id: z.uuid().nullable(),
  purpose: z.string(),
  resolution_reference: z.string().nullable(),
  financial_account_id: z.uuid().nullable(),
  journal_id: z.uuid().nullable(),
  retained_available: signedDecimalTextSchema.nullable(),
  exceeds_retained_earnings: z.boolean().nullable(),
  tax_status: taxReviewStatusSchema,
  reversal_journal_id: z.uuid().nullable(),
  reverse_reason: z.string().nullable(),
  cancel_reason: z.string().nullable(),
  related_entity_id: z.uuid().nullable(),
  relationship_basis: z.string().nullable(),
  outstanding: signedDecimalTextSchema.nullable(),
  payments: z.array(
    z.object({
      id: z.uuid(),
      number: z.string(),
      status: z.enum(["active", "reversed"]),
      date: isoDateSchema,
      amount: signedDecimalTextSchema,
      financial_account_id: z.uuid(),
      tax_status: taxReviewStatusSchema,
      journal_id: z.uuid(),
      reversal_journal_id: z.uuid().nullable(),
      note: z.string().nullable(),
    }),
  ),
});
export type EquityDetail = z.infer<typeof equityDetailSchema>;

export const equitySummaryRowSchema = z.object({
  metric: z.string(),
  events: z.coerce.number().int().nonnegative(),
  amount: signedDecimalTextSchema,
});
export const equitySummarySchema = z.array(equitySummaryRowSchema);
export type EquitySummaryRow = z.infer<typeof equitySummaryRowSchema>;

// ================================================================ control and tax review
export const financingControlInputSchema = z.object({
  entity_id: z.uuid(),
  as_of: isoDateSchema.optional(),
});
export const financingControlRowSchema = z.object({
  account_key: z.string(),
  sub_ledger: signedDecimalTextSchema,
  ledger_total: signedDecimalTextSchema,
  difference: signedDecimalTextSchema,
});
export const financingControlSchema = z.array(financingControlRowSchema);
export type FinancingControlRow = z.infer<typeof financingControlRowSchema>;

export const taxReviewSourceSchema = z.enum([
  "obligation_settlement",
  "loan_payment",
  "equity_event",
  "dividend_payment",
]);
export const financingTaxReviewRowSchema = z.object({
  source_type: taxReviewSourceSchema,
  source_id: z.uuid(),
  document_number: z.string(),
  event_date: isoDateSchema,
  amount: signedDecimalTextSchema,
  description: z.string(),
});
export const financingTaxReviewsSchema = z.array(financingTaxReviewRowSchema);
export type FinancingTaxReviewRow = z.infer<typeof financingTaxReviewRowSchema>;

/** Needs `tax.confirm_facts`. Records that the tax treatment was looked at and what was concluded; posts nothing. */
export const recordFinancingTaxReviewInputSchema = z.object({
  entity_id: z.uuid(),
  source: taxReviewSourceSchema,
  source_id: z.uuid(),
  note: z.string().trim().min(5).max(1000),
});
