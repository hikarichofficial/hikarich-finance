"use server";

import { revalidatePath } from "next/cache";
import { AuthzError, authzErrorMessage } from "@/domain/authz/errors";
import { exportBackupSnapshot, validateBackupPayload } from "@/services/backup/backup";
import type { BackupKind, BackupSnapshot, BackupValidationResult } from "@/schemas/backup";

/**
 * Server Actions behind the Backup & Restore Center screen (P14, Step 01 #36, decision 224), called
 * directly from client code the same way `searchRecordsAction` already is (`src/features/shell/
 * searchActions.ts`) -- a plain async function, not `useActionState`, since neither action here
 * submits a mutating `<form>`: Export fetches a payload the client then turns into a file download, and
 * Validate fetches a report over a file the person picked locally. Both still map a thrown `AuthzError`
 * to the same user-safe Indonesian copy every other module's actions already use.
 */

export type BackupExportResult =
  { status: "ok"; snapshot: BackupSnapshot } | { status: "error"; message: string };

export type BackupValidateResult =
  { status: "ok"; result: BackupValidationResult } | { status: "error"; message: string };

function errorMessage(error: unknown, fallback: string): string {
  if (error instanceof AuthzError) return authzErrorMessage(error.code);
  return fallback;
}

export async function exportBackupAction(
  entityId: string,
  kind: BackupKind,
): Promise<BackupExportResult> {
  try {
    const snapshot = await exportBackupSnapshot(entityId, kind);
    revalidatePath("/admin/backup");
    return { status: "ok", snapshot };
  } catch (error) {
    return { status: "error", message: errorMessage(error, "Ekspor backup gagal diproses.") };
  }
}

export async function validateBackupAction(
  entityId: string,
  payload: unknown,
): Promise<BackupValidateResult> {
  try {
    const result = await validateBackupPayload(entityId, payload);
    return { status: "ok", result };
  } catch (error) {
    return { status: "error", message: errorMessage(error, "Validasi backup gagal diproses.") };
  }
}
