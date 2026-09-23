import { z } from "zod";
import {
  idempotencyKeySchema,
  isoDateSchema,
  moneyTextSchema,
  signedDecimalTextSchema,
} from "@/schemas/accounting";

/**
 * Input and output contracts of the reporting RPCs (P12, Step 12 §3-§5, §15, §17, §19, §31): the canonical
 * financial statements (Profit & Loss, Balance Sheet, Statement of Changes in Equity, Cash Flow Statement,
 * General Ledger drill-down), year-end closing, the curated Custom Report Builder and cross-Entity
 * Consolidated Analysis. Every statement returns raw debit/credit (or an equivalent signed pair) as exact
 * decimal text, exactly like `trial_balance` (Step 13 §25) -- this layer never reinterprets a sign; turning
 * a debit/credit pair into the account's natural-direction figure is `@/domain/reports`'s job, applied once,
 * never duplicated per statement here or on the server. This layer validates the input shape, maps the
 * database's error prefixes to AuthzError without leaking detail, and validates what comes back. It holds
 * no business rule of its own.
 */

const accountClassSchema = z.enum([
  "asset",
  "contra_asset",
  "liability",
  "equity",
  "revenue",
  "contra_revenue",
  "expense",
  "other_income",
  "other_expense",
  "other",
  "tax",
  "special",
]);

// ================================================================ Profit & Loss
export const profitAndLossInputSchema = z
  .object({
    entity_id: z.uuid(),
    start_date: isoDateSchema,
    end_date: isoDateSchema,
    compare_start_date: isoDateSchema.optional(),
    compare_end_date: isoDateSchema.optional(),
  })
  .superRefine((v, ctx) => {
    if (v.end_date < v.start_date) {
      ctx.addIssue({
        code: "custom",
        path: ["end_date"],
        message: "Tanggal akhir harus setelah tanggal awal",
      });
    }
    if ((v.compare_start_date === undefined) !== (v.compare_end_date === undefined)) {
      ctx.addIssue({
        code: "custom",
        path: ["compare_end_date"],
        message: "Periode pembanding memerlukan tanggal awal dan akhir",
      });
    }
    if (v.compare_start_date && v.compare_end_date && v.compare_end_date < v.compare_start_date) {
      ctx.addIssue({
        code: "custom",
        path: ["compare_end_date"],
        message: "Tanggal akhir pembanding harus setelah tanggal awalnya",
      });
    }
  });

export const profitAndLossRowSchema = z.object({
  account_id: z.uuid(),
  code: z.string(),
  name: z.string(),
  account_class: accountClassSchema,
  parent_id: z.uuid().nullable(),
  debit: moneyTextSchema,
  credit: moneyTextSchema,
  compare_debit: moneyTextSchema.nullable(),
  compare_credit: moneyTextSchema.nullable(),
});
export const profitAndLossSchema = z.array(profitAndLossRowSchema);
export type ProfitAndLossRow = z.infer<typeof profitAndLossRowSchema>;

// ================================================================ Balance Sheet
export const balanceSheetInputSchema = z.object({
  entity_id: z.uuid(),
  as_of: isoDateSchema.optional(),
});

export const balanceSheetRowSchema = z.object({
  account_id: z.uuid(),
  code: z.string(),
  name: z.string(),
  account_class: accountClassSchema,
  parent_id: z.uuid().nullable(),
  debit: moneyTextSchema,
  credit: moneyTextSchema,
});
export const balanceSheetSchema = z.array(balanceSheetRowSchema);
export type BalanceSheetRow = z.infer<typeof balanceSheetRowSchema>;

// ================================================================ Statement of Changes in Equity
export const statementOfChangesInEquityInputSchema = z
  .object({
    entity_id: z.uuid(),
    start_date: isoDateSchema,
    end_date: isoDateSchema,
  })
  .refine((v) => v.end_date >= v.start_date, {
    path: ["end_date"],
    message: "Tanggal akhir harus setelah tanggal awal",
  });

export const equityChangeRowSchema = z.object({
  account_id: z.uuid().nullable(),
  code: z.string().nullable(),
  name: z.string(),
  opening_debit: moneyTextSchema,
  opening_credit: moneyTextSchema,
  period_debit: moneyTextSchema,
  period_credit: moneyTextSchema,
  closing_debit: moneyTextSchema,
  closing_credit: moneyTextSchema,
});
export const statementOfChangesInEquitySchema = z.array(equityChangeRowSchema);
export type EquityChangeRow = z.infer<typeof equityChangeRowSchema>;

// ================================================================ Cash Flow Statement
export const cashFlowStatementInputSchema = z
  .object({
    entity_id: z.uuid(),
    start_date: isoDateSchema,
    end_date: isoDateSchema,
  })
  .refine((v) => v.end_date >= v.start_date, {
    path: ["end_date"],
    message: "Tanggal akhir harus setelah tanggal awal",
  });

