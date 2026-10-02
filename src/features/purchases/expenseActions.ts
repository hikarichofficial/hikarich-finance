"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { AuthzError, authzErrorMessage } from "@/domain/authz/errors";
import { requirePermission } from "@/services/identity/access";
import {
  cancelExpense,
  confirmExpense,
  correctExpense,
  createExpenseDraft,
  recallExpense,
  rejectExpense,
  reverseExpense,
  submitExpense,
  updateExpenseDraft,
} from "@/services/purchases/purchases";

/**
 * Server actions behind the Direct Expense screens (Step 09 §12, decision 245). Every write is an
 * unmodified P6 RPC; this layer only shapes form input and maps `AuthzError` to user-safe copy, the same
 * shape `./actions.ts` uses for Bills.
 */

export interface ExpenseActionState {
  status: "idle" | "ok" | "error";
  message?: string;
}

export const idleExpenseActionState: ExpenseActionState = { status: "idle" };

function text(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function revalidateExpense(expenseId: string): void {
  revalidatePath("/purchases/expenses");
  revalidatePath(`/purchases/expenses/${expenseId}`);
}

function errorState(error: unknown, fallback: string): ExpenseActionState {
  if (error instanceof AuthzError)
    return { status: "error", message: authzErrorMessage(error.code) };
  return { status: "error", message: fallback };
}

/** The database's own explanation after an `INVALID:`/`CONFLICT:` prefix (English, but specific). */
function draftErrorState(error: unknown, fallback: string): ExpenseActionState {
  if (error instanceof AuthzError) {
    const match = /^(?:INVALID|CONFLICT):\s*([\s\S]+)$/.exec(error.message);
    const base = authzErrorMessage(error.code);
    return { status: "error", message: match?.[1] ? `${base} (${match[1].trim()})` : base };
  }
  return { status: "error", message: fallback };
}

function detailHref(expenseId: string, entity: string): string {
  return entity
    ? `/purchases/expenses/${expenseId}?entity=${encodeURIComponent(entity)}`
    : `/purchases/expenses/${expenseId}`;
}

export async function createExpenseAction(
  _previous: ExpenseActionState,
  formData: FormData,
): Promise<ExpenseActionState> {
  const entity = text(formData, "entity");
  let lines: unknown;
  try {
    lines = JSON.parse(text(formData, "lines") || "[]");
  } catch {
    return { status: "error", message: "Baris pengeluaran tidak valid." };
  }
  if (!Array.isArray(lines) || lines.length === 0) {
    return { status: "error", message: "Isi minimal satu baris dengan deskripsi dan harga." };
  }
  const payeeId = text(formData, "payee_id");
  let expenseId = text(formData, "expense_id");
  try {
    if (expenseId) {
      // Editing an existing draft: `update_expense_draft` (`bills.edit`), with the version the form loaded.
      const version = Number(text(formData, "version"));
      await updateExpenseDraft({
        expense_id: expenseId,
        expected_version: Number.isInteger(version) && version > 0 ? version : undefined,
        patch: {
          payee_id: payeeId || null,
          payee_name: payeeId ? null : text(formData, "payee_name") || null,
          account_id: text(formData, "account_id"),
          expense_date: text(formData, "expense_date"),
          receipt_reference: text(formData, "receipt_reference") || null,
          notes: text(formData, "notes") || null,
          lines: lines as never,
        },
      });
      revalidateExpense(expenseId);
    } else {
      const { membership } = await requirePermission("bills.create", { entityCode: entity });
      expenseId = await createExpenseDraft({
        entity_id: membership.entity_id,
        idempotency_key: randomUUID(),
        account_id: text(formData, "account_id"),
        expense_date: text(formData, "expense_date"),
        payee_id: payeeId || undefined,
        payee_name: text(formData, "payee_name") || undefined,
        receipt_reference: text(formData, "receipt_reference") || undefined,
        notes: text(formData, "notes") || undefined,
        lines: lines as never,
      });
    }
  } catch (error) {
    return draftErrorState(
      error,
      "Pengeluaran tidak dapat disimpan. Periksa rekening, tanggal, penerima dan baris.",
    );
  }
  revalidatePath("/purchases/expenses");
  redirect(detailHref(expenseId, entity));
}

type Command = (expenseId: string, formData: FormData) => Promise<unknown>;

function commandAction(command: Command, fallback: string) {
  return async (_previous: ExpenseActionState, formData: FormData): Promise<ExpenseActionState> => {
    const expenseId = text(formData, "expense_id");
    try {
      await command(expenseId, formData);
    } catch (error) {
      return errorState(error, fallback);
    }
    revalidateExpense(expenseId);
    return { status: "ok" };
  };
}

export async function submitExpenseAction(p: ExpenseActionState, f: FormData) {
  return commandAction(
    (id) => submitExpense({ expense_id: id, idempotency_key: randomUUID() }),
    "Pengeluaran tidak dapat diajukan.",
  )(p, f);
}

export async function recallExpenseAction(p: ExpenseActionState, f: FormData) {
  return commandAction(
    (id) => recallExpense({ expense_id: id }),
    "Pengeluaran tidak dapat ditarik kembali.",
  )(p, f);
}

export async function rejectExpenseAction(p: ExpenseActionState, f: FormData) {
  return commandAction(
    (id, fd) => rejectExpense({ expense_id: id, reason: text(fd, "reason") }),
    "Pengeluaran tidak dapat ditolak.",
  )(p, f);
}

export async function confirmExpenseAction(p: ExpenseActionState, f: FormData) {
  return commandAction(
    (id, fd) =>
      confirmExpense({
        expense_id: id,
        idempotency_key: randomUUID(),
        duplicate_reason: text(fd, "duplicate_reason") || undefined,
      }),
    "Pengeluaran tidak dapat dikonfirmasi. Jika struk ini tercatat ganda, isi alasan duplikat.",
  )(p, f);
}

export async function cancelExpenseAction(p: ExpenseActionState, f: FormData) {
  return commandAction(
    (id, fd) =>
      cancelExpense({ expense_id: id, idempotency_key: randomUUID(), reason: text(fd, "reason") }),
    "Pengeluaran tidak dapat dibatalkan.",
  )(p, f);
}

export async function reverseExpenseAction(p: ExpenseActionState, f: FormData) {
  return commandAction(
    (id, fd) =>
      reverseExpense({ expense_id: id, idempotency_key: randomUUID(), reason: text(fd, "reason") }),
    "Pengeluaran tidak dapat dibalik.",
  )(p, f);
}

export interface CorrectExpenseState extends ExpenseActionState {
  newExpenseId?: string;
}

export async function correctExpenseAction(
  _previous: CorrectExpenseState,
  formData: FormData,
): Promise<CorrectExpenseState> {
  const expenseId = text(formData, "expense_id");
  let newExpenseId: string;
  try {
    newExpenseId = await correctExpense({
      expense_id: expenseId,
      idempotency_key: randomUUID(),
      reason: text(formData, "reason"),
    });
  } catch (error) {
    return errorState(error, "Pengeluaran tidak dapat dikoreksi.");
  }
  revalidateExpense(expenseId);
  revalidatePath(`/purchases/expenses/${newExpenseId}`);
  return { status: "ok", newExpenseId };
}
