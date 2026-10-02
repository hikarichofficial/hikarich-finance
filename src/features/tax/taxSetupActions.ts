"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { AuthzError, authzErrorMessage } from "@/domain/authz/errors";
import { requirePermission } from "@/services/identity/access";
import { activateTaxEngine, recordEntityProfile } from "@/services/tax/tax";

/**
 * Server actions behind Tax Setup (decision 258): the Entity's effective-dated tax profile
 * (`tax_record_entity_profile`) and the engine switch (`tax_engine_activate`, OWNER + recent step-up).
 * Unmodified P7 RPCs; this layer shapes form input and words the errors.
 */

export interface TaxSetupState {
  status: "idle" | "ok" | "error";
  message?: string;
  stepUp?: boolean;
}

export const idleTaxSetupState: TaxSetupState = { status: "idle" };

function text(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function errorState(error: unknown, fallback: string): TaxSetupState {
  if (error instanceof AuthzError) {
    const match = /^(?:INVALID|CONFLICT):\s*([\s\S]+)$/.exec(error.message);
    const base = authzErrorMessage(error.code);
    return {
      status: "error",
      message: match?.[1] ? `${base} (${match[1].trim()})` : base,
      stepUp: error.code === "STEP_UP_REQUIRED",
    };
  }
  return { status: "error", message: fallback };
}

export async function recordTaxProfileAction(
  _previous: TaxSetupState,
  formData: FormData,
): Promise<TaxSetupState> {
  const entity = text(formData, "entity");
  try {
    const { membership } = await requirePermission("tax.confirm_facts", { entityCode: entity });
    await recordEntityProfile({
      entity_id: membership.entity_id,
      idempotency_key: randomUUID(),
      effective_from: text(formData, "effective_from"),
      taxpayer_kind: text(formData, "taxpayer_kind") as never,
      residency: "resident",
      income_regime: text(formData, "income_regime") as never,
      umkm_exclusion: text(formData, "umkm_exclusion") as never,
      aggregation_status: text(formData, "aggregation_status") as never,
      vat_status: text(formData, "vat_status") as never,
      withholding_agent: text(formData, "withholding_agent") as never,
      tax_identifier: text(formData, "tax_identifier") || null,
      evidence_note: text(formData, "evidence_note") || undefined,
    });
  } catch (error) {
    return errorState(error, "Profil pajak tidak dapat disimpan. Periksa isian.");
  }
  revalidatePath("/tax");
  revalidatePath("/tax/setup");
  return { status: "ok", message: "Profil pajak tersimpan." };
}

export async function activateTaxEngineAction(
  _previous: TaxSetupState,
  formData: FormData,
): Promise<TaxSetupState> {
  const entity = text(formData, "entity");
  try {
    const { membership } = await requirePermission("tax.confirm_facts", { entityCode: entity });
    await activateTaxEngine({
      entity_id: membership.entity_id,
      idempotency_key: randomUUID(),
      from: text(formData, "from"),
    });
  } catch (error) {
    return errorState(error, "Mesin pajak tidak dapat diaktifkan.");
  }
  revalidatePath("/tax");
  revalidatePath("/tax/setup");
  return { status: "ok", message: "Mesin pajak aktif." };
}
