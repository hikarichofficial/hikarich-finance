import "server-only";
import { z, type ZodType } from "zod";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { AuthzError, parseAuthzCode } from "@/domain/authz/errors";
import { isoDateSchema, uuidResultSchema } from "@/schemas/accounting";
import {
  applyPaymentCreditInputSchema,
  arAgingSchema,
  arControlSchema,
  closeInvoiceInputSchema,
  confirmRefundInputSchema,
  confirmSubmissionInputSchema,
  contactDuplicatesSchema,
  createContactInputSchema,
  createInvoiceDraftInputSchema,
  createPaymentClaimInputSchema,
  createRefundInputSchema,
  findContactDuplicatesInputSchema,
  invoiceDocumentSchema,
  invoiceFilterSchema,
  invoiceLinkRowsSchema,
  invoicePositionsSchema,
  issueInvoiceInputSchema,
  markDuplicateInputSchema,
  paymentListSchema,
  receiptDocumentSchema,
  recordPaymentInputSchema,
  refundOptionsSchema,
  refundReasonInputSchema,
  regenerateLinkInputSchema,
  rejectSubmissionInputSchema,
  reverseCreditApplicationInputSchema,
  reversePaymentInputSchema,
  reverseRefundInputSchema,
  revokeLinkInputSchema,
  setLinkExpiryInputSchema,
  updateDueDateInputSchema,
  updateInvoiceDraftInputSchema,
  type ArAgingRow,
  type ArControlRow,
  type ContactDuplicate,
  type InvoiceDocument,
  type InvoiceFilter,
  type InvoicePosition,
  type PaymentListRow,
  type ReceiptDocument,
  type RefundOption,
} from "@/schemas/sales";

/**
 * Thin, typed wrappers over the sales RPCs (P5). Every call runs as the signed-in person; the database decides
 * who may do what per Entity and enforces every rule (arithmetic, numbering, posting, periods, allocations,
 * refund limits, approval, idempotency, immutability) inside the transaction. This layer validates the input
 * shape, maps the database's error prefixes to AuthzError without leaking detail, and validates what comes
 * back. It holds no sales rules of its own (Step 04, Step 07, Step 08, Step 13 §9). The exact arithmetic that
 * screens use for early feedback lives in `@/domain/sales`.
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
    throw new Error("Operasi penjualan gagal diproses.");
  }
  const parsed = schema.safeParse(data);
  if (!parsed.success) throw new Error("Respons penjualan tidak dikenali.");
  return parsed.data;
}

const uuid = (value: string) => uuidResultSchema.parse(value);
const asOfArg = (asOf?: string) => (asOf ? isoDateSchema.parse(asOf) : null);

// ---- customers
export async function findContactDuplicates(
  input: z.input<typeof findContactDuplicatesInputSchema>,
): Promise<ContactDuplicate[]> {
  const v = findContactDuplicatesInputSchema.parse(input);
  return callRpc(
    "find_contact_duplicates",
    {
      p_entity: v.entity_id,
      p_name: v.name ?? null,
      p_email: v.email ?? null,
      p_phone: v.phone ?? null,
      p_tax_identifier: v.tax_identifier ?? null,
      p_exclude: v.exclude_contact_id ?? null,
    },
    contactDuplicatesSchema,
  );
}

export async function createContact(
  input: z.input<typeof createContactInputSchema>,
): Promise<string> {
  const v = createContactInputSchema.parse(input);
  return callRpc(
    "create_contact",
    {
      p_entity: v.entity_id,
      p_key: v.idempotency_key,
      p_kind: v.kind,
      p_display_name: v.display_name,
      p_email: v.email ?? null,
      p_phone: v.phone ?? null,
      p_tax_identifier: v.tax_identifier ?? null,
      p_legal_name: v.legal_name ?? null,
      p_address_line: v.address_line ?? null,
      p_city: v.city ?? null,
      p_country_code: v.country_code ?? null,
      p_notes: v.notes ?? null,
      p_allow_similar_name: v.allow_similar_name ?? false,
    },
    uuidResultSchema,
  );
}

// ---- invoices
export async function createInvoiceDraft(
  input: z.input<typeof createInvoiceDraftInputSchema>,
): Promise<string> {
  const v = createInvoiceDraftInputSchema.parse(input);
  return callRpc(
    "create_invoice_draft",
    {
      p_entity: v.entity_id,
      p_key: v.idempotency_key,
      p_customer: v.customer_id,
      p_issue_date: v.issue_date,
      p_due_date: v.due_date,
      p_lines: v.lines,
      p_currency: v.currency ?? null,
      p_rate: v.exchange_rate ?? null,
      p_notes: v.notes ?? null,
      p_terms: v.terms ?? null,
      p_payment_note: v.payment_note ?? null,
      p_internal_note: v.internal_note ?? null,
      p_payment_account: v.payment_account_id ?? null,
      p_payment_channel: v.payment_channel_id ?? null,
    },
    uuidResultSchema,
  );
}

/** Returns the new version number. A stale `expected_version` is refused (Step 08 §18). */
export async function updateInvoiceDraft(
  input: z.input<typeof updateInvoiceDraftInputSchema>,
): Promise<number> {
  const v = updateInvoiceDraftInputSchema.parse(input);
  return callRpc(
    "update_invoice_draft",
    { p_invoice: v.invoice_id, p_patch: v.patch, p_expected_version: v.expected_version ?? null },
    z.number().int(),
  );
}

