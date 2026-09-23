import { z } from "zod";
import { isoDateSchema } from "@/schemas/accounting";

/**
 * Input and output contracts of the Global Search RPCs (P11, Step 01 #34, Step 13 §17, Step 06 §11,
 * Step 08 §22). The database is the only authority for what is indexed, kept current (an outbox-driven
 * trigger on each of the nine searchable tables) and, above all, for filtering an inaccessible record out
 * of the result set itself before ranking — never merely hiding it in the UI. This layer validates the
 * input shape and what comes back; it holds no business rule of its own. Labels live in `@/domain/search`.
 */

/** The nine business-record kinds Global Search covers (DECISIONS 145): every `generic_linker = true`
 * document target kind except `import_batch` (a technical artifact, not content a user searches for).
 * Payroll and tax are never indexed — reached through their own permission-gated screens instead. */
export const searchTargetTypeSchema = z.enum([
  "contact",
  "invoice",
  "bill",
  "expense",
  "fixed_asset",
  "loan",
  "other_obligation",
  "equity_event",
  "journal_entry",
]);
export type SearchTargetType = z.infer<typeof searchTargetTypeSchema>;

export const searchInputSchema = z.object({
  entity_id: z.uuid(),
  query: z.string().trim().min(1).max(200),
  limit: z.number().int().min(1).max(100).optional(),
});

export const searchResultRowSchema = z.object({
  target_type: searchTargetTypeSchema,
  target_id: z.uuid(),
  title: z.string(),
  subtitle: z.string().nullable(),
  occurred_on: isoDateSchema.nullable(),
  rank: z.number(),
});
export const searchResultListSchema = z.array(searchResultRowSchema);
export type SearchResultRow = z.infer<typeof searchResultRowSchema>;

// ================================================================ index maintenance
/** The manual "refresh now" action (`system.import`). The scheduled path calls the same database function
 * with the service key and no signed-in user, exactly like P10's recurring occurrences (DECISIONS 136). */
export const refreshSearchIndexBatchInputSchema = z.object({
  limit: z.number().int().min(1).max(1000).optional(),
});

/** Full, derived rebuild for one Entity (Step 08 §22): wipes and repopulates straight from the nine
 * source tables. Never needed in normal operation — the outbox trigger keeps the index current — but
 * available as the recovery path when something needs re-deriving from scratch. */
export const rebuildSearchIndexInputSchema = z.object({ entity_id: z.uuid() });
