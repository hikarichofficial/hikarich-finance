import { z } from "zod";
import {
  exchangeRateTextSchema,
  idempotencyKeySchema,
  isoDateSchema,
  moneyTextSchema,
  signedDecimalTextSchema,
} from "@/schemas/accounting";
import { whtObjectSchema } from "@/schemas/tax";

/**
 * Input and output contracts of the purchase RPCs (P6): bills, vendor payments, direct expenses, evidence
 * documents and the accounts-payable reports. Money is always exact decimal text (Step 13 §25); the database
 * recomputes every figure and never trusts a total sent by the caller. Vendors are contacts of kind `vendor`
 * and are created with the same contact schema as customers (`@/schemas/sales`).
 */

const optionalText = (max: number) => z.string().trim().max(max).optional();
const nullableText = (max: number) =>
  z.string().trim().max(max).nullable().optional();
/** Reasons are kept by the audit trail: 5 to 1000 characters (a rejection needs only 3). */
const reasonSchema = z.string().trim().min(5).max(1000);
const shortReasonSchema = z.string().trim().min(3).max(1000);

// ---- lines
export const purchaseTreatmentSchema = z.enum(["expense", "asset", "prepaid"]);

export const purchaseLineInputSchema = z.object({
  description: z.string().trim().min(1).max(500),
  quantity: z
    .string()
    .regex(/^\d{1,9}(\.\d{1,4})?$/)
    .optional(),
  unit_price: moneyTextSchema,
  treatment: purchaseTreatmentSchema.optional(),
  category_id: z.uuid().optional(),
  account_id: z.uuid().optional(),
  /** The VAT the vendor charged on the line (P7): a fact from the tax invoice; the engine decides what it means. */
  tax_amount: moneyTextSchema.optional(),
  /** The tax invoice number that supports the input VAT (needed for it to be creditable). */
  vat_invoice_ref: z.string().trim().max(100).optional(),
  /** The drafter's assertion that the input VAT is not creditable and stays a cost. */
  vat_not_creditable: z.boolean().optional(),
  /** What the payment is for, when income tax is withheld from it (PPh 23). */
  wht_object: whtObjectSchema.optional(),
});
export type PurchaseLineInput = z.infer<typeof purchaseLineInputSchema>;

const currencySchema = z.string().regex(/^[A-Z]{3}$/);

// ---- bills
export const createBillDraftInputSchema = z
  .object({
    entity_id: z.uuid(),
    idempotency_key: idempotencyKeySchema,
    vendor_id: z.uuid(),
    bill_date: isoDateSchema,
    due_date: isoDateSchema,
    /** The vendor's own invoice number: the key of duplicate detection. */
    vendor_reference: optionalText(100),
    currency: currencySchema.optional(),
    exchange_rate: exchangeRateTextSchema.optional(),
    notes: optionalText(2000),
    internal_note: optionalText(2000),
    lines: z.array(purchaseLineInputSchema).max(200).default([]),
  })
  .refine((v) => v.due_date >= v.bill_date, {
    path: ["due_date"],
    message: "Jatuh tempo sebelum tanggal tagihan",
  });

/** Only the named fields change; `lines`, when present, replaces all lines. */
export const updateBillDraftInputSchema = z.object({
  bill_id: z.uuid(),
  expected_version: z.number().int().positive().optional(),
  patch: z
    .object({
      vendor_id: z.uuid().optional(),
      vendor_reference: nullableText(100),
      bill_date: isoDateSchema.optional(),
      due_date: isoDateSchema.optional(),
      currency: currencySchema.optional(),
      exchange_rate: exchangeRateTextSchema.nullable().optional(),
      notes: nullableText(2000),
      internal_note: nullableText(2000),
      lines: z.array(purchaseLineInputSchema).max(200).optional(),
    })
    .refine((p) => Object.keys(p).length > 0, "Tidak ada perubahan"),
});

export const submitBillInputSchema = z.object({
  bill_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
});

export const billIdInputSchema = z.object({ bill_id: z.uuid() });

export const rejectBillInputSchema = z.object({
  bill_id: z.uuid(),
  reason: shortReasonSchema,
});

