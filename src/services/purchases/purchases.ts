import "server-only";
import { z, type ZodType } from "zod";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { AuthzError, parseAuthzCode } from "@/domain/authz/errors";
import { isoDateSchema, uuidResultSchema } from "@/schemas/accounting";
import {
  apAgingSchema,
  apControlSchema,
  approveBillInputSchema,
  billFilterSchema,
  billIdInputSchema,
  billLineRowSchema,
  billPositionsSchema,
  billRowSchema,
  billSummaryRowSchema,
  cancelBillInputSchema,
  cancelExpenseInputSchema,
  closeBillInputSchema,
  closeExpenseInputSchema,
  confirmExpenseInputSchema,
  createBillDraftInputSchema,
  createExpenseDraftInputSchema,
  documentLinksSchema,
  expenseIdInputSchema,
  findPurchaseDuplicatesInputSchema,
  linkDocumentInputSchema,
  missingEvidenceSchema,
  purchaseDuplicatesSchema,
  recordVendorPaymentInputSchema,
  registerDocumentInputSchema,
  rejectBillInputSchema,
  rejectExpenseInputSchema,
  reverseVendorPaymentInputSchema,
  submitBillInputSchema,
  submitExpenseInputSchema,
  unlinkDocumentInputSchema,
  updateBillDraftInputSchema,
  updateBillDueDateInputSchema,
  updateExpenseDraftInputSchema,
  vendorNameRowSchema,
  vendorPaymentListSchema,
  type ApAgingRow,
  type ApControlRow,
  type BillFilter,
  type BillLineRow,
  type BillPosition,
  type DocumentLinkRow,
  type MissingEvidenceRow,
  type PurchaseDuplicate,
  type VendorPaymentRow,
} from "@/schemas/purchases";
import type { BillListRow } from "@/domain/purchases/billList";

/**
 * Thin, typed wrappers over the purchase RPCs (P6). Every call runs as the signed-in person; the database
 * decides who may do what per Entity and enforces every rule (arithmetic, numbering, posting, periods,
 * allocations, duplicate detection, approval, idempotency, immutability) inside the transaction. This layer
 * validates the input shape, maps the database's error prefixes to AuthzError without leaking detail, and
 * validates what comes back. It holds no purchase rules of its own (Step 04, Step 07, Step 08, Step 13 §9).
 * The exact arithmetic that screens use for early feedback lives in `@/domain/purchases`.
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
    throw new Error("Operasi pembelian gagal diproses.");
  }
  const parsed = schema.safeParse(data);
  if (!parsed.success) throw new Error("Respons pembelian tidak dikenali.");
  return parsed.data;
}

const uuid = (value: string) => uuidResultSchema.parse(value);
const asOfArg = (asOf?: string) => (asOf ? isoDateSchema.parse(asOf) : null);
const textResult = z.string();

// ---- bills
export async function createBillDraft(
  input: z.input<typeof createBillDraftInputSchema>,
): Promise<string> {
  const v = createBillDraftInputSchema.parse(input);
  return callRpc(
    "create_bill_draft",
    {
      p_entity: v.entity_id,
      p_key: v.idempotency_key,
      p_vendor: v.vendor_id,
      p_bill_date: v.bill_date,
      p_due_date: v.due_date,
      p_lines: v.lines,
      p_vendor_reference: v.vendor_reference ?? null,
      p_currency: v.currency ?? null,
      p_rate: v.exchange_rate ?? null,
      p_notes: v.notes ?? null,
      p_internal_note: v.internal_note ?? null,
    },
    uuidResultSchema,
  );
}

/** Returns the new version number. A stale `expected_version` is refused (Step 08 §18). */
export async function updateBillDraft(
  input: z.input<typeof updateBillDraftInputSchema>,
): Promise<number> {
  const v = updateBillDraftInputSchema.parse(input);
  return callRpc(
    "update_bill_draft",
    {
      p_bill: v.bill_id,
      p_patch: v.patch,
      p_expected_version: v.expected_version ?? null,
    },
    z.number().int(),
  );
}

