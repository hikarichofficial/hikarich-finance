import "server-only";
import { z, type ZodType } from "zod";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { AuthzError, parseAuthzCode } from "@/domain/authz/errors";
import {
  backupJobListSchema,
  restoreFileInputSchema,
  restoreJobListSchema,
  restorePreviewSchema,
  restoreResultSchema,
  type RestoreJobRow,
  type RestorePreview,
  type RestoreResult,
  exportBackupSnapshotInputSchema,
  exportBackupSnapshotResultSchema,
  validateBackupPayloadInputSchema,
  validateBackupPayloadResultSchema,
  type BackupJobRow,
  type BackupKind,
  type BackupSnapshot,
  type BackupValidationResult,
} from "@/schemas/backup";

/**
 * Thin, typed wrappers over the Backup & Restore Center RPCs (P14, Step 01 #36, Step 16 §34, decision
 * 224). Every call runs as the signed-in person; the database decides who may act (`backup.create`,
 * `backup.restore`) and owns every rule (which tables each kind carries, Entity isolation, validation).
 * This layer validates the input shape, maps the database's error prefixes to AuthzError without
 * leaking detail, and validates what comes back. It holds no business rule of its own. Labels live in
 * `@/domain/backup`.
 */

async function callRpc<T>(
  name: string,
  args: Record<string, unknown>,
  schema: ZodType<T>,
): Promise<T> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc(name, args);
  if (error) {
    const code = parseAuthzCode(error.message);
    if (code) throw new AuthzError(code, error.message);
    throw new Error("Operasi backup gagal diproses.");
  }
  const parsed = schema.safeParse(data);
  if (!parsed.success) throw new Error("Respons backup tidak dikenali.");
  return parsed.data;
}

export async function exportBackupSnapshot(
  entityId: string,
  kind: BackupKind,
): Promise<BackupSnapshot> {
  const v = exportBackupSnapshotInputSchema.parse({ entity_id: entityId, kind });
  return callRpc(
    "export_backup_snapshot",
    { p_entity: v.entity_id, p_kind: v.kind },
    exportBackupSnapshotResultSchema,
  );
}

export async function validateBackupPayload(
  entityId: string,
  payload: unknown,
): Promise<BackupValidationResult> {
  const v = validateBackupPayloadInputSchema.parse({ entity_id: entityId, payload });
  return callRpc(
    "validate_backup_payload",
    { p_entity: v.entity_id, p_payload: v.payload },
    validateBackupPayloadResultSchema,
  );
}

/** Direct RLS-scoped table read (`backup_jobs_select`, `20260930300000_p14_backup_restore.sql`) --
 * the same "no RPC exists, direct table read" shape `listActiveCategories` (decision 187) and the
 * money/reports modules' own picker lists already establish, reused here for a plain history listing
 * rather than a bespoke `list_backup_history` RPC. */
export async function listBackupHistory(entityId: string, limit = 20): Promise<BackupJobRow[]> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("backup_jobs")
    .select(
      "id, entity_id, kind, requested_by, table_count, row_counts, byte_size, checksum, created_at",
    )
    .eq("entity_id", entityId)
    .order("created_at", { ascending: false })
    .limit(limit);
  if (error) throw new Error("Gagal memuat riwayat backup.");
  const parsed = backupJobListSchema.safeParse(data);
  if (!parsed.success) throw new Error("Respons riwayat backup tidak dikenali.");
  return parsed.data;
}

// ------------------------------------------------------------ Part 2: restore (decision 247)

/** The backup file exactly as the database serialised it (`export_backup_file`), so the browser saves it
 * byte-for-byte: no JSON round-trip in JavaScript, which would turn exact NUMERIC money values into
 * doubles. Also records the export in `backup_jobs`, like `export_backup_snapshot`. */
export async function exportBackupFile(entityId: string, kind: BackupKind): Promise<string> {
  const v = exportBackupSnapshotInputSchema.parse({ entity_id: entityId, kind });
  return callRpc(
    "export_backup_file",
    { p_entity: v.entity_id, p_kind: v.kind },
    z.string().min(1),
  );
}

/** Read-only impact preview: validation errors/warnings, rows per table in the file, rows already in the
 * target Entity, and whether the caller's step-up window is currently satisfied. */
export async function previewBackupRestore(
  entityId: string,
  file: string,
): Promise<RestorePreview> {
  const v = restoreFileInputSchema.parse({ entity_id: entityId, file });
  return callRpc(
    "preview_backup_restore",
    { p_entity: v.entity_id, p_file: v.file },
    restorePreviewSchema,
  );
}

/** Runs the restore. The database re-checks everything (permission, step-up, typed Entity code,
 * empty target, checksum) and either commits a verified restore or records a Failed job with nothing
 * written. */
export async function restoreBackupSnapshot(
  entityId: string,
  file: string,
  confirmCode: string,
): Promise<RestoreResult> {
  const v = restoreFileInputSchema.parse({ entity_id: entityId, file });
  return callRpc(
    "restore_backup_snapshot",
    { p_entity: v.entity_id, p_file: v.file, p_confirm: confirmCode },
    restoreResultSchema,
  );
}

/** Direct RLS-scoped read (`restore_jobs_select`, `backup.restore`), same shape as `listBackupHistory`. */
export async function listRestoreHistory(entityId: string, limit = 20): Promise<RestoreJobRow[]> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("restore_jobs")
    .select(
      "id, entity_id, requested_by, source_kind, source_checksum, status, table_counts, skipped, integrity, error, created_at",
    )
    .eq("entity_id", entityId)
    .order("created_at", { ascending: false })
    .limit(limit);
  if (error) throw new Error("Gagal memuat riwayat pemulihan.");
  const parsed = restoreJobListSchema.safeParse(data);
  if (!parsed.success) throw new Error("Respons riwayat pemulihan tidak dikenali.");
  return parsed.data;
}
