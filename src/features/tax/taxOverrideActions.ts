"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { AuthzError, authzErrorMessage } from "@/domain/authz/errors";
import { setTaxOverride } from "@/services/tax/tax";

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
      const match = /^(?:INVALID|CONFLICT|STEP_UP_REQUIRED):\s*([\s\S]+)$/.exec(error.message);
      const base = authzErrorMessage(error.code);
      return {
        status: "error",
        message: match?.[1] ? `${base} (${match[1].trim()})` : base,
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