export async function submitBill(
  input: z.input<typeof submitBillInputSchema>,
): Promise<string> {
  const v = submitBillInputSchema.parse(input);
  return callRpc(
    "submit_bill",
    { p_bill: v.bill_id, p_key: v.idempotency_key },
    uuidResultSchema,
  );
}

/** Takes a submitted bill back to draft. */
export async function recallBill(
  input: z.input<typeof billIdInputSchema>,
): Promise<string> {
  const v = billIdInputSchema.parse(input);
  return callRpc("recall_bill", { p_bill: v.bill_id }, textResult);
}

export async function rejectBill(
  input: z.input<typeof rejectBillInputSchema>,
): Promise<string> {
  const v = rejectBillInputSchema.parse(input);
  return callRpc(
    "reject_bill",
    { p_bill: v.bill_id, p_reason: v.reason },
    textResult,
  );
}

/**
 * Numbers the bill, freezes the vendor snapshot and posts it to the ledger in one transaction. An exact
 * duplicate of a recognised bill (same vendor, same vendor invoice number) is refused with CONFLICT until the
 * person supplies `duplicate_reason`.
 */
export async function approveBill(
  input: z.input<typeof approveBillInputSchema>,
): Promise<string> {
  const v = approveBillInputSchema.parse(input);
  return callRpc(
    "approve_bill",
    {
      p_bill: v.bill_id,
      p_key: v.idempotency_key,
      p_duplicate_reason: v.duplicate_reason ?? null,
    },
    uuidResultSchema,
  );
}

/** Cancels a draft or submitted bill: no accounting effect and the bill never received a number. */
export async function cancelBill(
  input: z.input<typeof cancelBillInputSchema>,
): Promise<string> {
  const v = cancelBillInputSchema.parse(input);
  return callRpc(
    "cancel_bill",
    { p_bill: v.bill_id, p_key: v.idempotency_key, p_reason: v.reason },
    uuidResultSchema,
  );
}

/** Voids an approved bill with no active payment: a linked reversal journal; the number stays used. */
export async function voidBill(
  input: z.input<typeof closeBillInputSchema>,
): Promise<string> {
  const v = closeBillInputSchema.parse(input);
  return callRpc(
    "void_bill",
    {
      p_bill: v.bill_id,
      p_key: v.idempotency_key,
      p_reason: v.reason,
      p_date: v.date ?? null,
    },
    uuidResultSchema,
  );
}

/** Voids the bill and creates a replacement draft with the same content. Returns the new bill id. */
export async function correctBill(
  input: z.input<typeof closeBillInputSchema>,
): Promise<string> {
  const v = closeBillInputSchema.parse(input);
  return callRpc(
    "correct_bill",
    {
      p_bill: v.bill_id,
      p_key: v.idempotency_key,
      p_reason: v.reason,
      p_date: v.date ?? null,
    },
    uuidResultSchema,
  );
}

export async function updateBillDueDate(
  input: z.input<typeof updateBillDueDateInputSchema>,
): Promise<string> {
  const v = updateBillDueDateInputSchema.parse(input);
  return callRpc(
    "update_bill_due_date",
    { p_bill: v.bill_id, p_due_date: v.due_date, p_reason: v.reason },
    isoDateSchema,
  );
}

// ---- vendor payments
/** Books the payment, its money movement and its allocations in one transaction. Returns the payment id. */
export async function recordVendorPayment(
  input: z.input<typeof recordVendorPaymentInputSchema>,
): Promise<string> {
  const v = recordVendorPaymentInputSchema.parse(input);
  return callRpc(
    "record_vendor_payment",
    {
      p_entity: v.entity_id,
      p_key: v.idempotency_key,
      p_vendor: v.vendor_id,
      p_account: v.account_id,
      p_date: v.payment_date,
      p_amount: v.amount,
      p_allocations: v.allocations,
      p_rate: v.exchange_rate ?? null,
      p_reference: v.reference ?? null,
      p_channel: v.channel_id ?? null,
      p_note: v.note ?? null,
    },
    uuidResultSchema,
  );
}

