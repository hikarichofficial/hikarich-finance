"use server";

import { randomUUID } from "node:crypto";
import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import { AuthzError, authzErrorMessage } from "@/domain/authz/errors";
import {
  cancelTransfer,
  confirmTransfer,
  createTransfer,
  reverseTransfer,
} from "@/services/money/money";

/**
 * Server actions behind the Transfer create form and Transfer Detail's status actions (P13 Part 3c, Step 09
 * §13). Every call is an unmodified P4 RPC (`create_transfer`, `confirm_transfer`, `cancel_transfer`,
 * `reverse_transfer`) -- this layer only shapes form input and turns a thrown `AuthzError` into the same
 * user-safe Indonesian copy every other screen uses, mirroring `src/features/purchases/actions.ts` exactly.
 */

export interface TransferFormState {
  status: "idle" | "error";
  message?: string;
}

const IDLE: TransferFormState = { status: "idle" };
export const idleTransferFormState = IDLE;

function text(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function optionalText(formData: FormData, name: string): string | undefined {
  const value = text(formData, name);
  return value === "" ? undefined : value;
}

function errorState(error: unknown, fallback: string): TransferFormState {
  if (error instanceof AuthzError) {
    return { status: "error", message: authzErrorMessage(error.code) };
  }
  return { status: "error", message: fallback };
}

/** Redirects to the new transfer's Detail page on success (Next.js's own `redirect` throws internally, so it
 * is called outside the try/catch -- the same shape `redirect()`-after-success needs everywhere in this
 * codebase's server actions). */
export async function createTransferAction(
  _previous: TransferFormState,
  formData: FormData,
): Promise<TransferFormState> {
  const entity = text(formData, "entity");
  let transferId: string;
  try {
    transferId = await createTransfer({
      entity_id: text(formData, "entity_id"),
      idempotency_key: randomUUID(),
      from_account_id: text(formData, "from_account_id"),
      to_account_id: text(formData, "to_account_id"),
      transfer_date: text(formData, "transfer_date"),
      amount_out: text(formData, "amount_out"),
      amount_in: optionalText(formData, "amount_in"),
      fee: optionalText(formData, "fee"),
      rate_out: optionalText(formData, "rate_out"),
      rate_in: optionalText(formData, "rate_in"),
      description: optionalText(formData, "description"),
      reference: optionalText(formData, "reference"),
      confirm: formData.get("confirm") === "on",
    });
  } catch (error) {
    return errorState(error, "Transfer tidak dapat dibuat.");
  }
  revalidatePath("/money/transfers");
  redirect(
    entity
      ? `/money/transfers/${transferId}?entity=${encodeURIComponent(entity)}`
      : `/money/transfers/${transferId}`,
  );
}

export interface TransferActionState {
  status: "idle" | "ok" | "error";
  message?: string;
}

const ACTION_IDLE: TransferActionState = { status: "idle" };
export const idleTransferActionState = ACTION_IDLE;

function revalidateTransfer(transferId: string): void {
  revalidatePath("/money/transfers");
  revalidatePath(`/money/transfers/${transferId}`);
}

export async function confirmTransferAction(
  _previous: TransferActionState,
  formData: FormData,
): Promise<TransferActionState> {
  const transferId = text(formData, "transfer_id");
  try {
    await confirmTransfer({
      transfer_id: transferId,
      idempotency_key: randomUUID(),
    });
  } catch (error) {
    return errorState(error, "Transfer tidak dapat dikonfirmasi.");
  }
  revalidateTransfer(transferId);
  return { status: "ok" };
}

export async function cancelTransferAction(
  _previous: TransferActionState,
  formData: FormData,
): Promise<TransferActionState> {
  const transferId = text(formData, "transfer_id");
  const reason = optionalText(formData, "reason");
  try {
    await cancelTransfer({ transfer_id: transferId, reason });
  } catch (error) {
    return errorState(error, "Transfer tidak dapat dibatalkan.");
  }
  revalidateTransfer(transferId);
  return { status: "ok" };
}

export async function reverseTransferAction(
  _previous: TransferActionState,
  formData: FormData,
): Promise<TransferActionState> {
  const transferId = text(formData, "transfer_id");
  const reason = text(formData, "reason");
  try {
    await reverseTransfer({
      transfer_id: transferId,
      idempotency_key: randomUUID(),
      reversal_date: text(formData, "reversal_date"),
      reason,
    });
  } catch (error) {
    return errorState(error, "Transfer tidak dapat dibalik.");
  }
  revalidateTransfer(transferId);
  return { status: "ok" };
}
