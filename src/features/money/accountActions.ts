"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { AuthzError, describeAuthzError } from "@/domain/authz/errors";
import { requirePermission } from "@/services/identity/access";
import {
  createFinancialAccount,
  removeFinancialAccount,
  setFinancialAccountActive,
} from "@/services/money/money";

/** Server action behind Add Account (decision 258): the unmodified `create_financial_account`. */

export interface AccountActionState {
  status: "idle" | "error" | "ok";
  message?: string;
}

function text(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

export async function createAccountAction(
  _previous: AccountActionState,
  formData: FormData,
): Promise<AccountActionState> {
  const entity = text(formData, "entity");
  let accountId: string;
  try {
    const { membership } = await requirePermission("money.edit", { entityCode: entity });
    accountId = await createFinancialAccount({
      entity_id: membership.entity_id,
      idempotency_key: randomUUID(),
      kind: text(formData, "kind") as never,
      name: text(formData, "name"),
      currency: text(formData, "currency").toUpperCase(),
      institution_name: text(formData, "institution_name") || undefined,
      account_number: text(formData, "account_number") || undefined,
      account_holder: text(formData, "account_holder") || undefined,
    });
  } catch (error) {
    if (error instanceof AuthzError) {
      return { status: "error", message: describeAuthzError(error) };
    }
    return {
      status: "error",
      message: "Rekening tidak dapat disimpan. Periksa nama dan mata uang.",
    };
  }
  revalidatePath("/money/accounts");
  redirect(
    entity
      ? `/money/accounts/${accountId}?entity=${encodeURIComponent(entity)}`
      : `/money/accounts/${accountId}`,
  );
}

function manageErrorMessage(error: unknown, fallback: string): string {
  return error instanceof AuthzError ? describeAuthzError(error) : fallback;
}

/**
 * Hapus Rekening, behind a double confirmation (OWNER, 5 October 2026): the name must be typed exactly (step one)
 * and the final box ticked (step two). An account with no history is erased; one with transactions is archived
 * by the database (gone from every list, books untouched) -- the screen says which before it asks.
 */
export async function deleteAccountAction(
  _previous: AccountActionState,
  formData: FormData,
): Promise<AccountActionState> {
  const entity = text(formData, "entity");
  const accountId = text(formData, "account_id");
  if (text(formData, "confirm") !== "yes") {
    return {
      status: "error",
      message: "Centang kotak konfirmasi akhir dulu untuk menghapus rekening.",
    };
  }
  const expected = text(formData, "expected_name");
  if (expected === "" || text(formData, "confirm_name") !== expected) {
    return {
      status: "error",
      message: "Nama rekening yang diketik belum sama persis. Tidak ada yang dihapus.",
    };
  }
  try {
    await requirePermission("money.edit", { entityCode: entity });
    await removeFinancialAccount({ account_id: accountId, reason: text(formData, "reason") });
  } catch (error) {
    return {
      status: "error",
      message: manageErrorMessage(error, "Rekening tidak dapat dihapus saat ini."),
    };
  }
  revalidatePath("/money/accounts");
  redirect(entity ? `/money/accounts?entity=${encodeURIComponent(entity)}` : "/money/accounts");
}

/** Nonaktifkan / aktifkan kembali: the way to retire an account that already has history. */
export async function setAccountActiveAction(
  _previous: AccountActionState,
  formData: FormData,
): Promise<AccountActionState> {
  const entity = text(formData, "entity");
  const accountId = text(formData, "account_id");
  const active = text(formData, "active") === "true";
  try {
    await requirePermission("money.edit", { entityCode: entity });
    await setFinancialAccountActive({
      account_id: accountId,
      active,
      reason: text(formData, "reason") || "Diaktifkan kembali",
    });
  } catch (error) {
    return {
      status: "error",
      message: manageErrorMessage(
        error,
        "Status rekening tidak dapat diubah. Isi alasan minimal 5 huruf.",
      ),
    };
  }
  revalidatePath("/money/accounts");
  revalidatePath(`/money/accounts/${accountId}`);
  return {
    status: "ok",
    message: active ? "Rekening diaktifkan kembali." : "Rekening dinonaktifkan.",
  };
}