/** Returns the reversal journal id. */
export async function reverseVendorPayment(
  input: z.input<typeof reverseVendorPaymentInputSchema>,
): Promise<string> {
  const v = reverseVendorPaymentInputSchema.parse(input);
  return callRpc(
    "reverse_vendor_payment",
    {
      p_payment: v.payment_id,
      p_key: v.idempotency_key,
      p_date: v.date,
      p_reason: v.reason,
    },
    uuidResultSchema,
  );
}

// ---- expenses
export async function createExpenseDraft(
  input: z.input<typeof createExpenseDraftInputSchema>,
): Promise<string> {
  const v = createExpenseDraftInputSchema.parse(input);
  return callRpc(
    "create_expense_draft",
    {
      p_entity: v.entity_id,
      p_key: v.idempotency_key,
      p_account: v.account_id,
      p_expense_date: v.expense_date,
      p_lines: v.lines,
      p_payee_id: v.payee_id ?? null,
      p_payee_name: v.payee_name ?? null,
      p_receipt_reference: v.receipt_reference ?? null,
      p_rate: v.exchange_rate ?? null,
      p_notes: v.notes ?? null,
      p_internal_note: v.internal_note ?? null,
    },
    uuidResultSchema,
  );
}

export async function updateExpenseDraft(
  input: z.input<typeof updateExpenseDraftInputSchema>,
): Promise<number> {
  const v = updateExpenseDraftInputSchema.parse(input);
  return callRpc(
    "update_expense_draft",
    {
      p_expense: v.expense_id,
      p_patch: v.patch,
      p_expected_version: v.expected_version ?? null,
    },
    z.number().int(),
  );
}

export async function submitExpense(
  input: z.input<typeof submitExpenseInputSchema>,
): Promise<string> {
  const v = submitExpenseInputSchema.parse(input);
  return callRpc(
    "submit_expense",
    { p_expense: v.expense_id, p_key: v.idempotency_key },
    uuidResultSchema,
  );
}

export async function recallExpense(
  input: z.input<typeof expenseIdInputSchema>,
): Promise<string> {
  const v = expenseIdInputSchema.parse(input);
  return callRpc("recall_expense", { p_expense: v.expense_id }, textResult);
}

export async function rejectExpense(
  input: z.input<typeof rejectExpenseInputSchema>,
): Promise<string> {
  const v = rejectExpenseInputSchema.parse(input);
  return callRpc(
    "reject_expense",
    { p_expense: v.expense_id, p_reason: v.reason },
    textResult,
  );
}

/** Numbers the expense and posts it, with its money movement, in one transaction. Returns the expense id. */
export async function confirmExpense(
  input: z.input<typeof confirmExpenseInputSchema>,
): Promise<string> {
  const v = confirmExpenseInputSchema.parse(input);
  return callRpc(
    "confirm_expense",
    {
      p_expense: v.expense_id,
      p_key: v.idempotency_key,
      p_duplicate_reason: v.duplicate_reason ?? null,
    },
    uuidResultSchema,
  );
}

export async function cancelExpense(
  input: z.input<typeof cancelExpenseInputSchema>,
): Promise<string> {
  const v = cancelExpenseInputSchema.parse(input);
  return callRpc(
    "cancel_expense",
    { p_expense: v.expense_id, p_key: v.idempotency_key, p_reason: v.reason },
    uuidResultSchema,
  );
}

export async function reverseExpense(
  input: z.input<typeof closeExpenseInputSchema>,
): Promise<string> {
  const v = closeExpenseInputSchema.parse(input);
  return callRpc(
    "reverse_expense",
    {
      p_expense: v.expense_id,
      p_key: v.idempotency_key,
      p_reason: v.reason,
      p_date: v.date ?? null,
    },
    uuidResultSchema,
  );
}

/** Reverses the expense and creates a replacement draft with the same content. Returns the new expense id. */
export async function correctExpense(
  input: z.input<typeof closeExpenseInputSchema>,
): Promise<string> {
  const v = closeExpenseInputSchema.parse(input);
  return callRpc(
    "correct_expense",
    {
      p_expense: v.expense_id,
      p_key: v.idempotency_key,
      p_reason: v.reason,
      p_date: v.date ?? null,
    },
    uuidResultSchema,
  );
}

