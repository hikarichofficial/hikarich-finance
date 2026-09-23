import "server-only";
import { z, type ZodType } from "zod";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { AuthzError, parseAuthzCode } from "@/domain/authz/errors";
import { uuidResultSchema } from "@/schemas/accounting";
import {
  commitImportBatchInputSchema,
  commitImportBatchResultSchema,
  getImportBatchRowsInputSchema,
  importBatchListSchema,
  importRowListSchema,
  legacyOpenItemListSchema,
  listImportBatchesInputSchema,
  listLegacyOpenItemsInputSchema,
  rollbackImportBatchInputSchema,
  rollbackImportBatchResultSchema,
  settleLegacyOpenItemInputSchema,
  stageImportBatchInputSchema,
  validateImportBatchInputSchema,
  validateImportBatchResultSchema,
  type CommitImportBatchResult,
  type ImportBatchRow,
  type ImportRowRow,
  type LegacyOpenItemRow,
  type RollbackImportBatchResult,
  type ValidateImportBatchResult,
} from "@/schemas/imports";

/**
 * Thin, typed wrappers over the import staging engine RPCs (P11, Step 15 §15, Step 08 §17/§19,
 * Step 01 #43, DATA_CUTOVER items 7-8). Every call runs as the signed-in person; the database owns the
 * whole staging -> mapping -> validation -> preview -> commit/rollback lifecycle (`system.import` /
 * `system.rollback_import`), duplicate detection (batch id + row fingerprint, within-batch and
 * cross-batch), and the "safely and completely reversible" test for rollback (an imported contact is
 * archived only when nothing else references it; a legacy open item always reverses cleanly). This layer
 * validates the input shape, maps the database's error prefixes to AuthzError without leaking detail, and
 * validates what comes back. It holds no business rule of its own. CSV/XLSX parsing and column mapping
 * belong to the caller of `stageImportBatch` — the database receives already-mapped row payloads and never
 * parses a file. Labels live in `@/domain/imports`.
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
    if (code) throw new AuthzError(code);
    throw new Error("Operasi impor gagal diproses.");
  }
  const parsed = schema.safeParse(data);
  if (!parsed.success) throw new Error("Respons impor tidak dikenali.");
  return parsed.data;
}

const textResult = z.string();

// ================================================================ staging / validation / commit / rollback
export async function stageImportBatch(
  input: z.input<typeof stageImportBatchInputSchema>,
): Promise<string> {
  const v = stageImportBatchInputSchema.parse(input);
  return callRpc(
    "stage_import_batch",
    {
      p_entity: v.entity_id,
      p_domain: v.domain,
      p_mapping: v.mapping,
      p_rows: v.rows,
      p_source_file_name: v.source_file_name ?? null,
    },
    uuidResultSchema,
  );
}

/** Rows may be freely re-validated while the batch is still `staging`. */
export async function validateImportBatch(
  input: z.input<typeof validateImportBatchInputSchema>,
): Promise<ValidateImportBatchResult> {
  const v = validateImportBatchInputSchema.parse(input);
  const rows = await callRpc(
    "validate_import_batch",
    { p_batch: v.batch_id },
    z.array(validateImportBatchResultSchema),
  );
  if (rows.length !== 1) throw new Error("Respons impor tidak dikenali.");
  return rows[0];
}

/** One bad row never aborts the whole batch (Step 08 §19): a row that fails during commit is reported in
 * `skipped_rows` and left inspectable, not silently dropped. */
export async function commitImportBatch(
  input: z.input<typeof commitImportBatchInputSchema>,
): Promise<CommitImportBatchResult> {
  const v = commitImportBatchInputSchema.parse(input);
  const rows = await callRpc(
    "commit_import_batch",
    { p_batch: v.batch_id },
    z.array(commitImportBatchResultSchema),
  );
  if (rows.length !== 1) throw new Error("Respons impor tidak dikenali.");
  return rows[0];
}

/** Reverses what can be safely and completely reversed (Step 08 §19): a legacy open item always reverses;
 * an imported contact is archived only when nothing else in the Entity references it yet, and is otherwise
 * left committed and reported in `retained_rows`, never silently skipped. */
export async function rollbackImportBatch(
  input: z.input<typeof rollbackImportBatchInputSchema>,
): Promise<RollbackImportBatchResult> {
  const v = rollbackImportBatchInputSchema.parse(input);
  const rows = await callRpc(
    "rollback_import_batch",
    { p_batch: v.batch_id, p_reason: v.reason },
    z.array(rollbackImportBatchResultSchema),
  );
  if (rows.length !== 1) throw new Error("Respons impor tidak dikenali.");
  return rows[0];
}

// ================================================================ reads
export async function listImportBatches(
  input: z.input<typeof listImportBatchesInputSchema>,
): Promise<ImportBatchRow[]> {
  const v = listImportBatchesInputSchema.parse(input);
  return callRpc(
    "list_import_batches",
    { p_entity: v.entity_id, p_domain: v.domain ?? null },
    importBatchListSchema,
  );
}

export async function getImportBatchRows(
  input: z.input<typeof getImportBatchRowsInputSchema>,
): Promise<ImportRowRow[]> {
  const v = getImportBatchRowsInputSchema.parse(input);
  return callRpc(
    "get_import_batch_rows",
    { p_batch: v.batch_id, p_status: v.status ?? null },
    importRowListSchema,
  );
}

// ================================================================ legacy open items (DATA_CUTOVER 7-8)
export async function listLegacyOpenItems(
  input: z.input<typeof listLegacyOpenItemsInputSchema>,
): Promise<LegacyOpenItemRow[]> {
  const v = listLegacyOpenItemsInputSchema.parse(input);
  return callRpc(
    "list_legacy_open_items",
    { p_entity: v.entity_id, p_kind: v.kind, p_status: v.status ?? null },
    legacyOpenItemListSchema,
  );
}

export async function settleLegacyOpenItem(
  input: z.input<typeof settleLegacyOpenItemInputSchema>,
): Promise<string> {
  const v = settleLegacyOpenItemInputSchema.parse(input);
  return callRpc(
    "settle_legacy_open_item",
    { p_item: v.item_id, p_status: v.status, p_note: v.note ?? null },
    textResult,
  );
}
