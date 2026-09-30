import { z } from "zod";
import { uuidResultSchema } from "@/schemas/accounting";

/**
 * Input and output contracts of the Backup & Restore Center RPCs (P14, Step 01 #36, Step 16 §34,
 * decision 224). Export and validate-before-restore only in this Part 1 -- the database owns every
 * rule (which tables a Full/Data-only/Documents-Archive export carries, Entity isolation, permission).
 * This layer validates the input shape and what comes back; it holds no business rule of its own.
 * Labels live in `@/domain/backup`.
 */

export const backupKindSchema = z.enum(["full", "data_only", "documents_archive"]);
export type BackupKind = z.infer<typeof backupKindSchema>;

export const exportBackupSnapshotInputSchema = z.object({
  entity_id: uuidResultSchema,
  kind: backupKindSchema,
});

/** `table_counts`/`data` are keyed by table name; each table's own row shape is whatever that table's
 * columns are (over 100 tables, per `app_private.backup_export_tables`' own dynamic discovery), so this
 * stays a plain JSON record rather than a per-table typed schema -- re-modelling every business table's
 * shape a second time here, only for a backup export, is not this layer's job. */
export const exportBackupSnapshotResultSchema = z.object({
  job_id: uuidResultSchema,
  entity_id: uuidResultSchema,
  kind: backupKindSchema,
  checksum: z.string().min(1),
  created_at: z.string(),
  table_counts: z.record(z.string(), z.number().int().nonnegative()),
  data: z.record(z.string(), z.unknown()),
});
export type BackupSnapshot = z.infer<typeof exportBackupSnapshotResultSchema>;

export const backupJobRowSchema = z.object({
  id: uuidResultSchema,
  entity_id: uuidResultSchema,
  kind: backupKindSchema,
  requested_by: uuidResultSchema,
  table_count: z.number().int().nonnegative(),
  row_counts: z.record(z.string(), z.number().int().nonnegative()),
  byte_size: z.number().int().nonnegative(),
  checksum: z.string(),
  created_at: z.string(),
});
export type BackupJobRow = z.infer<typeof backupJobRowSchema>;
export const backupJobListSchema = z.array(backupJobRowSchema);

export const validateBackupPayloadInputSchema = z.object({
  entity_id: uuidResultSchema,
  // The uploaded file's parsed JSON, shape unknown until the RPC itself inspects it -- that is the
  // whole point of "validation before restore" (Step 01 #36).
  payload: z.unknown(),
});

export const validateBackupPayloadResultSchema = z.object({
  ok: z.boolean(),
  errors: z.array(z.string()),
  warnings: z.array(z.string()),
});
export type BackupValidationResult = z.infer<typeof validateBackupPayloadResultSchema>;
