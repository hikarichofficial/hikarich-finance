import { z } from "zod";

/**
 * Contracts private to the Dashboard's own composition layer (P13 Part 2, Step 09 §8, Step 10 §10-13).
 * The Dashboard has no RPC of its own -- it only composes already-shipped report/service RPCs -- except
 * for this one plain, RLS-governed read of `entities.base_currency`: every financial-statement and
 * aggregate RPC the Dashboard calls (`profit_and_loss`, `statement_of_changes_in_equity`,
 * `cash_flow_statement`, `ar_aging`, `ap_aging`, `money_control`) returns its figures in the Entity's base
 * currency without repeating the currency code on every row, and no existing RPC surfaces that code to the
 * client (DECISIONS #161). `entities_select` (Step 06/P2 RLS) already lets any member read their own
 * Entity row directly, matching the same direct-table-read shape `listFiscalYearClosures` and
 * `listReportDatasets` already use in `@/services/reports/reports`.
 */
export const entityCurrencyRowSchema = z.object({
  base_currency: z.string().min(1),
});
export type EntityCurrencyRow = z.infer<typeof entityCurrencyRowSchema>;