export const approveBillInputSchema = z.object({
  bill_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  /** Needed only when the database reports an exact duplicate: the person's reason it is a different bill. */
  duplicate_reason: reasonSchema.optional(),
});

export const closeBillInputSchema = z.object({
  bill_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  reason: reasonSchema,
  /** Effective date of a void; defaults to today in the Entity's time zone. */
  date: isoDateSchema.optional(),
});

export const cancelBillInputSchema = z.object({
  bill_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  reason: reasonSchema,
});

export const updateBillDueDateInputSchema = z.object({
  bill_id: z.uuid(),
  due_date: isoDateSchema,
  reason: shortReasonSchema,
});

// ---- vendor payments
export const vendorAllocationInputSchema = z.object({
  bill_id: z.uuid(),
  amount: moneyTextSchema,
});

export const recordVendorPaymentInputSchema = z.object({
  entity_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  vendor_id: z.uuid(),
  account_id: z.uuid(),
  payment_date: isoDateSchema,
  amount: moneyTextSchema,
  /** The payment always equals the sum of these: vendor advances are not supported. */
  allocations: z.array(vendorAllocationInputSchema).min(1).max(100),
  exchange_rate: exchangeRateTextSchema.optional(),
  reference: optionalText(200),
  channel_id: z.uuid().optional(),
  note: optionalText(1000),
});

export const reverseVendorPaymentInputSchema = z.object({
  payment_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  date: isoDateSchema,
  reason: reasonSchema,
});

// ---- expenses
export const createExpenseDraftInputSchema = z
  .object({
    entity_id: z.uuid(),
    idempotency_key: idempotencyKeySchema,
    /** The account the money leaves; the expense is in its currency. */
    account_id: z.uuid(),
    expense_date: isoDateSchema,
    payee_id: z.uuid().optional(),
    payee_name: optionalText(200),
    receipt_reference: optionalText(100),
    exchange_rate: exchangeRateTextSchema.optional(),
    notes: optionalText(2000),
    internal_note: optionalText(2000),
    lines: z.array(purchaseLineInputSchema).max(200).default([]),
  })
  .refine((v) => v.payee_id !== undefined || (v.payee_name ?? "") !== "", {
    path: ["payee_name"],
    message: "Isi vendor atau nama penerima",
  });

export const updateExpenseDraftInputSchema = z.object({
  expense_id: z.uuid(),
  expected_version: z.number().int().positive().optional(),
  patch: z
    .object({
      payee_id: z.uuid().nullable().optional(),
      payee_name: nullableText(200),
      account_id: z.uuid().optional(),
      expense_date: isoDateSchema.optional(),
      receipt_reference: nullableText(100),
      exchange_rate: exchangeRateTextSchema.nullable().optional(),
      notes: nullableText(2000),
      internal_note: nullableText(2000),
      lines: z.array(purchaseLineInputSchema).max(200).optional(),
    })
    .refine((p) => Object.keys(p).length > 0, "Tidak ada perubahan"),
});

export const submitExpenseInputSchema = z.object({
  expense_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
});

export const expenseIdInputSchema = z.object({ expense_id: z.uuid() });

export const rejectExpenseInputSchema = z.object({
  expense_id: z.uuid(),
  reason: shortReasonSchema,
});

export const confirmExpenseInputSchema = z.object({
  expense_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  duplicate_reason: reasonSchema.optional(),
});

export const cancelExpenseInputSchema = z.object({
  expense_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  reason: reasonSchema,
});

export const closeExpenseInputSchema = z.object({
  expense_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  reason: reasonSchema,
  date: isoDateSchema.optional(),
});

// ---- duplicates and evidence
export const purchaseDocKindSchema = z.enum(["bill", "expense"]);

export const findPurchaseDuplicatesInputSchema = z.object({
  entity_id: z.uuid(),
  vendor_id: z.uuid().optional(),
  payee_name: optionalText(200),
  reference: optionalText(200),
  date: isoDateSchema.optional(),
  currency: currencySchema.optional(),
  total: moneyTextSchema.optional(),
  exclude_kind: purchaseDocKindSchema.optional(),
  exclude_id: z.uuid().optional(),
});

export const documentMimeTypeSchema = z.enum([
  "application/pdf",
  "image/jpeg",
  "image/png",
  "image/webp",
]);

