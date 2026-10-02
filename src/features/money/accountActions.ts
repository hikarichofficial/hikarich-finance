"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { AuthzError, authzErrorMessage } from "@/domain/authz/errors";
import { requirePermission } from "@/services/identity/access";
import { createFinancialAccount } from "@/services/money/money";

/** Server action behind Add Account (decision 258): the unmodified `create_financial_account`. */

export interface AccountActionState {
  status: "idle" | "error";
  message?: string;
}

export const idleAccountActionState: AccountActionState = { status: "idle" };

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
      const match = /^(?:INVALID|CONFLICT):\s*([\s\S]+)$/.exec(error.message);
      const base = authzErrorMessage(error.code);
      return { status: "error", message: match?.[1] ? `${base} (${match[1].trim()})` : base };
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