// ---- duplicates and evidence
export async function findPurchaseDuplicates(
  input: z.input<typeof findPurchaseDuplicatesInputSchema>,
): Promise<PurchaseDuplicate[]> {
  const v = findPurchaseDuplicatesInputSchema.parse(input);
  return callRpc(
    "find_purchase_duplicates",
    {
      p_entity: v.entity_id,
      p_vendor: v.vendor_id ?? null,
      p_payee_name: v.payee_name ?? null,
      p_reference: v.reference ?? null,
      p_date: v.date ?? null,
      p_currency: v.currency ?? null,
      p_total: v.total ?? null,
      p_exclude_kind: v.exclude_kind ?? null,
      p_exclude_id: v.exclude_id ?? null,
    },
    purchaseDuplicatesSchema,
  );
}

/** Registers a document by content hash (the same content in the same Entity is the same document). */
export async function registerDocument(
  input: z.input<typeof registerDocumentInputSchema>,
): Promise<string> {
  const v = registerDocumentInputSchema.parse(input);
  return callRpc(
    "register_document",
    {
      p_entity: v.entity_id,
      p_key: v.idempotency_key,
      p_file_name: v.file_name,
      p_mime_type: v.mime_type,
      p_size_bytes: v.size_bytes,
      p_sha256: v.sha256,
    },
    uuidResultSchema,
  );
}

export async function linkDocument(
  input: z.input<typeof linkDocumentInputSchema>,
): Promise<string> {
  const v = linkDocumentInputSchema.parse(input);
  return callRpc(
    "link_document",
    {
      p_document: v.document_id,
      p_target_type: v.target_type,
      p_target_id: v.target_id,
      p_purpose: v.purpose ?? "receipt",
    },
    uuidResultSchema,
  );
}

/** Evidence can be removed only while the bill or expense is still being prepared. */
export async function unlinkDocument(
  input: z.input<typeof unlinkDocumentInputSchema>,
): Promise<string> {
  const v = unlinkDocumentInputSchema.parse(input);
  return callRpc(
    "unlink_document",
    { p_link: v.link_id, p_reason: v.reason },
    textResult,
  );
}

export async function listDocumentLinks(
  entityId: string,
  targetType: "bill" | "expense",
  targetId: string,
): Promise<DocumentLinkRow[]> {
  return callRpc(
    "list_document_links",
    {
      p_entity: uuid(entityId),
      p_target_type: targetType,
      p_target_id: uuid(targetId),
    },
    documentLinksSchema,
  );
}

export async function listMissingEvidence(
  entityId: string,
  options: { from?: string; to?: string } = {},
): Promise<MissingEvidenceRow[]> {
  return callRpc(
    "list_missing_evidence",
    {
      p_entity: uuid(entityId),
      p_from: asOfArg(options.from),
      p_to: asOfArg(options.to),
    },
    missingEvidenceSchema,
  );
}

// ---- reading: positions, payments, aging, control
export async function listBillPositions(
  entityId: string,
  options: { filter?: BillFilter; vendorId?: string; asOf?: string } = {},
): Promise<BillPosition[]> {
  return callRpc(
    "list_bill_positions",
    {
      p_entity: uuid(entityId),
      p_filter: options.filter ? billFilterSchema.parse(options.filter) : null,
      p_vendor: options.vendorId ? uuid(options.vendorId) : null,
      p_as_of: asOfArg(options.asOf),
    },
    billPositionsSchema,
  );
}

export async function listVendorPayments(
  entityId: string,
  options: { vendorId?: string; billId?: string; limit?: number } = {},
): Promise<VendorPaymentRow[]> {
  const limit = z
    .number()
    .int()
    .min(1)
    .max(500)
    .parse(options.limit ?? 100);
  return callRpc(
    "list_vendor_payments",
    {
      p_entity: uuid(entityId),
      p_vendor: options.vendorId ? uuid(options.vendorId) : null,
      p_bill: options.billId ? uuid(options.billId) : null,
      p_limit: limit,
    },
    vendorPaymentListSchema,
  );
}

export async function getApAging(
  entityId: string,
  options: { asOf?: string; vendorId?: string } = {},
): Promise<ApAgingRow[]> {
  return callRpc(
    "ap_aging",
    {
      p_entity: uuid(entityId),
      p_as_of: asOfArg(options.asOf),
      p_vendor: options.vendorId ? uuid(options.vendorId) : null,
    },
    apAgingSchema,
  );
}

