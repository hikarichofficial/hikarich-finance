import { z } from "zod";
import {
  exchangeRateTextSchema,
  idempotencyKeySchema,
  isoDateSchema,
  moneyTextSchema,
  signedDecimalTextSchema,
} from "@/schemas/accounting";

/**
 * Input and output contracts of the sales RPCs (P5): customers, invoices, payments, refunds, public links and
 * the accounts-receivable reports. Money is always exact decimal text (Step 13 §25); the database recomputes
 * every figure and never trusts a total sent by the caller.
 */

const optionalText = (max: number) => z.string().trim().max(max).optional();
const reasonSchema = z.string().trim().min(5).max(500);

// ---- customers
export const contactKindSchema = z.enum(["customer", "vendor", "both"]);

export const createContactInputSchema = z.object({
  entity_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  kind: contactKindSchema,
  display_name: z.string().trim().min(1).max(200),
  email: optionalText(200),
  phone: optionalText(40),
  tax_identifier: optionalText(40),
  legal_name: optionalText(200),
  address_line: optionalText(300),
  city: optionalText(100),
  country_code: z
    .string()
    .regex(/^[A-Z]{2}$/)
    .optional(),
  notes: optionalText(1000),
  /** The person's explicit confirmation that a similar name is a different party. */
  allow_similar_name: z.boolean().optional(),
});

export const findContactDuplicatesInputSchema = z.object({
  entity_id: z.uuid(),
  name: optionalText(200),
  email: optionalText(200),
  phone: optionalText(40),
  tax_identifier: optionalText(40),
  exclude_contact_id: z.uuid().optional(),
});

export const contactDuplicateSchema = z.object({
  contact_id: z.uuid(),
  display_name: z.string(),
  kind: z.string(),
  severity: z.enum(["exact", "suspected"]),
  reason: z.string(),
});
export const contactDuplicatesSchema = z.array(contactDuplicateSchema);
export type ContactDuplicate = z.infer<typeof contactDuplicateSchema>;

// ---- invoices
export const discountTypeSchema = z.enum(["none", "percent", "fixed"]);

export const invoiceLineInputSchema = z.object({
  product_id: z.uuid().optional(),
  description: z.string().trim().max(500).optional(),
  quantity: z
    .string()
    .regex(/^\d{1,9}(\.\d{1,4})?$/)
    .optional(),
  unit_price: moneyTextSchema.optional(),
  discount_type: discountTypeSchema.optional(),
  discount_value: z
    .string()
    .regex(/^\d{1,16}(\.\d{1,4})?$/)
    .optional(),
  category_id: z.uuid().optional(),
});
export type InvoiceLineInput = z.infer<typeof invoiceLineInputSchema>;

const invoiceHeaderFields = {
  customer_id: z.uuid(),
  issue_date: isoDateSchema,
  due_date: isoDateSchema,
  currency: z
    .string()
    .regex(/^[A-Z]{3}$/)
    .optional(),
  exchange_rate: exchangeRateTextSchema.optional(),
  notes: optionalText(2000),
  terms: optionalText(4000),
  payment_note: optionalText(1000),
  internal_note: optionalText(2000),
  payment_account_id: z.uuid().optional(),
  payment_channel_id: z.uuid().optional(),
};

export const createInvoiceDraftInputSchema = z
  .object({
    entity_id: z.uuid(),
    idempotency_key: idempotencyKeySchema,
    ...invoiceHeaderFields,
    lines: z.array(invoiceLineInputSchema).max(200).default([]),
  })
  .refine((v) => v.due_date >= v.issue_date, {
    path: ["due_date"],
    message: "Jatuh tempo sebelum tanggal faktur",
  });

