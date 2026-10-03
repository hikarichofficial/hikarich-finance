"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { AuthzError, describeAuthzError } from "@/domain/authz/errors";
import { isFiscalYearLockedMessage } from "@/domain/settings/settings";
import { requirePermission } from "@/services/identity/access";
import {
  createEntity,
  updateEntityIdentity,
  updateEntityTimeSettings,
} from "@/services/settings/settings";

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
        message: describeAuthzError(error),
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

/** Settings write (decision 272): the Entity's names, address and contact details. The RPC re-checks the
 * permission, step-up and version. Issued documents keep the name they were issued with. */
export async function updateEntityIdentityAction(
  _previous: TimeSettingsState,
  formData: FormData,
): Promise<TimeSettingsState> {
  try {
    const { membership } = await requirePermission("system.entity_config", {
      entityCode: text(formData, "entity"),
    });
    await updateEntityIdentity({
      entity_id: membership.entity_id,
      legal_name: text(formData, "legal_name"),
      brand_name: text(formData, "brand_name"),
      address_line: text(formData, "address_line"),
      city: text(formData, "city"),
      province: text(formData, "province"),
      postal_code: text(formData, "postal_code"),
      contact_email: text(formData, "contact_email"),
      contact_phone: text(formData, "contact_phone"),
      website: text(formData, "website"),
      expected_version: Number(text(formData, "expected_version")),
    });
  } catch (error) {
    if (error instanceof AuthzError) {
      return {
        status: "error",
        message: describeAuthzError(error),
        stepUp: error.code === "STEP_UP_REQUIRED",
      };
    }
    return { status: "error", message: "Profil tidak dapat disimpan. Periksa nama dan email." };
  }
  revalidatePath("/", "layout");
  return { status: "ok", message: "Nama dan profil disimpan." };
}

/** Add an Entity (decision 276). `create_entity` decides who may; on success the person lands on the new
 * Entity's Settings, where the address and tax details are filled in next. */
export async function createEntityAction(
  _previous: TimeSettingsState,
  formData: FormData,
): Promise<TimeSettingsState> {
  const code = text(formData, "code").toLowerCase();
  try {
    await createEntity({
      code,
      entity_type: text(formData, "entity_type") === "personal" ? "personal" : "company",
      legal_name: text(formData, "legal_name"),
      brand_name: text(formData, "brand_name"),
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
      message:
        "Entity tidak dapat dibuat. Kode: 2 sampai 31 huruf kecil, angka, - atau _, diawali huruf.",
    };
  }
  revalidatePath("/", "layout");
  redirect(`/admin/settings?entity=${encodeURIComponent(code)}`);
}