/** Sub-ledger (bills and allocations) against the General Ledger; a difference blocks period close. */
export async function getApControl(
  entityId: string,
  asOf?: string,
): Promise<ApControlRow> {
  const rows = await callRpc(
    "ap_control_report",
    { p_entity: uuid(entityId), p_as_of: asOfArg(asOf) },
    apControlSchema,
  );
  if (rows.length !== 1) throw new Error("Respons pembelian tidak dikenali.");
  return rows[0];
}

// ---- Bills List / Detail (P13 Part 3b, Step 09 §9-§10, §12). Not RPC wrappers: `bills`/`bill_lines`/
// `contacts` are read directly, RLS-governed (`bills.view`/`contacts.view`), the same direct-table-read
// shape `getEntityBaseCurrency` established (DECISIONS 161).

/**
 * Best-effort vendor display names, keyed by contact id. `contacts_select`'s RLS requires `contacts.view`
 * (P2), a permission not every `bills.view` role template grants (`approver`, `tax` -- Step 06's own
 * catalog, decision this file records in DECISIONS' Open items): a caller without it simply gets back no
 * rows for those ids, not an error, so a missing name here is expected for some roles and every caller must
 * fall back to something else (the bill's own `vendor_reference`, then a generic label) rather than crash.
 */
async function getVendorNames(
  vendorIds: readonly string[],
): Promise<Map<string, string>> {
  if (vendorIds.length === 0) return new Map();
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("contacts")
    .select("id, display_name")
    .in("id", [...vendorIds]);
  if (error) return new Map();
  const parsed = z
    .array(
      z.object({
        id: z.uuid(),
        display_name: vendorNameRowSchema.shape.display_name,
      }),
    )
    .safeParse(data);
  if (!parsed.success) return new Map();
  return new Map(parsed.data.map((row) => [row.id, row.display_name]));
}

/**
 * Every bill regardless of workflow state, merged into one list-row shape: `list_bill_positions` (P6) for
 * `approved`/`void` bills (it already carries settlement/overdue), plus a direct read of `draft`/
 * `submitted`/`cancelled` bills (no RPC lists those -- see `billRowSchema`'s doc comment). Filtering and the
 * status badge are computed client-side by `src/domain/purchases/billList.ts` over this merged list.
 */
export async function listBillsOverview(
  entityId: string,
): Promise<BillListRow[]> {
  const supabase = await createSupabaseServerClient();
  const [positions, preparingResult] = await Promise.all([
    listBillPositions(entityId),
    supabase
      .from("bills")
      .select(
        "id, bill_number, vendor_id, vendor_reference, currency, status, bill_date, due_date, total",
      )
      .eq("entity_id", uuid(entityId))
      .in("status", ["draft", "submitted", "cancelled"])
      .order("bill_date", { ascending: false }),
  ]);
  if (preparingResult.error) throw new Error("Gagal memuat tagihan pembelian.");
  const parsedPreparing = z
    .array(billSummaryRowSchema)
    .safeParse(preparingResult.data);
  if (!parsedPreparing.success)
    throw new Error("Respons tagihan pembelian tidak dikenali.");

  const vendorNames = await getVendorNames(
    parsedPreparing.data.map((b) => b.vendor_id),
  );

  const fromPositions: BillListRow[] = positions.map((p) => ({
    bill_id: p.bill_id,
    bill_number: p.bill_number,
    vendor_id: p.vendor_id,
    vendor_name: p.vendor_name,
    currency: p.currency,
    status: p.status,
    bill_date: p.bill_date,
    due_date: p.due_date,
    total: p.total,
    outstanding: p.outstanding,
    settlement_status: p.settlement_status,
    is_overdue: p.is_overdue,
    days_overdue: p.days_overdue,
  }));
  const fromPreparing: BillListRow[] = parsedPreparing.data.map((b) => ({
    bill_id: b.id,
    bill_number: b.bill_number,
    vendor_id: b.vendor_id,
    vendor_name: vendorNames.get(b.vendor_id) ?? b.vendor_reference ?? "Vendor",
    currency: b.currency,
    status: b.status,
    bill_date: b.bill_date,
    due_date: b.due_date,
    total: b.total,
    outstanding: null,
    settlement_status: null,
    is_overdue: false,
    days_overdue: 0,
  }));
  return [...fromPositions, ...fromPreparing].sort((a, b) =>
    a.bill_date < b.bill_date ? 1 : -1,
  );
}

