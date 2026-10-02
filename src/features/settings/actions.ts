"use server";

import { revalidatePath } from "next/cache";
import { AuthzError, authzErrorMessage } from "@/domain/authz/errors";
import { isFiscalYearLockedMessage } from "@/domain/settings/settings";
import { requirePermission } from "@/services/identity/access";
import { updateEntityTimeSettings } from "@/services/settings/settings";

/** Settings write (decision 248): the Entity's timezone and fiscal-year start. The RPC re-checks the
 * permission, step-up, reason, version and the fiscal-year lock. */

export interface TimeSettingsState {
  status: "idle" | "ok" | "error";
  message?: string;
  stepUp?: boolean;
}

function text(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

export async function updateTimeSettingsAction(
  _previous: TimeSettingsState,
  formData: FormData,
): Promise<TimeSettingsState> {
  try {
    const { membership } = await requirePermission("system.entity_config", {
      entityCode: text(formData, "entity"),
    });
    await updateEntityTimeSettings({
      entity_id: membership.entity_id,
      timezone: text(formData, "timezone"),
      fiscal_year_start_month: Number(text(formData, "fiscal_year_start_month")),
      expected_version: Number(text(formData, "expected_version")),
      reason: text(formData, "reason"),
    });
  } catch (error) {
    if (error instanceof AuthzError) {
      if (error.code === "CONFLICT" && isFiscalYearLockedMessage(error.message)) {
        return {
          status: "error",
          message: "Awal tahun buku tidak dapat diubah karena periode akuntansi sudah ada.",
        };
      }
      return {
        status: "error",
        message: authzErrorMessage(error.code),
        stepUp: error.code === "STEP_UP_REQUIRED",
      };
    }
    return {
      status: "error",
      message: "Pengaturan tidak dapat disimpan. Pastikan alasan diisi minimal 5 karakter.",
    };
  }
  revalidatePath("/admin/settings");
  return { status: "ok", message: "Zona waktu dan tahun buku disimpan." };
}
