"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { AuthzError, authzErrorMessage } from "@/domain/authz/errors";
import {
  correctInvoice,
  getInvoiceLink,
  issueInvoice,
  regenerateInvoiceLink,
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

/** Issue: numbers the draft, freezes its snapshots and posts it. No input beyond the invoice itself. */
export async function issueInvoiceAction(
  _previous: InvoiceActionState,
  formData: FormData,
): Promise<InvoiceActionState> {
  const invoiceId = text(formData, "invoice_id");
  try {
    await issueInvoice({
      invoice_id: invoiceId,
      idempotency_key: randomUUID(),
    });
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
    await voidInvoice({
      invoice_id: invoiceId,
      idempotency_key: randomUUID(),
      reason,
    });
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