export const MAX_DOCUMENT_BYTES = 25 * 1024 * 1024;

export const registerDocumentInputSchema = z.object({
  entity_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  file_name: z
    .string()
    .trim()
    .min(1)
    .max(255)
    // No path separators or control characters in a stored name.
    .regex(/^[^\\/\u0000-\u001f\u007f]+$/),
  mime_type: documentMimeTypeSchema,
  size_bytes: z.number().int().positive().max(MAX_DOCUMENT_BYTES),
  sha256: z
    .string()
    .trim()
    .toLowerCase()
    .regex(/^[0-9a-f]{64}$/),
});

export const documentPurposeSchema = z.enum([
  "vendor_invoice",
  "receipt",
  "contract",
  "other",
]);

export const linkDocumentInputSchema = z.object({
  document_id: z.uuid(),
  target_type: purchaseDocKindSchema,
  target_id: z.uuid(),
  purpose: documentPurposeSchema.optional(),
});

export const unlinkDocumentInputSchema = z.object({
  link_id: z.uuid(),
  reason: shortReasonSchema,
});

// ---- RPC results
export const billFilterSchema = z.enum([
  "open",
  "overdue",
  "paid",
  "unpaid",
  "partial",
  "closed",
]);
export type BillFilter = z.infer<typeof billFilterSchema>;

export const billPositionSchema = z.object({
  bill_id: z.uuid(),
  bill_number: z.string(),
  vendor_id: z.uuid(),
  vendor_name: z.string(),
  vendor_reference: z.string().nullable(),
  currency: z.string(),
  status: z.enum(["approved", "void"]),
  bill_date: isoDateSchema,
  due_date: isoDateSchema,
  total: signedDecimalTextSchema,
  settled: signedDecimalTextSchema,
  outstanding: signedDecimalTextSchema,
  base_outstanding: signedDecimalTextSchema,
  settlement_status: z.enum(["unpaid", "partial", "paid"]).nullable(),
  is_overdue: z.boolean(),
  days_overdue: z.number().int().nonnegative(),
});
export const billPositionsSchema = z.array(billPositionSchema);
export type BillPosition = z.infer<typeof billPositionSchema>;

/**
 * Row shape of a direct, RLS-governed read of `public.bills` (P13 Part 3b's List/Detail screens, not an
 * RPC): `bills_select`/`bill_lines_select` (P6, `*_p6_bills.sql`) already gate `select` on `bills.view` per
 * row, the same direct-table-read shape `entities.base_currency` established (DECISIONS 161). This exists
 * because `list_bill_positions` only ever returns `approved`/`void` bills (it reads
 * `app_private.bill_positions`, which has no notion of a bill still in preparation) -- Step 09 §12's "Bills
 * list emphasizes... approval... state" needs draft/submitted/cancelled bills too, and no RPC lists those.
 */
export const billRowSchema = z.object({
  id: z.uuid(),
  entity_id: z.uuid(),
  bill_number: z.string().nullable(),
  vendor_id: z.uuid(),
  vendor_reference: z.string().nullable(),
  currency: z.string(),
  status: z.enum(["draft", "submitted", "approved", "cancelled", "void"]),
  bill_date: isoDateSchema,
  due_date: isoDateSchema,
  notes: z.string().nullable(),
  subtotal: moneyTextSchema,
  tax_total: moneyTextSchema,
  total: moneyTextSchema,
  submitted_at: z.string().nullable(),
  rejected_at: z.string().nullable(),
  reject_reason: z.string().nullable(),
  approved_at: z.string().nullable(),
  closed_at: z.string().nullable(),
  closed_date: isoDateSchema.nullable(),
  closed_reason: z.string().nullable(),
});
export type BillRow = z.infer<typeof billRowSchema>;

/** Narrow projection of `billRowSchema` for the List screen's in-preparation rows (draft/submitted/cancelled
 * bills `list_bill_positions` never returns). `vendor_reference` is the fallback label when the caller's
 * role lacks `contacts.view` (see `listBillsOverview`'s doc comment) and the vendor's name cannot be read. */