/** Numbers the invoice, freezes its snapshots and posts it to the ledger in one transaction. */
export async function issueInvoice(
  input: z.input<typeof issueInvoiceInputSchema>,
): Promise<string> {
  const v = issueInvoiceInputSchema.parse(input);
  return callRpc(
    "issue_invoice",
    { p_invoice: v.invoice_id, p_key: v.idempotency_key },
    uuidResultSchema,
  );
}

/** Cancels an issued invoice that has no payment allocated (reversal journal). Returns the reversal journal id. */
export async function cancelInvoice(
  input: z.input<typeof closeInvoiceInputSchema>,
): Promise<string> {
  const v = closeInvoiceInputSchema.parse(input);
  return callRpc(
    "cancel_invoice",
    {
      p_invoice: v.invoice_id,
      p_key: v.idempotency_key,
      p_reason: v.reason,
      p_date: v.date ?? null,
    },
    uuidResultSchema,
  );
}

export async function voidInvoice(input: z.input<typeof closeInvoiceInputSchema>): Promise<string> {
  const v = closeInvoiceInputSchema.parse(input);
  return callRpc(
    "void_invoice",
    {
      p_invoice: v.invoice_id,
      p_key: v.idempotency_key,
      p_reason: v.reason,
      p_date: v.date ?? null,
    },
    uuidResultSchema,
  );
}

/** Voids the invoice and creates a replacement draft with the same content. Returns the new invoice id. */
export async function correctInvoice(
  input: z.input<typeof closeInvoiceInputSchema>,
): Promise<string> {
  const v = closeInvoiceInputSchema.parse(input);
  return callRpc(
    "correct_invoice",
    {
      p_invoice: v.invoice_id,
      p_key: v.idempotency_key,
      p_reason: v.reason,
      p_date: v.date ?? null,
    },
    uuidResultSchema,
  );
}

export async function updateInvoiceDueDate(
  input: z.input<typeof updateDueDateInputSchema>,
): Promise<string> {
  const v = updateDueDateInputSchema.parse(input);
  return callRpc(
    "update_invoice_due_date",
    { p_invoice: v.invoice_id, p_due_date: v.due_date, p_reason: v.reason },
    isoDateSchema,
  );
}

export async function listInvoicePositions(
  entityId: string,
  options: { filter?: InvoiceFilter; customerId?: string; asOf?: string } = {},
): Promise<InvoicePosition[]> {
  return callRpc(
    "list_invoice_positions",
    {
      p_entity: uuid(entityId),
      p_filter: options.filter ? invoiceFilterSchema.parse(options.filter) : null,
      p_customer: options.customerId ? uuid(options.customerId) : null,
      p_as_of: asOfArg(options.asOf),
    },
    invoicePositionsSchema,
  );
}

export async function getInvoiceDocument(invoiceId: string): Promise<InvoiceDocument> {
  return callRpc("invoice_document", { p_invoice: uuid(invoiceId) }, invoiceDocumentSchema);
}

