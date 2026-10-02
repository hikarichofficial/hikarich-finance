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
    if (code) throw new AuthzError(code, error.message);
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

/** Whose invoice this is (Entity and customer), by a direct RLS-governed read; `null` when it does not
 * exist or the caller cannot see it. Used to record a payment against one invoice (decision 258). */
export async function getInvoiceOwner(
  invoiceId: string,
): Promise<{ entity_id: string; customer_id: string } | null> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("invoices")
    .select("entity_id, customer_id")
    .eq("id", uuidResultSchema.parse(invoiceId))
    .maybeSingle();
  if (error || !data) return null;
  return { entity_id: String(data.entity_id), customer_id: String(data.customer_id) };
}

export interface PaymentClaimRow {
  id: string;
  invoice_id: string;
  invoice_number: string | null;
  source: string;
  amount: string;
  currency: string;
  payment_date: string;
  payer_name: string | null;
  payer_reference: string | null;
  note: string | null;
  created_at: string;
}

/** Pending payment claims of the Entity ("Saya Sudah Bayar" from the public page, or staff-recorded), by a
 * direct RLS-governed read; the requester hash is never selected. Decision 259. */
export async function listPendingPaymentClaims(entityId: string): Promise<PaymentClaimRow[]> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("payment_submissions")
    .select(
      "id, invoice_id, source, amount::text, currency, payment_date, payer_name, payer_reference, note, created_at",
    )
    .eq("entity_id", uuid(entityId))
    .eq("status", "pending")
    .order("created_at", { ascending: true })
    .limit(200);
  if (error) throw new Error("Gagal memuat klaim pembayaran.");
  const rows = (data ?? []) as unknown as Omit<PaymentClaimRow, "invoice_number">[];
  if (rows.length === 0) return [];
  const { data: invoices } = await supabase
    .from("invoices")
    .select("id, invoice_number")
    .in("id", [...new Set(rows.map((r) => r.invoice_id))]);
  const numbers = new Map(
    ((invoices ?? []) as { id: string; invoice_number: string | null }[]).map((i) => [
      i.id,
      i.invoice_number,
    ]),
  );
  return rows.map((r) => ({ ...r, invoice_number: numbers.get(r.invoice_id) ?? null }));
}

// ---- marketplace stores and settlements (decision 260)
export interface MarketplaceStoreRow {
  id: string;
  platform: string;
  name: string;
  settlement_financial_account_id: string | null;
  pph22_exempt: boolean;
  is_active: boolean;
}

export interface MarketplaceSettlementRow {
  id: string;
  store_id: string;
  status: "confirmed" | "reversed";
  period_start: string;
  period_end: string;
  settlement_date: string;
  currency: string;
  gross_sales: string;
  vat_amount: string;
  fee_amount: string;
  pph22_amount: string;
  payout_amount: string;
  reference: string | null;
}

export async function listMarketplaceStores(entityId: string): Promise<MarketplaceStoreRow[]> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("marketplace_stores")
    .select("id, platform, name, settlement_financial_account_id, pph22_exempt, is_active")
    .eq("entity_id", uuid(entityId))
    .order("name", { ascending: true });
  if (error) throw new Error("Gagal memuat toko marketplace.");
  return (data ?? []) as MarketplaceStoreRow[];
}

export async function listMarketplaceSettlements(
  entityId: string,
): Promise<MarketplaceSettlementRow[]> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("marketplace_settlements")
    .select(
      "id, store_id, status, period_start, period_end, settlement_date, currency, gross_sales::text, vat_amount::text, fee_amount::text, pph22_amount::text, payout_amount::text, reference",
    )
    .eq("entity_id", uuid(entityId))
    .order("settlement_date", { ascending: false })
    .limit(100);
  if (error) throw new Error("Gagal memuat pencairan marketplace.");
  return (data ?? []) as unknown as MarketplaceSettlementRow[];
}

const marketplacePlatformSchema = z.enum([
  "shopee",
  "tokopedia",
  "lazada",
  "blibli",
  "tiktok_shop",
  "bukalapak",
  "other",
]);
const marketplaceMoney = z.string().regex(/^\d{1,16}(\.\d{1,4})?$/);

