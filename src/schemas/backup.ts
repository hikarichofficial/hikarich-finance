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

// ------------------------------------------------------------ Part 2: restore (decision 247)

/** Upper bound for a backup file sent through a Server Action (the deployment's request-body ceiling,
 * `next.config.ts` `serverActions.bodySizeLimit`). Checked in the browser before upload so the person
 * gets a clear message instead of a framework error. */
export const RESTORE_FILE_MAX_BYTES = 4 * 1024 * 1024;

const countRecordSchema = z.record(z.string(), z.number().int().nonnegative());

export const restoreFileInputSchema = z.object({
  entity_id: uuidResultSchema,
  // The backup file's exact text -- never parsed and re-serialised in the browser, so money values keep
  // their exact digits and the checksum is verified over what was exported.
  file: z.string().min(1).max(RESTORE_FILE_MAX_BYTES),
});

export const restorePreviewSchema = z.object({
  ok: z.boolean(),
  errors: z.array(z.string()),
  warnings: z.array(z.string()),
  target_rows: countRecordSchema,
  table_counts: countRecordSchema,
  step_up_ok: z.boolean(),
});
export type RestorePreview = z.infer<typeof restorePreviewSchema>;

export const restoreIntegritySchema = z.object({
  ok: z.boolean().optional(),
  count_mismatches: z.array(z.string()).optional(),
  unbalanced_journals: z.number().optional(),
  trial_balance_difference: z.union([z.number(), z.string()]).optional(),
});
export type RestoreIntegrity = z.infer<typeof restoreIntegritySchema>;

export const restoreStatusSchema = z.enum(["completed", "failed"]);
export type RestoreStatus = z.infer<typeof restoreStatusSchema>;

export const restoreResultSchema = z.object({
  job_id: uuidResultSchema,
  status: restoreStatusSchema,
  table_counts: countRecordSchema,
  skipped: countRecordSchema,
  integrity: restoreIntegritySchema,
  error: z.string().nullable(),
});
export type RestoreResult = z.infer<typeof restoreResultSchema>;

export const restoreJobRowSchema = z.object({
  id: uuidResultSchema,
  entity_id: uuidResultSchema,
  requested_by: uuidResultSchema,
  source_kind: z.string(),
  source_checksum: z.string(),
  status: restoreStatusSchema,
  table_counts: countRecordSchema,
  skipped: countRecordSchema,
  integrity: restoreIntegritySchema,
  error: z.string().nullable(),
  created_at: z.string(),
});
export type RestoreJobRow = z.infer<typeof restoreJobRowSchema>;
export const restoreJobListSchema = z.array(restoreJobRowSchema);