export const cashFlowBucketSchema = z.enum([
  "opening_cash",
  "operating",
  "investing",
  "financing",
  "closing_cash",
]);
export const cashFlowRowSchema = z.object({
  bucket: cashFlowBucketSchema,
  amount: signedDecimalTextSchema,
});
export const cashFlowStatementSchema = z.array(cashFlowRowSchema);
export type CashFlowRow = z.infer<typeof cashFlowRowSchema>;

// ================================================================ General Ledger drill-down
export const generalLedgerInputSchema = z.object({
  entity_id: z.uuid(),
  account_id: z.uuid().optional(),
  start_date: isoDateSchema.optional(),
  end_date: isoDateSchema.optional(),
});

export const generalLedgerRowSchema = z.object({
  account_id: z.uuid(),
  code: z.string(),
  name: z.string(),
  entry_date: isoDateSchema,
  journal_id: z.uuid(),
  journal_number: z.string(),
  entry_type: z.string(),
  description: z.string().nullable(),
  source_type: z.string().nullable(),
  source_id: z.uuid().nullable(),
  debit: moneyTextSchema,
  credit: moneyTextSchema,
  running_balance: signedDecimalTextSchema,
});
export const generalLedgerSchema = z.array(generalLedgerRowSchema);
export type GeneralLedgerRow = z.infer<typeof generalLedgerRowSchema>;

// ================================================================ Year-end closing
export const closeFiscalYearInputSchema = z.object({
  entity_id: z.uuid(),
  fiscal_year: z.number().int().min(2000).max(2999),
  idempotency_key: idempotencyKeySchema,
});

export const reverseFiscalYearClosingInputSchema = z.object({
  entity_id: z.uuid(),
  fiscal_year: z.number().int().min(2000).max(2999),
  reason: z.string().trim().min(10).max(500),
});

export const fiscalYearClosureRowSchema = z.object({
  id: z.uuid(),
  entity_id: z.uuid(),
  fiscal_year: z.number().int(),
  closing_journal_id: z.uuid(),
  closed_at: z.string(),
  closed_by: z.uuid().nullable(),
  reversed_at: z.string().nullable(),
  reversed_by: z.uuid().nullable(),
  reversal_journal_id: z.uuid().nullable(),
  reversal_reason: z.string().nullable(),
});
export const fiscalYearClosureListSchema = z.array(fiscalYearClosureRowSchema);
export type FiscalYearClosureRow = z.infer<typeof fiscalYearClosureRowSchema>;

// ================================================================ Custom Report Builder
export const reportDatasetKeySchema = z.enum([
  "invoices_by_customer",
  "bills_by_vendor",
  "expenses_by_payee",
]);
export type ReportDatasetKey = z.infer<typeof reportDatasetKeySchema>;

export const runCustomReportInputSchema = z
  .object({
    entity_id: z.uuid(),
    dataset: reportDatasetKeySchema,
    start_date: isoDateSchema.optional(),
    end_date: isoDateSchema.optional(),
  })
  .superRefine((v, ctx) => {
    if (v.start_date && v.end_date && v.end_date < v.start_date) {
      ctx.addIssue({
        code: "custom",
        path: ["end_date"],
        message: "Tanggal akhir harus setelah tanggal awal",
      });
    }
  });

export const customReportRowSchema = z.object({
  dimension: z.string(),
  row_count: z.number().int().nonnegative(),
  total_amount: moneyTextSchema,
});
export const customReportSchema = z.array(customReportRowSchema);
export type CustomReportRow = z.infer<typeof customReportRowSchema>;

/** The `report_datasets` discovery catalog (a plain permission-gated table, not an RPC): what a future
 * dataset picker reads to list the datasets a caller may even attempt (Step 12 §19). */
export const reportDatasetCatalogRowSchema = z.object({
  dataset_key: reportDatasetKeySchema,
  name: z.string(),
  description: z.string(),
  dimension_label: z.string(),
  measure_label: z.string(),
  required_permission: z.string(),
});
export const reportDatasetCatalogSchema = z.array(reportDatasetCatalogRowSchema);
export type ReportDatasetCatalogRow = z.infer<typeof reportDatasetCatalogRowSchema>;

// ================================================================ Consolidated Analysis
export const consolidatedCashPositionInputSchema = z.object({
  entity_ids: z.array(z.uuid()).min(1).max(50),
  as_of: isoDateSchema.optional(),
});

export const consolidatedCashPositionRowSchema = z.object({
  entity_id: z.uuid(),
  entity_code: z.string(),
  entity_name: z.string(),
  entity_type: z.string(),
  cash_balance: signedDecimalTextSchema,
});
export const consolidatedCashPositionSchema = z.array(consolidatedCashPositionRowSchema);
export type ConsolidatedCashPositionRow = z.infer<typeof consolidatedCashPositionRowSchema>;