/** Only the named fields change; `lines`, when present, replaces all lines. */
export const updateInvoiceDraftInputSchema = z.object({
  invoice_id: z.uuid(),
  expected_version: z.number().int().positive().optional(),
  patch: z
    .object({
      customer_id: z.uuid().optional(),
      issue_date: isoDateSchema.optional(),
      due_date: isoDateSchema.optional(),
      currency: z
        .string()
        .regex(/^[A-Z]{3}$/)
        .optional(),
      exchange_rate: exchangeRateTextSchema.nullable().optional(),
      notes: z.string().trim().max(2000).nullable().optional(),
      terms: z.string().trim().max(4000).nullable().optional(),
      payment_note: z.string().trim().max(1000).nullable().optional(),
      internal_note: z.string().trim().max(2000).nullable().optional(),
      payment_account_id: z.uuid().nullable().optional(),
      payment_channel_id: z.uuid().nullable().optional(),
      lines: z.array(invoiceLineInputSchema).max(200).optional(),
    })
    .refine((p) => Object.keys(p).length > 0, "Tidak ada perubahan"),
});

export const issueInvoiceInputSchema = z.object({
  invoice_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
});

export const closeInvoiceInputSchema = z.object({
  invoice_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  reason: reasonSchema,
  /** Effective date of the reversal; defaults to today in the Entity's time zone. */
  date: isoDateSchema.optional(),
});

export const updateDueDateInputSchema = z.object({
  invoice_id: z.uuid(),
  due_date: isoDateSchema,
  reason: reasonSchema,
});

// ---- payments
export const paymentAllocationInputSchema = z.object({
  invoice_id: z.uuid(),
  amount: moneyTextSchema,
});

export const recordPaymentInputSchema = z.object({
  entity_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  customer_id: z.uuid(),
  account_id: z.uuid(),
  payment_date: isoDateSchema,
  amount: moneyTextSchema,
  allocations: z.array(paymentAllocationInputSchema).max(100),
  exchange_rate: exchangeRateTextSchema.optional(),
  reference: optionalText(200),
  payer_name: optionalText(200),
  channel_id: z.uuid().optional(),
  /** The explicit choice to keep any excess over the allocations as a customer advance. */
  allow_advance: z.boolean().optional(),
  note: optionalText(1000),
});

export const createPaymentClaimInputSchema = z.object({
  invoice_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  amount: moneyTextSchema,
  payment_date: isoDateSchema,
  payer_name: optionalText(200),
  reference: optionalText(200),
  channel_id: z.uuid().optional(),
  note: optionalText(1000),
});

export const confirmSubmissionInputSchema = z.object({
  submission_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  account_id: z.uuid().optional(),
  payment_date: isoDateSchema.optional(),
  amount: moneyTextSchema.optional(),
  exchange_rate: exchangeRateTextSchema.optional(),
  allow_advance: z.boolean().optional(),
  note: optionalText(1000),
});

export const rejectSubmissionInputSchema = z.object({
  submission_id: z.uuid(),
  reason: reasonSchema,
});

export const markDuplicateInputSchema = z.object({
  submission_id: z.uuid(),
  duplicate_of_id: z.uuid(),
  reason: reasonSchema,
});

export const applyPaymentCreditInputSchema = z.object({
  payment_id: z.uuid(),
  invoice_id: z.uuid(),
  amount: moneyTextSchema,
  idempotency_key: idempotencyKeySchema,
  date: isoDateSchema.optional(),
});

export const reverseCreditApplicationInputSchema = z.object({
  allocation_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  date: isoDateSchema,
  reason: reasonSchema,
});

export const reversePaymentInputSchema = z.object({
  payment_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  date: isoDateSchema,
  reason: reasonSchema,
});

// ---- refunds
export const refundItemInputSchema = z.discriminatedUnion("source", [
  z.object({ source: z.literal("allocation"), allocation_id: z.uuid(), amount: moneyTextSchema }),
  z.object({ source: z.literal("advance"), amount: moneyTextSchema }),
]);

export const createRefundInputSchema = z.object({
  payment_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  account_id: z.uuid(),
  refund_date: isoDateSchema,
  items: z.array(refundItemInputSchema).min(1).max(100),
  exchange_rate: exchangeRateTextSchema.optional(),
  reason: optionalText(500),
  customer_reason: optionalText(500),
  reference: optionalText(200),
  /** Confirming needs refunds.confirm (OWNER); a draft reserves nothing. */
  confirm: z.boolean().optional(),
});