// ---- payments
export async function recordPayment(
  input: z.input<typeof recordPaymentInputSchema>,
): Promise<string> {
  const v = recordPaymentInputSchema.parse(input);
  return callRpc(
    "record_payment",
    {
      p_entity: v.entity_id,
      p_key: v.idempotency_key,
      p_customer: v.customer_id,
      p_account: v.account_id,
      p_date: v.payment_date,
      p_amount: v.amount,
      p_allocations: v.allocations,
      p_rate: v.exchange_rate ?? null,
      p_reference: v.reference ?? null,
      p_payer_name: v.payer_name ?? null,
      p_channel: v.channel_id ?? null,
      p_allow_advance: v.allow_advance ?? false,
      p_note: v.note ?? null,
    },
    uuidResultSchema,
  );
}

/** A claim recorded by staff on a customer's behalf; it has no accounting effect until confirmed. */
export async function createPaymentClaim(
  input: z.input<typeof createPaymentClaimInputSchema>,
): Promise<string> {
  const v = createPaymentClaimInputSchema.parse(input);
  return callRpc(
    "create_payment_claim",
    {
      p_invoice: v.invoice_id,
      p_key: v.idempotency_key,
      p_amount: v.amount,
      p_date: v.payment_date,
      p_payer_name: v.payer_name ?? null,
      p_reference: v.reference ?? null,
      p_channel: v.channel_id ?? null,
      p_note: v.note ?? null,
    },
    uuidResultSchema,
  );
}

/** Confirms a pending claim after the money is verified; returns the payment id. */
export async function confirmPaymentSubmission(
  input: z.input<typeof confirmSubmissionInputSchema>,
): Promise<string> {
  const v = confirmSubmissionInputSchema.parse(input);
  return callRpc(
    "confirm_payment_submission",
    {
      p_submission: v.submission_id,
      p_key: v.idempotency_key,
      p_account: v.account_id ?? null,
      p_date: v.payment_date ?? null,
      p_amount: v.amount ?? null,
      p_rate: v.exchange_rate ?? null,
      p_allow_advance: v.allow_advance ?? false,
      p_note: v.note ?? null,
    },
    uuidResultSchema,
  );
}

export async function rejectPaymentSubmission(
  input: z.input<typeof rejectSubmissionInputSchema>,
): Promise<string> {
  const v = rejectSubmissionInputSchema.parse(input);
  return callRpc(
    "reject_payment_submission",
    { p_submission: v.submission_id, p_reason: v.reason },
    z.string(),
  );
}

export async function markSubmissionDuplicate(
  input: z.input<typeof markDuplicateInputSchema>,
): Promise<string> {
  const v = markDuplicateInputSchema.parse(input);
  return callRpc(
    "mark_submission_duplicate",
    { p_submission: v.submission_id, p_of: v.duplicate_of_id, p_reason: v.reason },
    z.string(),
  );
}

/** Applies part of a payment's unapplied credit (customer advance) to an invoice. */
export async function applyPaymentCredit(
  input: z.input<typeof applyPaymentCreditInputSchema>,
): Promise<string> {
  const v = applyPaymentCreditInputSchema.parse(input);
  return callRpc(
    "apply_payment_credit",
    {
      p_payment: v.payment_id,
      p_invoice: v.invoice_id,
      p_amount: v.amount,
      p_key: v.idempotency_key,
      p_date: v.date ?? null,
    },
    uuidResultSchema,
  );
}

export async function reverseCreditApplication(
  input: z.input<typeof reverseCreditApplicationInputSchema>,
): Promise<string> {
  const v = reverseCreditApplicationInputSchema.parse(input);
  return callRpc(
    "reverse_credit_application",
    { p_allocation: v.allocation_id, p_key: v.idempotency_key, p_date: v.date, p_reason: v.reason },
    uuidResultSchema,
  );
}

export async function reversePayment(
  input: z.input<typeof reversePaymentInputSchema>,
): Promise<string> {
  const v = reversePaymentInputSchema.parse(input);
  return callRpc(
    "reverse_payment",
    { p_payment: v.payment_id, p_key: v.idempotency_key, p_date: v.date, p_reason: v.reason },
    uuidResultSchema,
  );
}

export async function listPayments(
  entityId: string,
  options: { customerId?: string; invoiceId?: string; limit?: number } = {},
): Promise<PaymentListRow[]> {
  return callRpc(
    "list_payments",
    {
      p_entity: uuid(entityId),
      p_customer: options.customerId ? uuid(options.customerId) : null,
      p_invoice: options.invoiceId ? uuid(options.invoiceId) : null,
      p_limit: options.limit ?? 100,
    },
    paymentListSchema,
  );
}

