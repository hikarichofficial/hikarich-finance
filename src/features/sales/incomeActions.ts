"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { setFlash } from "@/lib/flash";
import { AuthzError, describeAuthzError } from "@/domain/authz/errors";
import { requirePermission } from "@/services/identity/access";
import { recordIncomeEntry, reverseIncomeEntry } from "@/services/sales/income";

/**
 * Server actions behind "Catat Pendapatan" (decision 350): record an income that has no invoice, and cancel one.
 * The database makes the journal (debit the receiving account, credit the income account), the cash movement and
 * the reversal; nothing here knows a debit from a credit.
 */

export interface IncomeActionState {
  status: "idle" | "ok" | "error";
  message?: string;
}

function text(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function errorState(error: unknown, fallback: string): IncomeActionState {
  if (error instanceof AuthzError) {
    return { status: "error", message: describeAuthzError(error) };
  }
  return { status: "error", message: fallback };
}

export async function recordIncomeAction(
  _previous: IncomeActionState,
  formData: FormData,
): Promise<IncomeActionState> {
  const entity = text(formData, "entity");
  let id: string;
  try {
    const { membership } = await requirePermission("invoices.issue", { entityCode: entity });
    id = await recordIncomeEntry({
      entity_id: membership.entity_id,
      idempotency_key: randomUUID(),
      category_id: text(formData, "category_id"),
      date: text(formData, "entry_date"),
      account_id: text(formData, "account_id"),
      amount: text(formData, "amount"),
      contact_id: text(formData, "contact_id") || undefined,
      reference: text(formData, "reference") || undefined,
      note: text(formData, "note") || undefined,
    });
  } catch (error) {
    return errorState(
      error,
      "Pendapatan tidak dapat dicatat. Periksa jenis pendapatan, tanggal (tidak boleh lewat hari ini), jumlah, dan rekening.",
    );
  }
  revalidatePath("/sales/income");
  await setFlash("Pendapatan tercatat.");
  redirect(
    entity ? `/sales/income/${id}?entity=${encodeURIComponent(entity)}` : `/sales/income/${id}`,
  );
}

export async function reverseIncomeAction(
  _previous: IncomeActionState,
  formData: FormData,
): Promise<IncomeActionState> {
  const entryId = text(formData, "entry_id");
  try {
    await reverseIncomeEntry({
      entry_id: entryId,
      idempotency_key: randomUUID(),
      date: text(formData, "date"),
      reason: text(formData, "reason"),
    });
  } catch (error) {
    return errorState(error, "Pendapatan tidak dapat dibatalkan. Isi alasan minimal 5 karakter.");
  }
  revalidatePath("/sales/income");
  revalidatePath(`/sales/income/${entryId}`);
  return { status: "ok", message: "Pendapatan dibatalkan." };
}