export const confirmRefundInputSchema = z.object({
  refund_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
});

export const refundReasonInputSchema = z.object({
  refund_id: z.uuid(),
  reason: reasonSchema,
});

export const reverseRefundInputSchema = z.object({
  refund_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  date: isoDateSchema,
  reason: reasonSchema,
});

// ---- public links
export const regenerateLinkInputSchema = z.object({
  invoice_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  expires_at: z.iso.datetime({ offset: true }).optional(),
});

export const revokeLinkInputSchema = z.object({
  invoice_id: z.uuid(),
  reason: reasonSchema,
});

export const setLinkExpiryInputSchema = z.object({
  invoice_id: z.uuid(),
  expires_at: z.iso.datetime({ offset: true }).nullable(),
});

/** A public token is 40-120 URL-safe characters; anything else is treated as unavailable without a lookup. */
export const publicTokenSchema = z
  .string()
  .min(40)
  .max(120)
  .regex(/^[A-Za-z0-9_-]+$/);

export const publicClaimInputSchema = z.object({
  token: publicTokenSchema,
  amount: moneyTextSchema,
  payment_date: isoDateSchema,
  payer_name: z.string().trim().max(200).optional(),
  reference: z.string().trim().max(200).optional(),
  note: z.string().trim().max(1000).optional(),
});

// ---- RPC results
export const invoicePositionSchema = z.object({
  invoice_id: z.uuid(),
  invoice_number: z.string().nullable(),
  customer_id: z.uuid(),
  customer_name: z.string(),
  currency: z.string(),
  status: z.enum(["draft", "issued", "cancelled", "void"]),
  issue_date: isoDateSchema,
  due_date: isoDateSchema,
  total: signedDecimalTextSchema,
  settled: signedDecimalTextSchema,
  outstanding: signedDecimalTextSchema,
  base_outstanding: signedDecimalTextSchema,
  refunded: signedDecimalTextSchema,
  settlement_status: z.enum(["unpaid", "partial", "paid"]).nullable(),
  refund_status: z.string().nullable(),
  is_overdue: z.boolean(),
  days_overdue: z.number().int().nonnegative(),
});
export const invoicePositionsSchema = z.array(invoicePositionSchema);
export type InvoicePosition = z.infer<typeof invoicePositionSchema>;

export const invoiceFilterSchema = z.enum([
  "open",
  "overdue",
  "paid",
  "unpaid",
  "partial",
  "closed",
]);
export type InvoiceFilter = z.infer<typeof invoiceFilterSchema>;

export const paymentListRowSchema = z.object({
  payment_id: z.uuid(),
  payment_number: z.string(),
  status: z.enum(["confirmed", "reversed"]),
  payment_date: isoDateSchema,
  customer_id: z.uuid(),
  customer_name: z.string(),
  currency: z.string(),
  amount: signedDecimalTextSchema,
  allocated_amount: signedDecimalTextSchema,
  advance_remaining: signedDecimalTextSchema.nullable(),
  refunded: signedDecimalTextSchema,
  refundable: signedDecimalTextSchema,
  refund_status: z.enum(["none", "partial", "full"]),
  reference: z.string().nullable(),
});
export const paymentListSchema = z.array(paymentListRowSchema);
export type PaymentListRow = z.infer<typeof paymentListRowSchema>;

export const refundOptionSchema = z.object({
  source: z.enum(["allocation", "advance"]),
  allocation_id: z.uuid().nullable(),
  invoice_number: z.string().nullable(),
  refundable: signedDecimalTextSchema,
  currency: z.string(),
});
export const refundOptionsSchema = z.array(refundOptionSchema);
export type RefundOption = z.infer<typeof refundOptionSchema>;

export const arAgingRowSchema = z.object({
  customer_id: z.uuid(),
  customer_name: z.string(),
  not_due: signedDecimalTextSchema,
  days_1_30: signedDecimalTextSchema,
  days_31_60: signedDecimalTextSchema,
  days_61_90: signedDecimalTextSchema,
  days_over_90: signedDecimalTextSchema,
  total: signedDecimalTextSchema,
  invoice_count: z.coerce.number().int().nonnegative(),
});
export const arAgingSchema = z.array(arAgingRowSchema);
export type ArAgingRow = z.infer<typeof arAgingRowSchema>;

