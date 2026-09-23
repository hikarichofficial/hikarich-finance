import { z } from "zod";
import { isoDateSchema, moneyTextSchema } from "@/schemas/accounting";

/**
 * Input and output contracts of the import staging engine RPCs (P11, Step 15 §15, Step 08 §17/§19,
 * Step 01 #43, DATA_CUTOVER items 7-8). CSV/XLSX parsing and column mapping happen in the application
 * layer (`@/services/imports`) — the database receives already-mapped row payloads and only validates
 * business rules; it never parses a file (DECISIONS 143-144). This layer validates the input shape and
 * what comes back; it holds no business rule of its own. Labels live in `@/domain/imports`.
 */

export const importDomainSchema = z.enum([
  "contacts",
  "legacy_open_receivables",
  "legacy_open_payables",
]);
export type ImportDomain = z.infer<typeof importDomainSchema>;

export const importBatchStatusSchema = z.enum(["staging", "validated", "committed", "rolled_back"]);
export type ImportBatchStatus = z.infer<typeof importBatchStatusSchema>;

export const importRowStatusSchema = z.enum([
  "pending",
  "valid",
  "invalid",
  "duplicate",
  "committed",
  "rolled_back",
]);
export type ImportRowStatus = z.infer<typeof importRowStatusSchema>;

export const legacyOpenItemKindSchema = z.enum(["receivable", "payable"]);
export type LegacyOpenItemKind = z.infer<typeof legacyOpenItemKindSchema>;

export const legacyOpenItemStatusSchema = z.enum(["open", "settled", "written_off", "rolled_back"]);
export type LegacyOpenItemStatus = z.infer<typeof legacyOpenItemStatusSchema>;

// ================================================================ staging
export const stageImportBatchInputSchema = z.object({
  entity_id: z.uuid(),
  domain: importDomainSchema,
  mapping: z.record(z.string(), z.unknown()).default({}),
  rows: z.array(z.record(z.string(), z.unknown())).min(1).max(5000),
  source_file_name: z.string().trim().max(300).optional(),
});

export const validateImportBatchInputSchema = z.object({ batch_id: z.uuid() });

export const validateImportBatchResultSchema = z.object({
  total_rows: z.number().int(),
  valid_rows: z.number().int(),
  invalid_rows: z.number().int(),
  duplicate_rows: z.number().int(),
});
export type ValidateImportBatchResult = z.infer<typeof validateImportBatchResultSchema>;

export const commitImportBatchInputSchema = z.object({ batch_id: z.uuid() });

export const commitImportBatchResultSchema = z.object({
  committed_rows: z.number().int(),
  skipped_rows: z.number().int(),
});
export type CommitImportBatchResult = z.infer<typeof commitImportBatchResultSchema>;

export const rollbackImportBatchInputSchema = z.object({
  batch_id: z.uuid(),
  reason: z.string().trim().min(3).max(1000),
});

export const rollbackImportBatchResultSchema = z.object({
  rolled_back_rows: z.number().int(),
  retained_rows: z.number().int(),
});
export type RollbackImportBatchResult = z.infer<typeof rollbackImportBatchResultSchema>;

// ================================================================ reads
export const listImportBatchesInputSchema = z.object({
  entity_id: z.uuid(),
  domain: importDomainSchema.optional(),
});

export const importBatchRowSchema = z.object({
  batch_id: z.uuid(),
  domain: importDomainSchema,
  status: importBatchStatusSchema,
  row_count: z.number().int(),
  source_file_name: z.string().nullable(),
  created_at: z.string(),
  created_by: z.uuid().nullable(),
});
export const importBatchListSchema = z.array(importBatchRowSchema);
export type ImportBatchRow = z.infer<typeof importBatchRowSchema>;

export const getImportBatchRowsInputSchema = z.object({
  batch_id: z.uuid(),
  status: importRowStatusSchema.optional(),
});

export const importRowRowSchema = z.object({
  row_id: z.uuid(),
  row_no: z.number().int(),
  raw_payload: z.unknown(),
  mapped_payload: z.unknown().nullable(),
  status: importRowStatusSchema,
  messages: z.array(z.string()),
  target_type: z.enum(["contact", "legacy_open_item"]).nullable(),
  target_record_id: z.uuid().nullable(),
});
export const importRowListSchema = z.array(importRowRowSchema);
export type ImportRowRow = z.infer<typeof importRowRowSchema>;

// ================================================================ legacy open items (DATA_CUTOVER 7-8)
export const listLegacyOpenItemsInputSchema = z.object({
  entity_id: z.uuid(),
  kind: legacyOpenItemKindSchema,
  status: legacyOpenItemStatusSchema.optional(),
});

export const legacyOpenItemRowSchema = z.object({
  item_id: z.uuid(),
  contact_id: z.uuid(),
  contact_name: z.string(),
  amount: moneyTextSchema,
  currency: z.string().length(3),
  txn_date: isoDateSchema,
  due_date: isoDateSchema.nullable(),
  reference: z.string().nullable(),
  status: legacyOpenItemStatusSchema,
});
export const legacyOpenItemListSchema = z.array(legacyOpenItemRowSchema);
export type LegacyOpenItemRow = z.infer<typeof legacyOpenItemRowSchema>;

export const settleLegacyOpenItemInputSchema = z.object({
  item_id: z.uuid(),
  status: z.enum(["settled", "written_off"]),
  note: z.string().trim().max(1000).optional(),
});