export const billSummaryRowSchema = z.object({
  id: z.uuid(),
  bill_number: z.string().nullable(),
  vendor_id: z.uuid(),
  vendor_reference: z.string().nullable(),
  currency: z.string(),
  status: z.enum(["draft", "submitted", "cancelled"]),
  bill_date: isoDateSchema,
  due_date: isoDateSchema,
  total: moneyTextSchema,
});
export type BillSummaryRow = z.infer<typeof billSummaryRowSchema>;

export const billLineRowSchema = z.object({
  line_no: z.number().int().positive(),
  description: z.string(),
  quantity: z.string(),
  unit_price: moneyTextSchema,
  line_subtotal: moneyTextSchema,
  tax_amount: moneyTextSchema,
  line_total: moneyTextSchema,
  treatment: purchaseTreatmentSchema,
});
export type BillLineRow = z.infer<typeof billLineRowSchema>;

export const vendorNameRowSchema = z.object({ display_name: z.string() });

export const apControlRowSchema = z.object({
  sub_ledger: signedDecimalTextSchema,
  ledger_purchases: signedDecimalTextSchema,
  ledger_total: signedDecimalTextSchema,
  difference: signedDecimalTextSchema,
  other_ledger: signedDecimalTextSchema,
});
export const apControlSchema = z.array(apControlRowSchema);
export type ApControlRow = z.infer<typeof apControlRowSchema>;

export const vendorPaymentRowSchema = z.object({
  payment_id: z.uuid(),
  payment_number: z.string(),
  status: z.enum(["confirmed", "reversed"]),
  payment_date: isoDateSchema,
  vendor_id: z.uuid(),
  vendor_name: z.string(),
  currency: z.string(),
  amount: signedDecimalTextSchema,
  base_amount: signedDecimalTextSchema,
  fx_difference: signedDecimalTextSchema,
  reference: z.string().nullable(),
  bill_count: z.coerce.number().int().nonnegative(),
});
export const vendorPaymentListSchema = z.array(vendorPaymentRowSchema);
export type VendorPaymentRow = z.infer<typeof vendorPaymentRowSchema>;

export const apAgingRowSchema = z.object({
  vendor_id: z.uuid(),
  vendor_name: z.string(),
  not_due: signedDecimalTextSchema,
  days_1_30: signedDecimalTextSchema,
  days_31_60: signedDecimalTextSchema,
  days_61_90: signedDecimalTextSchema,
  days_over_90: signedDecimalTextSchema,
  total: signedDecimalTextSchema,
  bill_count: z.coerce.number().int().nonnegative(),
});
export const apAgingSchema = z.array(apAgingRowSchema);
export type ApAgingRow = z.infer<typeof apAgingRowSchema>;

export const purchaseDuplicateSchema = z.object({
  doc_kind: purchaseDocKindSchema,
  doc_id: z.uuid(),
  doc_number: z.string().nullable(),
  doc_date: isoDateSchema,
  /** `exact` needs the person's written reason to proceed; `likely` is only a warning. */
  severity: z.enum(["exact", "likely"]),
  reason: z.string(),
});
export const purchaseDuplicatesSchema = z.array(purchaseDuplicateSchema);
export type PurchaseDuplicate = z.infer<typeof purchaseDuplicateSchema>;

export const documentLinkRowSchema = z.object({
  link_id: z.uuid(),
  document_id: z.uuid(),
  file_name: z.string(),
  mime_type: z.string(),
  size_bytes: z.coerce.number().int().positive(),
  sha256: z.string(),
  purpose: documentPurposeSchema,
  created_at: z.string(),
});
export const documentLinksSchema = z.array(documentLinkRowSchema);
export type DocumentLinkRow = z.infer<typeof documentLinkRowSchema>;

export const missingEvidenceRowSchema = z.object({
  doc_kind: purchaseDocKindSchema,
  doc_id: z.uuid(),
  doc_number: z.string().nullable(),
  doc_date: isoDateSchema,
  party_name: z.string().nullable(),
  currency: z.string(),
  total: signedDecimalTextSchema,
});
export const missingEvidenceSchema = z.array(missingEvidenceRowSchema);
export type MissingEvidenceRow = z.infer<typeof missingEvidenceRowSchema>;