export interface BillDetail {
  id: string;
  bill_number: string | null;
  vendor_id: string;
  vendor_name: string;
  vendor_reference: string | null;
  currency: string;
  status: "draft" | "submitted" | "approved" | "cancelled" | "void";
  bill_date: string;
  due_date: string;
  notes: string | null;
  subtotal: string;
  tax_total: string;
  total: string;
  submitted_at: string | null;
  rejected_at: string | null;
  reject_reason: string | null;
  approved_at: string | null;
  closed_at: string | null;
  closed_date: string | null;
  closed_reason: string | null;
  lines: BillLineRow[];
  /** Only set for `approved`/`void` bills (from `list_bill_positions`); `null` while in preparation. */
  settled: string | null;
  outstanding: string | null;
  settlement_status: "unpaid" | "partial" | "paid" | null;
  is_overdue: boolean;
  days_overdue: number;
}

/** `null` for a missing or inaccessible bill -- the same answer either way (no existence leak), matching
 * every P6 RPC's own "not found or not allowed" convention. */
export async function getBillDetail(
  billId: string,
): Promise<BillDetail | null> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("bills")
    .select(
      "id, entity_id, bill_number, vendor_id, vendor_reference, currency, status, bill_date, due_date, notes, subtotal, tax_total, total, submitted_at, rejected_at, reject_reason, approved_at, closed_at, closed_date, closed_reason",
    )
    .eq("id", uuid(billId))
    .maybeSingle();
  if (error) throw new Error("Gagal memuat tagihan pembelian.");
  if (!data) return null;
  const parsedBill = billRowSchema.safeParse(data);
  if (!parsedBill.success)
    throw new Error("Respons tagihan pembelian tidak dikenali.");
  const bill = parsedBill.data;

  const [linesResult, vendorNames, positions] = await Promise.all([
    supabase
      .from("bill_lines")
      .select(
        "line_no, description, quantity, unit_price, line_subtotal, tax_amount, line_total, treatment",
      )
      .eq("bill_id", bill.id)
      .order("line_no", { ascending: true }),
    getVendorNames([bill.vendor_id]),
    bill.status === "approved" || bill.status === "void"
      ? listBillPositions(bill.entity_id)
      : null,
  ]);
  if (linesResult.error)
    throw new Error("Gagal memuat baris tagihan pembelian.");
  const parsedLines = z.array(billLineRowSchema).safeParse(linesResult.data);
  if (!parsedLines.success)
    throw new Error("Respons baris tagihan pembelian tidak dikenali.");

  const position = positions?.find((p) => p.bill_id === bill.id) ?? null;

  return {
    id: bill.id,
    bill_number: bill.bill_number,
    vendor_id: bill.vendor_id,
    vendor_name:
      vendorNames.get(bill.vendor_id) ?? bill.vendor_reference ?? "Vendor",
    vendor_reference: bill.vendor_reference,
    currency: bill.currency,
    status: bill.status,
    bill_date: bill.bill_date,
    due_date: bill.due_date,
    notes: bill.notes,
    subtotal: bill.subtotal,
    tax_total: bill.tax_total,
    total: bill.total,
    submitted_at: bill.submitted_at,
    rejected_at: bill.rejected_at,
    reject_reason: bill.reject_reason,
    approved_at: bill.approved_at,
    closed_at: bill.closed_at,
    closed_date: bill.closed_date,
    closed_reason: bill.closed_reason,
    lines: parsedLines.data,
    settled: position?.settled ?? null,
    outstanding: position?.outstanding ?? null,
    settlement_status: position?.settlement_status ?? null,
    is_overdue: position?.is_overdue ?? false,
    days_overdue: position?.days_overdue ?? 0,
  };
}
