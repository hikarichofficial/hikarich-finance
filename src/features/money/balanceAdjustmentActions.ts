"use server";

import { randomUUID } from "node:crypto";
import { redirect } from "next/navigation";
import { AuthzError, describeAuthzError } from "@/domain/authz/errors";
import { recordBalanceAdjustment } from "@/services/money/money";

/**
 * Server action behind the Balance Adjustment form ("Advanced Adjustments", Step 09 §14, decision 232).
 * `record_balance_adjustment` posts its journal and money movement in one transaction and returns the
 * movement id -- there is no adjustment "record" of its own to view afterward, so this redirects to the
 * affected account's own Detail page (its ledger already shows the new movement), the same "go see the
 * result where it actually lives" shape `TransferForm`'s own create action uses.
 */

export interface BalanceAdjustmentFormState {
  status: "idle" | "error";
  message?: string;
}

function text(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function optionalText(formData: FormData, name: string): string | undefined {
  const value = text(formData, name);
  return value === "" ? undefined : value;
}

export async function recordBalanceAdjustmentAction(
  _previous: BalanceAdjustmentFormState,
  formData: FormData,
): Promise<BalanceAdjustmentFormState> {
  const entity = text(formData, "entity");
  const accountId = text(formData, "account_id");
  try {
    await recordBalanceAdjustment({
      entity_id: text(formData, "entity_id"),
      idempotency_key: randomUUID(),
      account_id: accountId,
      direction: text(formData, "direction") === "out" ? "out" : "in",
      amount: text(formData, "amount"),
      exchange_rate: optionalText(formData, "exchange_rate"),
      movement_date: text(formData, "movement_date"),
      counter_account_id: text(formData, "counter_account_id"),
      reason: text(formData, "reason"),
    });
  } catch (error) {
    if (error instanceof AuthzError) {
      return { status: "error", message: describeAuthzError(error) };
    }
    return { status: "error", message: "Penyesuaian saldo tidak dapat dicatat." };
  }
  redirect(
    entity
      ? `/money/accounts/${accountId}?entity=${encodeURIComponent(entity)}`
      : `/money/accounts/${accountId}`,
  );
}
