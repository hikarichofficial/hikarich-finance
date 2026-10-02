"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { AuthzError, authzErrorMessage } from "@/domain/authz/errors";
import { requirePermission } from "@/services/identity/access";
import {
  confirmPaymentSubmission,
  correctInvoice,
  createInvoiceDraft,
  getInvoiceOwner,
  recordPayment,
  rejectPaymentSubmission,
  revokeInvoiceLink,
  updateInvoiceDraft,
  getInvoiceLink,
  issueInvoice,
  regenerateInvoiceLink,
  reversePayment,
  voidInvoice,
} from "@/services/sales/sales";

/**
 * Server actions behind Invoice Detail's status actions (P13 Part 3a, Step 09 §11: "Issue/Send/Copy Link/
 * Confirm Payment/Refund/Correct actions according to state/permission"). Every RPC call here is an
 * unmodified P5 command (`issue_invoice`, `void_invoice`, `correct_invoice`, `invoice_public_link`,
 * `regenerate_invoice_link`) -- this layer only shapes form input and turns a thrown `AuthzError` into the
 * same user-safe Indonesian copy every other screen uses (`authzErrorMessage`), never a raw database
 * message. The database re-checks permission against the invoice's own Entity on every call, so a stale or
 * mismatched `?entity=` in the URL cannot widen what an action is allowed to do (DECISIONS 158's per-page
 * `requireAccess({entityCode})` pattern only controls which buttons are *shown*).
 *
 * Send/Confirm Payment/Refund are Part 3a's later increment (see DECISIONS, P13 Part 3a scope): Send has no
 * email/notification channel built yet (not part of any shipped phase), and Confirm Payment/Refund belong
 * to their own queue screens (Step 09 §11 "Payment confirmation queue... accessible from Sales and
 * Attention/Tasks") rather than a single-invoice action.
 *
 * `reversePaymentAction` (unbuilt-screens backlog) belongs to Payment Detail, not Invoice Detail, but lives
 * here rather than a second `actions.ts` for one function -- both screens are the same Sales module and
 * already share this file's `text`/`errorState` helpers.
 */

export interface InvoiceActionState {
  status: "idle" | "ok" | "error";
  message?: string;
}

const IDLE: InvoiceActionState = { status: "idle" };
export const idleInvoiceActionState = IDLE;

