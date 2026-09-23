import "server-only";
import { z, type ZodType } from "zod";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { AuthzError, parseAuthzCode } from "@/domain/authz/errors";
import { uuidResultSchema } from "@/schemas/accounting";
import {
  balanceSheetInputSchema,
  balanceSheetSchema,
  cashFlowStatementInputSchema,
  cashFlowStatementSchema,
  closeFiscalYearInputSchema,
  consolidatedCashPositionInputSchema,
  consolidatedCashPositionSchema,
  fiscalYearClosureListSchema,
  generalLedgerInputSchema,
  generalLedgerSchema,
  profitAndLossInputSchema,
  profitAndLossSchema,
  reportDatasetCatalogSchema,
  reverseFiscalYearClosingInputSchema,
  runCustomReportInputSchema,
  customReportSchema,
  statementOfChangesInEquityInputSchema,
  statementOfChangesInEquitySchema,
  type BalanceSheetRow,
  type CashFlowRow,
  type ConsolidatedCashPositionRow,
  type CustomReportRow,
  type EquityChangeRow,
  type FiscalYearClosureRow,
  type GeneralLedgerRow,
  type ProfitAndLossRow,
  type ReportDatasetCatalogRow,
} from "@/schemas/reports";

/**
 * Thin, typed wrappers over the reporting RPCs (P12, Step 12 §3-§5, §15, §17, §19, §31): the canonical
 * financial statements, year-end closing, the curated Custom Report Builder and cross-Entity Consolidated
 * Analysis. Every call runs as the signed-in person; the database decides who may read (`reports.view` and,
 * for a curated dataset, that dataset's own permission) and owns every figure (Step 12 §2: posted data
 * only, no second financial truth). This layer validates the input shape, maps the database's error
 * prefixes to AuthzError without leaking detail, and validates what comes back. It holds no business rule
 * of its own -- turning a debit/credit pair into a natural-direction figure is `@/domain/reports`'s job.
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
    throw new Error("Operasi laporan gagal diproses.");
  }
  const parsed = schema.safeParse(data);
  if (!parsed.success) throw new Error("Respons laporan tidak dikenali.");
  return parsed.data;
}

// ================================================================ canonical financial statements
export async function getProfitAndLoss(
  input: z.input<typeof profitAndLossInputSchema>,
): Promise<ProfitAndLossRow[]> {
  const v = profitAndLossInputSchema.parse(input);
  return callRpc(
    "profit_and_loss",
    {
      p_entity: v.entity_id,
      p_start: v.start_date,
      p_end: v.end_date,
      p_compare_start: v.compare_start_date ?? null,
      p_compare_end: v.compare_end_date ?? null,
    },
    profitAndLossSchema,
  );
}

export async function getBalanceSheet(
  input: z.input<typeof balanceSheetInputSchema>,
): Promise<BalanceSheetRow[]> {
  const v = balanceSheetInputSchema.parse(input);
  return callRpc(
    "balance_sheet",
    { p_entity: v.entity_id, p_as_of: v.as_of ?? null },
    balanceSheetSchema,
  );
}

export async function getStatementOfChangesInEquity(
  input: z.input<typeof statementOfChangesInEquityInputSchema>,
): Promise<EquityChangeRow[]> {
  const v = statementOfChangesInEquityInputSchema.parse(input);
  return callRpc(
    "statement_of_changes_in_equity",
    { p_entity: v.entity_id, p_start: v.start_date, p_end: v.end_date },
    statementOfChangesInEquitySchema,
  );
}

export async function getCashFlowStatement(
  input: z.input<typeof cashFlowStatementInputSchema>,
): Promise<CashFlowRow[]> {
  const v = cashFlowStatementInputSchema.parse(input);
  return callRpc(
    "cash_flow_statement",
    { p_entity: v.entity_id, p_start: v.start_date, p_end: v.end_date },
    cashFlowStatementSchema,
  );
}

/** p_account omitted returns every non-group account's posted lines in range (a Journal Report); a specific
 * account additionally carries a running balance in its own natural direction (a General Ledger card). */
