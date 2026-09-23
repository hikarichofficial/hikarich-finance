"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { AuthzError, authzErrorMessage } from "@/domain/authz/errors";
import {
  approveBill,
  cancelBill,
  correctBill,
  recallBill,
  rejectBill,
  submitBill,
  voidBill,
} from "@/services/purchases/purchases";

/**
 * Server actions behind Bill Detail's status actions (P13 Part 3b, Step 09 §12). Every call is an
 * unmodified P6 RPC (`submit_bill`, `recall_bill`, `reject_bill`, `approve_bill`, `cancel_bill`,
 * `void_bill`, `correct_bill`) -- this layer only shapes form input and turns a thrown `AuthzError` into
 * the same user-safe Indonesian copy every other screen uses, mirroring `src/features/sales/actions.ts`
 * exactly (P13 Part 3a's established shape). `approve_bill`'s `duplicate_reason` (only needed when the
 * database reports an exact vendor-reference duplicate) is not wired up yet -- deferred with
 * `findPurchaseDuplicates`'s own UI to a later increment (see DECISIONS, P13 Part 3b scope).
 */

export interface BillActionState {
  status: "idle" | "ok" | "error";
  message?: string;
}

const IDLE: BillActionState = { status: "idle" };
export const idleBillActionState = IDLE;

function text(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function revalidateBill(billId: string): void {
  revalidatePath("/purchases/bills");
  revalidatePath(`/purchases/bills/${billId}`);
}

function errorState(error: unknown, fallback: string): BillActionState {
  if (error instanceof AuthzError) {
    return { status: "error", message: authzErrorMessage(error.code) };
  }
  return { status: "error", message: fallback };
}

export async function submitBillAction(
  _previous: BillActionState,
  formData: FormData,
): Promise<BillActionState> {
  const billId = text(formData, "bill_id");
  try {
    await submitBill({ bill_id: billId, idempotency_key: randomUUID() });
  } catch (error) {
    return errorState(error, "Tagihan tidak dapat diajukan.");
  }
  revalidateBill(billId);
  return { status: "ok" };
}

export async function recallBillAction(
  _previous: BillActionState,
  formData: FormData,
): Promise<BillActionState> {
  const billId = text(formData, "bill_id");
  try {
    await recallBill({ bill_id: billId });
  } catch (error) {
    return errorState(error, "Tagihan tidak dapat ditarik kembali.");
  }
  revalidateBill(billId);
  return { status: "ok" };
}

export async function rejectBillAction(
  _previous: BillActionState,
  formData: FormData,
): Promise<BillActionState> {
  const billId = text(formData, "bill_id");
  const reason = text(formData, "reason");
  try {
    await rejectBill({ bill_id: billId, reason });
  } catch (error) {
    return errorState(error, "Tagihan tidak dapat ditolak.");
  }
  revalidateBill(billId);
  return { status: "ok" };
}

export async function approveBillAction(
  _previous: BillActionState,
  formData: FormData,
): Promise<BillActionState> {
  const billId = text(formData, "bill_id");
  try {
    await approveBill({ bill_id: billId, idempotency_key: randomUUID() });
  } catch (error) {
    return errorState(error, "Tagihan tidak dapat disetujui.");
  }
  revalidateBill(billId);
  return { status: "ok" };
}

export async function cancelBillAction(
  _previous: BillActionState,
  formData: FormData,
): Promise<BillActionState> {
  const billId = text(formData, "bill_id");
  const reason = text(formData, "reason");
  try {
    await cancelBill({
      bill_id: billId,
      idempotency_key: randomUUID(),
      reason,
    });
  } catch (error) {
    return errorState(error, "Tagihan tidak dapat dibatalkan.");
  }
  revalidateBill(billId);
  return { status: "ok" };
}

export async function voidBillAction(
  _previous: BillActionState,
  formData: FormData,
): Promise<BillActionState> {
  const billId = text(formData, "bill_id");
  const reason = text(formData, "reason");
  try {
    await voidBill({ bill_id: billId, idempotency_key: randomUUID(), reason });
  } catch (error) {
    return errorState(error, "Tagihan tidak dapat dibatalkan (void).");
  }
  revalidateBill(billId);
  return { status: "ok" };
}

export interface CorrectBillState extends BillActionState {
  newBillId?: string;
}

const CORRECT_IDLE: CorrectBillState = { status: "idle" };
export const idleCorrectBillState = CORRECT_IDLE;

export async function correctBillAction(
  _previous: CorrectBillState,
  formData: FormData,
): Promise<CorrectBillState> {
  const billId = text(formData, "bill_id");
  const reason = text(formData, "reason");
  let newBillId: string;
  try {
    newBillId = await correctBill({
      bill_id: billId,
      idempotency_key: randomUUID(),
      reason,
    });
  } catch (error) {
    return errorState(error, "Tagihan tidak dapat dikoreksi.");
  }
  revalidateBill(billId);
  revalidatePath(`/purchases/bills/${newBillId}`);
  return { status: "ok", newBillId };
}
