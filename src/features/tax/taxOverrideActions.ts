"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { AuthzError, describeAuthzError } from "@/domain/authz/errors";
import { setTaxOverride, withdrawTaxOverride } from "@/services/tax/tax";

/** Server action behind the tax override form (decision 262): the unmodified `tax_override_set`
 * (`tax.override`, recent step-up, reason and evidence note). */

export interface TaxOverrideState {
  status: "idle" | "ok" | "error";
  message?: string;
  stepUp?: boolean;
}

function text(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

export async function setTaxOverrideAction(
  _previous: TaxOverrideState,
  formData: FormData,
): Promise<TaxOverrideState> {
  try {
    await setTaxOverride({
      source_type: text(formData, "source_type") as never,
      source_id: text(formData, "source_id"),
      idempotency_key: randomUUID(),
      kind: text(formData, "kind") as never,
      amount: text(formData, "amount"),
      reason: text(formData, "reason"),
      evidence_note: text(formData, "evidence_note"),
    });
  } catch (error) {
    if (error instanceof AuthzError) {
      return {
        status: "error",
        message: describeAuthzError(error),
        stepUp: error.code === "STEP_UP_REQUIRED",
      };
    }
    return {
      status: "error",
      message: "Koreksi tidak dapat disimpan. Alasan minimal 10 karakter, catatan bukti minimal 5.",
    };
  }
  revalidatePath(text(formData, "path") || "/");
  return { status: "ok", message: "Koreksi pajak tersimpan." };
}

/** Withdraw an override no posted document has used yet: the unmodified `tax_override_withdraw`
 * (`tax.override`, recent step-up, a reason of 5 to 500 characters). */
export async function withdrawTaxOverrideAction(
  _previous: TaxOverrideState,
  formData: FormData,
): Promise<TaxOverrideState> {
  try {
    await withdrawTaxOverride({
      override_id: text(formData, "override_id"),
      reason: text(formData, "reason"),
    });
  } catch (error) {
    if (error instanceof AuthzError) {
      return {
        status: "error",
        message: describeAuthzError(error),
        stepUp: error.code === "STEP_UP_REQUIRED",
      };
    }
    return { status: "error", message: "Koreksi tidak dapat ditarik. Alasan minimal 5 karakter." };
  }
  revalidatePath(text(formData, "path") || "/");
  return { status: "ok", message: "Koreksi pajak ditarik." };
}