export async function getGeneralLedger(
  input: z.input<typeof generalLedgerInputSchema>,
): Promise<GeneralLedgerRow[]> {
  const v = generalLedgerInputSchema.parse(input);
  return callRpc(
    "general_ledger",
    {
      p_entity: v.entity_id,
      p_account: v.account_id ?? null,
      p_start: v.start_date ?? null,
      p_end: v.end_date ?? null,
    },
    generalLedgerSchema,
  );
}

// ================================================================ year-end closing
export async function closeFiscalYear(
  input: z.input<typeof closeFiscalYearInputSchema>,
): Promise<string> {
  const v = closeFiscalYearInputSchema.parse(input);
  return callRpc(
    "close_fiscal_year",
    { p_entity: v.entity_id, p_fiscal_year: v.fiscal_year, p_key: v.idempotency_key },
    uuidResultSchema,
  );
}

export async function reverseFiscalYearClosing(
  input: z.input<typeof reverseFiscalYearClosingInputSchema>,
): Promise<string> {
  const v = reverseFiscalYearClosingInputSchema.parse(input);
  return callRpc(
    "reverse_fiscal_year_closing",
    { p_entity: v.entity_id, p_fiscal_year: v.fiscal_year, p_reason: v.reason },
    uuidResultSchema,
  );
}

/** `fiscal_year_closures` is a plain, permission-gated table (`accounting.view`), not an RPC -- there is no
 * business rule left to apply once RLS has filtered it, matching the same direct-read shape the migration
 * gives `report_datasets` below. Read as any other server-side table query: RLS is still the enforcement. */
export async function listFiscalYearClosures(entityId: string): Promise<FiscalYearClosureRow[]> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("fiscal_year_closures")
    .select(
      "id, entity_id, fiscal_year, closing_journal_id, closed_at, closed_by, reversed_at, reversed_by, reversal_journal_id, reversal_reason",
    )
    .eq("entity_id", entityId)
    .order("fiscal_year", { ascending: false });
  if (error) throw new Error("Gagal memuat riwayat penutupan tahun buku.");
  const parsed = fiscalYearClosureListSchema.safeParse(data);
  if (!parsed.success) throw new Error("Respons riwayat penutupan tahun buku tidak dikenali.");
  return parsed.data;
}

// ================================================================ Custom Report Builder
export async function runCustomReport(
  input: z.input<typeof runCustomReportInputSchema>,
): Promise<CustomReportRow[]> {
  const v = runCustomReportInputSchema.parse(input);
  return callRpc(
    "run_custom_report",
    {
      p_entity: v.entity_id,
      p_dataset: v.dataset,
      p_start: v.start_date ?? null,
      p_end: v.end_date ?? null,
    },
    customReportSchema,
  );
}

/** The dataset discovery catalog a picker reads before calling `runCustomReport` (Step 12 §19). Every
 * caller with an active membership may read it (it names datasets, not data); `runCustomReport` itself is
 * still gated per-dataset by `required_permission`. */
export async function listReportDatasets(): Promise<ReportDatasetCatalogRow[]> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("report_datasets")
    .select("dataset_key, name, description, dimension_label, measure_label, required_permission")
    .order("dataset_key");
  if (error) throw new Error("Gagal memuat katalog dataset laporan.");
  const parsed = reportDatasetCatalogSchema.safeParse(data);
  if (!parsed.success) throw new Error("Respons katalog dataset laporan tidak dikenali.");
  return parsed.data;
}

// ================================================================ Consolidated Analysis
/** Cross-Entity cash position (Step 12 §15, Table 6, Table 10), gated by `reports.cross_entity` on every
 * requested Entity -- fails closed on the whole call when any one is unauthorized (never silently drops
 * it). Company and Personal books are never merged: one row per requested Entity. */
export async function getConsolidatedCashPosition(
  input: z.input<typeof consolidatedCashPositionInputSchema>,
): Promise<ConsolidatedCashPositionRow[]> {
  const v = consolidatedCashPositionInputSchema.parse(input);
  return callRpc(
    "consolidated_cash_position",
    { p_entities: v.entity_ids, p_as_of: v.as_of ?? null },
    consolidatedCashPositionSchema,
  );
}