export async function createMarketplaceStore(input: {
  entity_id: string;
  idempotency_key: string;
  platform: string;
  name: string;
  account_id?: string;
  pph22_exempt?: boolean;
}): Promise<string> {
  return callRpc(
    "create_marketplace_store",
    {
      p_entity: uuid(input.entity_id),
      p_key: input.idempotency_key,
      p_platform: marketplacePlatformSchema.parse(input.platform),
      p_name: z.string().trim().min(2).max(120).parse(input.name),
      p_account: input.account_id ? uuid(input.account_id) : null,
      p_revenue_category: null,
      p_fee_category: null,
      p_pph22_exempt: input.pph22_exempt ?? false,
    },
    uuidResultSchema,
  );
}

export async function recordMarketplaceSettlement(input: {
  entity_id: string;
  idempotency_key: string;
  store_id: string;
  period_start: string;
  period_end: string;
  settlement_date: string;
  account_id: string;
  gross: string;
  fees?: string;
  pph22?: string;
  reference?: string;
  note?: string;
}): Promise<string> {
  return callRpc(
    "record_marketplace_settlement",
    {
      p_entity: uuid(input.entity_id),
      p_key: input.idempotency_key,
      p_store: uuid(input.store_id),
      p_period_start: isoDateSchema.parse(input.period_start),
      p_period_end: isoDateSchema.parse(input.period_end),
      p_settlement_date: isoDateSchema.parse(input.settlement_date),
      p_account: uuid(input.account_id),
      p_gross: marketplaceMoney.parse(input.gross),
      p_fees: input.fees ? marketplaceMoney.parse(input.fees) : "0",
      p_pph22: input.pph22 ? marketplaceMoney.parse(input.pph22) : null,
      p_reference: input.reference ?? null,
      p_note: input.note ?? null,
    },
    uuidResultSchema,
  );
}

export async function reverseMarketplaceSettlement(input: {
  settlement_id: string;
  idempotency_key: string;
  date: string;
  reason: string;
}): Promise<string> {
  return callRpc(
    "reverse_marketplace_settlement",
    {
      p_settlement: uuid(input.settlement_id),
      p_key: input.idempotency_key,
      p_date: isoDateSchema.parse(input.date),
      p_reason: z.string().trim().min(5).max(500).parse(input.reason),
    },
    uuidResultSchema,
  );
}

function editableLine(row: Record<string, unknown>): Record<string, unknown> {
  const line: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(row)) {
    if (value === null || value === undefined || value === "") continue;
    if (key === "tax_amount" && Number(value) === 0) continue;
    if (key === "vat_not_creditable" && value === false) continue;
    if (key === "discount_type" && value === "none") continue;
    if (key === "discount_value" && Number(value) === 0) continue;
    line[key] = typeof value === "number" ? String(value) : value;
  }
  return line;
}

export interface InvoiceDraftForEdit {
  id: string;
  entity_id: string;
  version: number;
  customer_id: string;
  issue_date: string;
  due_date: string;
  payment_account_id: string | null;
  notes: string | null;
  terms: string | null;
  lines: Record<string, unknown>[];
}

/** A DRAFT invoice with the line facts the editor shows, by a direct RLS-governed read; `null` when it does
 * not exist, is not visible, or is no longer a draft (decision 261). */
export async function getInvoiceDraftForEdit(
  invoiceId: string,
): Promise<InvoiceDraftForEdit | null> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("invoices")
    .select(
      "id, entity_id, version, status, customer_id, issue_date, due_date, payment_account_id, notes, terms",
    )
    .eq("id", uuid(invoiceId))
    .maybeSingle();
  if (error || !data || data.status !== "draft") return null;
  const { data: lines, error: linesError } = await supabase
    .from("invoice_lines")
    .select(
      "description, quantity::text, unit_price::text, category_id, vat_treatment, product_id, discount_type, discount_value::text",
    )
    .eq("invoice_id", data.id)
    .order("line_no", { ascending: true });
  if (linesError) return null;
  return {
    id: String(data.id),
    entity_id: String(data.entity_id),
    version: Number(data.version),
    customer_id: String(data.customer_id),
    issue_date: String(data.issue_date),
    due_date: String(data.due_date),
    payment_account_id: (data.payment_account_id as string | null) ?? null,
    notes: (data.notes as string | null) ?? null,
    terms: (data.terms as string | null) ?? null,
    lines: ((lines ?? []) as unknown as Record<string, unknown>[]).map(editableLine),
  };
}