export const arControlRowSchema = z.object({
  sub_ledger: signedDecimalTextSchema,
  ledger_sales: signedDecimalTextSchema,
  ledger_total: signedDecimalTextSchema,
  difference: signedDecimalTextSchema,
  other_ledger: signedDecimalTextSchema,
  advance_sub_ledger: signedDecimalTextSchema,
  advance_ledger_sales: signedDecimalTextSchema,
  advance_ledger_total: signedDecimalTextSchema,
  advance_difference: signedDecimalTextSchema,
});
export const arControlSchema = z.array(arControlRowSchema);
export type ArControlRow = z.infer<typeof arControlRowSchema>;

export const invoiceLinkSchema = z.object({
  token: z.string(),
  status: z.enum(["active", "revoked"]),
  expires_at: z.string().nullable(),
});
export const invoiceLinkRowsSchema = z.array(invoiceLinkSchema);

// ---- documents (what a customer or staff member reads)
const partySchema = z.record(z.string(), z.unknown()).nullable();

export const documentLineSchema = z.object({
  line_no: z.number().int(),
  description: z.string(),
  quantity: z.string(),
  unit_price: z.string(),
  discount_type: discountTypeSchema,
  discount_value: z.string(),
  discount_amount: z.string(),
  tax_amount: z.string(),
  line_total: z.string(),
});

export const invoiceDocumentSchema = z.object({
  invoice_number: z.string().nullable(),
  status: z.enum(["draft", "issued", "cancelled", "void"]),
  issue_date: isoDateSchema,
  due_date: isoDateSchema,
  currency: z.string(),
  subtotal: z.string(),
  discount_total: z.string(),
  tax_total: z.string(),
  total: z.string(),
  settled: z.string(),
  outstanding: z.string(),
  settlement_status: z.enum(["unpaid", "partial", "paid"]).nullable(),
  is_overdue: z.boolean(),
  refunded: z.string(),
  notes: z.string().nullable(),
  terms: z.string().nullable(),
  payment_note: z.string().nullable(),
  issuer: partySchema,
  customer: partySchema,
  payment_instructions: partySchema.optional(),
  lines: z.array(documentLineSchema),
  payments: z.array(
    z.object({
      receipt_number: z.string(),
      payment_date: isoDateSchema,
      amount: z.string(),
      currency: z.string(),
    }),
  ),
});
export type InvoiceDocument = z.infer<typeof invoiceDocumentSchema>;

export const publicInvoiceViewSchema = z.discriminatedUnion("state", [
  z.object({ state: z.literal("unavailable") }),
  z.object({
    state: z.literal("ok"),
    invoice: invoiceDocumentSchema,
    pending_claim: z.boolean(),
    can_claim: z.boolean(),
  }),
]);
export type PublicInvoiceView = z.infer<typeof publicInvoiceViewSchema>;

export const publicClaimResultSchema = z.object({
  state: z.literal("pending"),
  already_received: z.boolean(),
});

export const receiptDocumentSchema = z.object({
  document: z.literal("payment_receipt").optional(),
  receipt_number: z.string(),
  status: z.enum(["confirmed", "reversed"]),
  payment_date: isoDateSchema,
  amount: z.string(),
  currency: z.string(),
  reference: z.string().nullable(),
  issuer: partySchema,
  customer: partySchema,
  method: z.record(z.string(), z.unknown()).nullable(),
  allocations: z.array(z.record(z.string(), z.unknown())),
  refunded: z.string(),
});
export type ReceiptDocument = z.infer<typeof receiptDocumentSchema>;

export const publicReceiptViewSchema = z.discriminatedUnion("state", [
  z.object({ state: z.literal("unavailable") }),
  z.object({ state: z.literal("ok"), receipt: receiptDocumentSchema }),
]);
export type PublicReceiptView = z.infer<typeof publicReceiptViewSchema>;
