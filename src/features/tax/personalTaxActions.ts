"use server";

import { revalidatePath } from "next/cache";
import { AuthzError, describeAuthzError } from "@/domain/authz/errors";
import { ptkpStatusSchema } from "@/schemas/personalTax";
import { requirePermission } from "@/services/identity/access";
import { setPtkpStatus } from "@/services/tax/tax";

/**
 * The one thing a person tells the system for the progressive tax: the PTKP status for the year (decision 365).
 * Everything else on Pajak Pribadi is read from the books and from the owner's own PT.
 */

export interface PtkpState {
  status: "idle" | "ok" | "error";
  message?: string;
}

export async function setPtkpAction(_previous: PtkpState, formData: FormData): Promise<PtkpState> {
  const entity = String(formData.get("entity") ?? "");
  const year = Number(formData.get("year"));
  const parsed = ptkpStatusSchema.safeParse(formData.get("status"));
  if (!parsed.success || !Number.isInteger(year)) {
    return { status: "error", message: "Pilih status PTKP." };
  }
  try {
    const { membership } = await requirePermission("tax.confirm_facts", { entityCode: entity });
    await setPtkpStatus({ entity_id: membership.entity_id, year, status: parsed.data });
  } catch (error) {
    if (error instanceof AuthzError) return { status: "error", message: describeAuthzError(error) };
    return { status: "error", message: "Status PTKP tidak dapat disimpan." };
  }
  revalidatePath("/tax/personal");
  return { status: "ok", message: "Status PTKP tersimpan." };
}