function text(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function revalidateInvoice(invoiceId: string): void {
  revalidatePath("/sales/invoices");
  revalidatePath(`/sales/invoices/${invoiceId}`);
}

function errorState(error: unknown, fallback: string): InvoiceActionState {
  if (error instanceof AuthzError) {
    return { status: "error", message: authzErrorMessage(error.code) };
  }
  return { status: "error", message: fallback };
}

/** The database's own explanation after an `INVALID:`/`CONFLICT:` prefix (English, but specific). */
function draftErrorState(error: unknown, fallback: string): InvoiceActionState {
  if (error instanceof AuthzError) {
    const match = /^(?:INVALID|CONFLICT):\s*([\s\S]+)$/.exec(error.message);
    const base = authzErrorMessage(error.code);
    return { status: "error", message: match?.[1] ? `${base} (${match[1].trim()})` : base };
  }
  return { status: "error", message: fallback };
}

/** Create Invoice (decision 257): the draft is created, then the person lands on its Detail page. */
export async function createInvoiceAction(
  _previous: InvoiceActionState,
  formData: FormData,
): Promise<InvoiceActionState> {
  const entity = text(formData, "entity");
  let lines: unknown;
  try {
    lines = JSON.parse(text(formData, "lines") || "[]");
  } catch {
    return { status: "error", message: "Baris invoice tidak valid." };
  }
  if (!Array.isArray(lines) || lines.length === 0) {
    return { status: "error", message: "Isi minimal satu baris dengan deskripsi dan harga." };
  }
  let invoiceId = text(formData, "invoice_id");
  try {
    if (invoiceId) {
      const version = Number(text(formData, "version"));
      await updateInvoiceDraft({
        invoice_id: invoiceId,
        expected_version: Number.isInteger(version) && version > 0 ? version : undefined,
        patch: {
          customer_id: text(formData, "customer_id"),
          issue_date: text(formData, "issue_date"),
          due_date: text(formData, "due_date"),
          payment_account_id: text(formData, "payment_account_id") || null,
          notes: text(formData, "notes") || null,
          terms: text(formData, "terms") || null,
          lines: lines as never,
        },
      });
      revalidateInvoice(invoiceId);
    } else {
    const { membership } = await requirePermission("invoices.create", { entityCode: entity });
    invoiceId = await createInvoiceDraft({
      entity_id: membership.entity_id,
      idempotency_key: randomUUID(),
      customer_id: text(formData, "customer_id"),
      issue_date: text(formData, "issue_date"),
      due_date: text(formData, "due_date"),
      payment_account_id: text(formData, "payment_account_id") || undefined,
      notes: text(formData, "notes") || undefined,
      terms: text(formData, "terms") || undefined,
      lines: lines as never,
    });
    }
  } catch (error) {
    return draftErrorState(
      error,
      "Invoice tidak dapat disimpan. Periksa pelanggan, tanggal, jatuh tempo dan isian tiap baris.",
    );
  }
  revalidatePath("/sales/invoices");
  redirect(
    entity
      ? `/sales/invoices/${invoiceId}?entity=${encodeURIComponent(entity)}`
      : `/sales/invoices/${invoiceId}`,
  );
}

/** Issue: numbers the draft, freezes its snapshots and posts it. No input beyond the invoice itself. */
export async function issueInvoiceAction(
  _previous: InvoiceActionState,
  formData: FormData,
): Promise<InvoiceActionState> {
  const invoiceId = text(formData, "invoice_id");
  try {
    await issueInvoice({ invoice_id: invoiceId, idempotency_key: randomUUID() });
  } catch (error) {
    return errorState(error, "Faktur tidak dapat diterbitkan.");
  }
  revalidateInvoice(invoiceId);
  return { status: "ok" };
}

/** Void: only an issued invoice with no payment allocated against it can be voided (DECISIONS 76). */
export async function voidInvoiceAction(
  _previous: InvoiceActionState,
  formData: FormData,
): Promise<InvoiceActionState> {
  const invoiceId = text(formData, "invoice_id");
  const reason = text(formData, "reason");
  try {
    await voidInvoice({ invoice_id: invoiceId, idempotency_key: randomUUID(), reason });
  } catch (error) {
    return errorState(error, "Faktur tidak dapat dibatalkan.");
  }
  revalidateInvoice(invoiceId);
  return { status: "ok" };
}

export interface CorrectInvoiceState extends InvoiceActionState {
  newInvoiceId?: string;
}

const CORRECT_IDLE: CorrectInvoiceState = { status: "idle" };
export const idleCorrectInvoiceState = CORRECT_IDLE;

/** Correct: voids the original and opens a same-content replacement draft; returns the new draft's id. */
export async function correctInvoiceAction(
  _previous: CorrectInvoiceState,
  formData: FormData,
): Promise<CorrectInvoiceState> {
  const invoiceId = text(formData, "invoice_id");
  const reason = text(formData, "reason");
  let newInvoiceId: string;
  try {
    newInvoiceId = await correctInvoice({
      invoice_id: invoiceId,
      idempotency_key: randomUUID(),
      reason,
    });
  } catch (error) {
    return errorState(error, "Faktur tidak dapat dikoreksi.");
  }
  revalidateInvoice(invoiceId);
  revalidatePath(`/sales/invoices/${newInvoiceId}`);
  return { status: "ok", newInvoiceId };
}

export interface InvoiceLinkState {
  status: "idle" | "ok" | "error";
  message?: string;
  token?: string;
}

const LINK_IDLE: InvoiceLinkState = { status: "idle" };
export const idleInvoiceLinkState = LINK_IDLE;

/** Copy Link: reuses the active public link if one exists, otherwise issues a new one (finance admin/OWNER only, DECISIONS 75). */
export async function ensureInvoiceLinkAction(
  _previous: InvoiceLinkState,
  formData: FormData,
): Promise<InvoiceLinkState> {
  const invoiceId = text(formData, "invoice_id");
  try {
    const existing = await getInvoiceLink(invoiceId);
    if (existing && existing.status === "active") {
      return { status: "ok", token: existing.token };
    }
    const token = await regenerateInvoiceLink({
      invoice_id: invoiceId,
      idempotency_key: randomUUID(),
    });
    return { status: "ok", token };
  } catch (error) {
    return errorState(error, "Tautan publik tidak dapat dibuat.");
  }
}

function revalidatePayment(paymentId: string): void {
  revalidatePath("/sales/payments");
  revalidatePath("/sales/refunds");
  revalidatePath(`/sales/payments/${paymentId}`);
}

const REVERSE_PAYMENT_IDLE: InvoiceActionState = { status: "idle" };
export const idleReversePaymentState = REVERSE_PAYMENT_IDLE;

/** Reverse Payment (Payment Detail, unbuilt-screens backlog): the RPC itself is gated on
 * `invoices.confirm_payment` (there is no separate `payments.reverse` key) and refuses a payment that
 * still has confirmed refunds against it. */
export async function reversePaymentAction(
  _previous: InvoiceActionState,
  formData: FormData,
): Promise<InvoiceActionState> {
  const paymentId = text(formData, "payment_id");
  const date = text(formData, "date");
  const reason = text(formData, "reason");
  try {
    await reversePayment({ payment_id: paymentId, idempotency_key: randomUUID(), date, reason });
  } catch (error) {
    return errorState(error, "Pembayaran tidak dapat dibalik.");
  }
  revalidatePayment(paymentId);
  return { status: "ok" };
}

/** Record Payment on one invoice (decision 258): `record_payment` with a single allocation to this invoice.
 * The database checks the amount against what is outstanding and posts the receipt. */
export async function recordInvoicePaymentAction(
  _previous: InvoiceActionState,
  formData: FormData,
): Promise<InvoiceActionState> {
  const invoiceId = text(formData, "invoice_id");
  const amount = text(formData, "amount");
  try {
    const owner = await getInvoiceOwner(invoiceId);
    if (!owner) return { status: "error", message: "Invoice tidak ditemukan." };
    await recordPayment({
      entity_id: owner.entity_id,
      idempotency_key: randomUUID(),
      customer_id: owner.customer_id,
      account_id: text(formData, "account_id"),
      payment_date: text(formData, "payment_date"),
      amount,
      allocations: [{ invoice_id: invoiceId, amount }],
      reference: text(formData, "reference") || undefined,
      note: text(formData, "note") || undefined,
    });
  } catch (error) {
    return draftErrorState(
      error,
      "Pembayaran tidak dapat dicatat. Periksa rekening, tanggal dan jumlah.",
    );
  }
  revalidateInvoice(invoiceId);
  revalidatePath("/sales/payments");
  return { status: "ok", message: "Pembayaran tercatat." };
}

/** Confirm a pending payment claim (decision 259, Step 07 §4): `confirm_payment_submission` creates the
 * confirmed payment, its allocation, the money movement, the journal and the receipt. */
export async function confirmClaimAction(
  _previous: InvoiceActionState,
  formData: FormData,
): Promise<InvoiceActionState> {
  try {
    await confirmPaymentSubmission({
      submission_id: text(formData, "submission_id"),
      idempotency_key: randomUUID(),
      account_id: text(formData, "account_id") || undefined,
      payment_date: text(formData, "payment_date") || undefined,
      amount: text(formData, "amount") || undefined,
      note: text(formData, "note") || undefined,
    });
  } catch (error) {
    return draftErrorState(
      error,
      "Klaim tidak dapat dikonfirmasi. Periksa rekening, tanggal dan jumlah.",
    );
  }
  revalidatePath("/sales/claims");
  revalidatePath("/sales/invoices");
  revalidatePath("/sales/payments");
  return { status: "ok", message: "Pembayaran dikonfirmasi dan kwitansi terbit." };
}

/** Reject a pending claim: no financial effect; the reason is kept. */
export async function rejectClaimAction(
  _previous: InvoiceActionState,
  formData: FormData,
): Promise<InvoiceActionState> {
  try {
    await rejectPaymentSubmission({
      submission_id: text(formData, "submission_id"),
      reason: text(formData, "reason"),
    });
  } catch (error) {
    return draftErrorState(error, "Klaim tidak dapat ditolak. Isi alasan minimal 5 karakter.");
  }
  revalidatePath("/sales/claims");
  return { status: "ok", message: "Klaim ditolak." };
}

/** Revoke the public link of an invoice: the old address stops working at once (Step 07 §4). */
export async function revokeInvoiceLinkAction(
  _previous: InvoiceActionState,
  formData: FormData,
): Promise<InvoiceActionState> {
  const invoiceId = text(formData, "invoice_id");
  try {
    await revokeInvoiceLink({ invoice_id: invoiceId, reason: text(formData, "reason") });
  } catch (error) {
    return draftErrorState(error, "Tautan tidak dapat dicabut. Isi alasan minimal 5 karakter.");
  }
  revalidateInvoice(invoiceId);
  return { status: "ok", message: "Tautan publik dicabut." };
}
