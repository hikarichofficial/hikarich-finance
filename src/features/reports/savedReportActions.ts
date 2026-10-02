"use server";

import { revalidatePath } from "next/cache";
import { AuthzError, authzErrorMessage } from "@/domain/authz/errors";
import { requirePermission } from "@/services/identity/access";
import { deleteSavedReport, saveReport } from "@/services/reports/reports";

/** Saved Reports (decision 252): save the current report view (path + filters) under a name, or delete
 * one. The RPCs keep each person's list private and require `reports.view`. */

export interface SavedReportState {
  status: "idle" | "ok" | "error";
  message?: string;
}

export const idleSavedReportState: SavedReportState = { status: "idle" };

function text(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

export async function saveReportAction(
  _previous: SavedReportState,
  formData: FormData,
): Promise<SavedReportState> {
  try {
    const { membership } = await requirePermission("reports.view", {
      entityCode: text(formData, "entity"),
    });
    await saveReport({
      entity_id: membership.entity_id,
      name: text(formData, "name"),
      path: text(formData, "path"),
      query: text(formData, "query"),
    });
  } catch (error) {
    if (error instanceof AuthzError && error.code === "CONFLICT") {
      return { status: "error", message: "Nama itu sudah dipakai. Pilih nama lain." };
    }
    if (error instanceof AuthzError)
      return { status: "error", message: authzErrorMessage(error.code) };
    return { status: "error", message: "Laporan tidak dapat disimpan. Nama 2–120 karakter." };
  }
  revalidatePath("/reports/saved");
  return { status: "ok", message: "Tersimpan di Laporan Tersimpan." };
}

export async function deleteSavedReportAction(
  _previous: SavedReportState,
  formData: FormData,
): Promise<SavedReportState> {
  try {
    await deleteSavedReport(text(formData, "id"));
  } catch (error) {
    if (error instanceof AuthzError)
      return { status: "error", message: authzErrorMessage(error.code) };
    return { status: "error", message: "Laporan tersimpan tidak dapat dihapus." };
  }
  revalidatePath("/reports/saved");
  return { status: "ok", message: "Dihapus." };
}
