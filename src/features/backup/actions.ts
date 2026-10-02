"use server";

import { revalidatePath } from "next/cache";
import { AuthzError, describeAuthzError } from "@/domain/authz/errors";
import {
  exportBackupFile,
  previewBackupRestore,
  restoreBackupSnapshot,
} from "@/services/backup/backup";
import type { BackupKind, RestorePreview, RestoreResult } from "@/schemas/backup";

/**
 * Server Actions behind the Backup & Restore Center screen (P14, Step 01 #36, decisions 224 and 247),
 * called directly from client code the same way `searchRecordsAction` already is -- plain async
 * functions, since Export returns a file the client saves, and Preview/Restore carry the text of a file
 * the person picked locally. Each maps a thrown `AuthzError` to the same user-safe Indonesian copy every
 * other module's actions use; the database re-checks every rule on its own.
 */

export type BackupExportResult =
  | { status: "ok"; file: string; kind: BackupKind }
  | { status: "error"; message: string };

export type RestorePreviewActionResult =
  | { status: "ok"; preview: RestorePreview }
  | { status: "error"; message: string };

export type RestoreActionResult =
  | { status: "ok"; result: RestoreResult }
  | { status: "error"; message: string; code?: AuthzError["code"] };

function errorMessage(error: unknown, fallback: string): string {
  if (error instanceof AuthzError) return describeAuthzError(error);
  return fallback;
}

export async function exportBackupAction(
  entityId: string,
  kind: BackupKind,
): Promise<BackupExportResult> {
  try {
    const file = await exportBackupFile(entityId, kind);
    revalidatePath("/admin/backup");
    return { status: "ok", file, kind };
  } catch (error) {
    return { status: "error", message: errorMessage(error, "Ekspor backup gagal diproses.") };
  }
}

export async function previewRestoreAction(
  entityId: string,
  file: string,
): Promise<RestorePreviewActionResult> {
  try {
    const preview = await previewBackupRestore(entityId, file);
    return { status: "ok", preview };
  } catch (error) {
    return { status: "error", message: errorMessage(error, "Pemeriksaan berkas backup gagal.") };
  }
}

export async function restoreBackupAction(
  entityId: string,
  file: string,
  confirmCode: string,
): Promise<RestoreActionResult> {
  try {
    const result = await restoreBackupSnapshot(entityId, file, confirmCode);
    revalidatePath("/admin/backup");
    return { status: "ok", result };
  } catch (error) {
    if (error instanceof AuthzError) {
      return { status: "error", message: describeAuthzError(error), code: error.code };
    }
    return { status: "error", message: "Pemulihan gagal diproses." };
  }
}