export async function getPaymentReceipt(paymentId: string): Promise<ReceiptDocument> {
  return callRpc("payment_receipt_document", { p_payment: uuid(paymentId) }, receiptDocumentSchema);
}

// ---- refunds
export async function getPaymentRefundOptions(paymentId: string): Promise<RefundOption[]> {
  return callRpc("payment_refund_options", { p_payment: uuid(paymentId) }, refundOptionsSchema);
}

export async function createRefund(
  input: z.input<typeof createRefundInputSchema>,
): Promise<string> {
  const v = createRefundInputSchema.parse(input);
  return callRpc(
    "create_refund",
    {
      p_payment: v.payment_id,
      p_key: v.idempotency_key,
      p_account: v.account_id,
      p_date: v.refund_date,
      p_items: v.items,
      p_rate: v.exchange_rate ?? null,
      p_reason: v.reason ?? null,
      p_customer_reason: v.customer_reason ?? null,
      p_reference: v.reference ?? null,
      p_confirm: v.confirm ?? false,
    },
    uuidResultSchema,
  );
}

export async function confirmRefund(
  input: z.input<typeof confirmRefundInputSchema>,
): Promise<string> {
  const v = confirmRefundInputSchema.parse(input);
  return callRpc(
    "confirm_refund",
    { p_refund: v.refund_id, p_key: v.idempotency_key },
    uuidResultSchema,
  );
}

export async function rejectRefund(
  input: z.input<typeof refundReasonInputSchema>,
): Promise<string> {
  const v = refundReasonInputSchema.parse(input);
  return callRpc("reject_refund", { p_refund: v.refund_id, p_reason: v.reason }, z.string());
}

export async function cancelRefund(
  input: z.input<typeof refundReasonInputSchema>,
): Promise<string> {
  const v = refundReasonInputSchema.parse(input);
  return callRpc("cancel_refund", { p_refund: v.refund_id, p_reason: v.reason }, z.string());
}

export async function reverseRefund(
  input: z.input<typeof reverseRefundInputSchema>,
): Promise<string> {
  const v = reverseRefundInputSchema.parse(input);
  return callRpc(
    "reverse_refund",
    { p_refund: v.refund_id, p_key: v.idempotency_key, p_date: v.date, p_reason: v.reason },
    uuidResultSchema,
  );
}

// ---- public link management (authenticated)
export async function getInvoiceLink(invoiceId: string) {
  const rows = await callRpc(
    "invoice_public_link",
    { p_invoice: uuid(invoiceId) },
    invoiceLinkRowsSchema,
  );
  return rows[0] ?? null;
}

export async function regenerateInvoiceLink(
  input: z.input<typeof regenerateLinkInputSchema>,
): Promise<string> {
  const v = regenerateLinkInputSchema.parse(input);
  return callRpc(
    "regenerate_invoice_link",
    { p_invoice: v.invoice_id, p_key: v.idempotency_key, p_expires_at: v.expires_at ?? null },
    z.string(),
  );
}

export async function revokeInvoiceLink(
  input: z.input<typeof revokeLinkInputSchema>,
): Promise<string> {
  const v = revokeLinkInputSchema.parse(input);
  return callRpc(
    "revoke_invoice_link",
    { p_invoice: v.invoice_id, p_reason: v.reason },
    z.string(),
  );
}

export async function setInvoiceLinkExpiry(
  input: z.input<typeof setLinkExpiryInputSchema>,
): Promise<string | null> {
  const v = setLinkExpiryInputSchema.parse(input);
  return callRpc(
    "set_invoice_link_expiry",
    { p_invoice: v.invoice_id, p_expires_at: v.expires_at },
    z.string().nullable(),
  );
}

// ---- receivables reports
export async function getArAging(
  entityId: string,
  options: { asOf?: string; customerId?: string } = {},
): Promise<ArAgingRow[]> {
  return callRpc(
    "ar_aging",
    {
      p_entity: uuid(entityId),
      p_as_of: asOfArg(options.asOf),
      p_customer: options.customerId ? uuid(options.customerId) : null,
    },
    arAgingSchema,
  );
}

export async function getArControl(entityId: string, asOf?: string): Promise<ArControlRow> {
  const rows = await callRpc(
    "ar_control_report",
    { p_entity: uuid(entityId), p_as_of: asOfArg(asOf) },
    arControlSchema,
  );
  if (rows.length !== 1) throw new Error("Respons penjualan tidak dikenali.");
  return rows[0];
}
