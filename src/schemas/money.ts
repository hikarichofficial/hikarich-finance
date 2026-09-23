import { z } from "zod";
import {
  exchangeRateTextSchema,
  idempotencyKeySchema,
  isoDateSchema,
  moneyTextSchema,
  signedDecimalTextSchema,
} from "@/schemas/accounting";

/**
 * Input and output contracts of the money RPCs (P4): financial accounts, transfers, balance adjustments and
 * bank reconciliation. Money is always exact decimal text (Step 13 §25).
 */

export const financialAccountKindSchema = z.enum(["cash", "bank", "ewallet"]);
export type FinancialAccountKind = z.infer<typeof financialAccountKindSchema>;

export const createFinancialAccountInputSchema = z.object({
  entity_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  kind: financialAccountKindSchema,
  name: z.string().trim().min(1).max(120),
  currency: z.string().regex(/^[A-Z]{3}$/),
  ledger_account_id: z.uuid().optional(),
  institution_name: z.string().trim().max(120).optional(),
  account_number: z.string().trim().max(60).optional(),
  account_holder: z.string().trim().max(120).optional(),
});

export const updateFinancialAccountInputSchema = z.object({
  account_id: z.uuid(),
  expected_version: z.number().int().positive().optional(),
  patch: z
    .object({
      name: z.string().trim().min(1).max(120).optional(),
      institution_name: z.string().trim().max(120).optional(),
      account_number: z.string().trim().max(60).optional(),
      account_holder: z.string().trim().max(120).optional(),
    })
    .refine((p) => Object.keys(p).length > 0, "Tidak ada perubahan"),
});

export const setFinancialAccountActiveInputSchema = z.object({
  account_id: z.uuid(),
  active: z.boolean(),
  reason: z.string().trim().min(5).max(500),
});

export const balanceAdjustmentInputSchema = z.object({
  entity_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  account_id: z.uuid(),
  direction: z.enum(["in", "out"]),
  amount: moneyTextSchema,
  exchange_rate: exchangeRateTextSchema.optional(),
  movement_date: isoDateSchema,
  counter_account_id: z.uuid(),
  reason: z.string().trim().min(10).max(500),
});

export const createTransferInputSchema = z.object({
  entity_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  from_account_id: z.uuid(),
  to_account_id: z.uuid(),
  transfer_date: isoDateSchema,
  amount_out: moneyTextSchema,
  amount_in: moneyTextSchema.optional(),
  fee: moneyTextSchema.optional(),
  rate_out: exchangeRateTextSchema.optional(),
  rate_in: exchangeRateTextSchema.optional(),
  description: z.string().trim().max(500).optional(),
  reference: z.string().trim().max(120).optional(),
  /** Confirming needs money.transfer_approve; a draft only needs money.transfer_create. */
  confirm: z.boolean().optional(),
});

export const confirmTransferInputSchema = z.object({
  transfer_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
});

export const cancelTransferInputSchema = z.object({
  transfer_id: z.uuid(),
  reason: z.string().trim().max(500).optional(),
});

export const reverseTransferInputSchema = z.object({
  transfer_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  reversal_date: isoDateSchema,
  reason: z.string().trim().min(5).max(500),
});

/** Direct-table-read projection of `public.transfers` (P13 Part 3c) for the Transfers List/Detail screens --
 * covered by the pre-existing `transfers_select` RLS policy (`money.view`, P4), same reasoning as decisions
 * 161/167's extension of this pattern: a pure read with no business rule left to apply once RLS has filtered
 * it, so a wrapping RPC would add a round trip without adding a rule. No RPC reads a transfer today (only
 * `create_transfer`/`confirm_transfer`/`cancel_transfer`/`reverse_transfer` write one). */
export const transferRowSchema = z.object({
  id: z.uuid(),
  entity_id: z.uuid(),
  transfer_number: z.string().nullable(),
  status: z.enum(["draft", "confirmed", "reversed", "cancelled"]),
  transfer_date: isoDateSchema,
  from_account_id: z.uuid(),
  to_account_id: z.uuid(),
  amount_out: moneyTextSchema,
  amount_in: moneyTextSchema,
  fee_amount: moneyTextSchema,
  rate_out: exchangeRateTextSchema.nullable(),
  rate_in: exchangeRateTextSchema.nullable(),
  base_out: moneyTextSchema,
  base_in: moneyTextSchema,
  base_fee: moneyTextSchema,
  fx_difference: signedDecimalTextSchema,
  description: z.string().nullable(),
  reference: z.string().nullable(),
  journal_id: z.uuid().nullable(),
  reversal_journal_id: z.uuid().nullable(),
  confirmed_at: z.string().nullable(),
  cancelled_at: z.string().nullable(),
  reversed_at: z.string().nullable(),
  reverse_reason: z.string().nullable(),
  created_at: z.string(),
});
export type TransferRow = z.infer<typeof transferRowSchema>;

/** Direct-table-read projection of `public.money_movements` (P13 Part 3c) for the Cash/Bank Activity screen
 * (Step 09 §13's Entity-wide feed, distinct from `account_activity`'s single-account ledger, which already
 * has its own running balance and needs no direct read). Covered by the pre-existing `money_movements_select`
 * RLS policy (`money.view`, P4), same reasoning as decisions 161/167/170's extensions of this pattern. */
export const moneyMovementRowSchema = z.object({
  id: z.uuid(),
  financial_account_id: z.uuid(),
  currency: z.string(),
  direction: z.enum(["in", "out"]),
  amount: moneyTextSchema,
  base_amount: moneyTextSchema,
  movement_date: isoDateSchema,
  source_type: z.string(),
  source_id: z.uuid(),
  component: z.enum(["principal", "fee", "opening", "adjustment"]),
  journal_id: z.uuid(),
  reverses_movement_id: z.uuid().nullable(),
  description: z.string().nullable(),
});
export type MoneyMovementRow = z.infer<typeof moneyMovementRowSchema>;

export const journalNumberRowSchema = z.object({
  id: z.uuid(),
  journal_number: z.string().nullable(),
});

// ---- reconciliation
export const createReconciliationInputSchema = z
  .object({
    entity_id: z.uuid(),
    idempotency_key: idempotencyKeySchema,
    account_id: z.uuid(),
    period_start: isoDateSchema,
    period_end: isoDateSchema,
    statement_opening: signedDecimalTextSchema,
    statement_closing: signedDecimalTextSchema,
    note: z.string().trim().max(500).optional(),
  })
  .refine((v) => v.period_end >= v.period_start, {
    path: ["period_end"],
    message: "Periode berakhir sebelum dimulai",
  });

export const statementLineInputSchema = z.object({
  date: isoDateSchema,
  amount: signedDecimalTextSchema,
  description: z.string().trim().max(500).optional(),
  reference: z.string().trim().max(200).optional(),
  balance_after: signedDecimalTextSchema.optional(),
});

export const addStatementLinesInputSchema = z.object({
  session_id: z.uuid(),
  lines: z.array(statementLineInputSchema).min(1).max(1000),
});

export const matchStatementLineInputSchema = z.object({
  line_id: z.uuid(),
  movement_ids: z.array(z.uuid()).min(1).max(50),
  manual_reason: z.string().trim().min(5).max(500).optional(),
});

export const reasonInputSchema = z.object({
  line_id: z.uuid(),
  reason: z.string().trim().min(5).max(500),
});

export const completeReconciliationInputSchema = z.object({
  session_id: z.uuid(),
  accept_reason: z.string().trim().min(10).max(500).optional(),
});

export const reopenReconciliationInputSchema = z.object({
  session_id: z.uuid(),
  reason: z.string().trim().min(10).max(500),
});

// ---- RPC results
export const moneyControlRowSchema = z.object({
  financial_account_id: z.uuid(),
  name: z.string(),
  kind: z.string(),
  currency: z.string(),
  is_active: z.boolean(),
  movement_balance: signedDecimalTextSchema,
  movement_base_balance: signedDecimalTextSchema,
  ledger_balance: signedDecimalTextSchema,
  difference: signedDecimalTextSchema,
  is_negative: z.boolean(),
});
export const moneyControlSchema = z.array(moneyControlRowSchema);
export type MoneyControlRow = z.infer<typeof moneyControlRowSchema>;

export const addStatementLinesResultSchema = z.object({
  added: z.number().int().nonnegative(),
  skipped: z.number().int().nonnegative(),
});

export const workspaceLineSchema = z.object({
  line_id: z.uuid(),
  line_date: isoDateSchema,
  description: z.string().nullable(),
  reference: z.string().nullable(),
  amount: signedDecimalTextSchema,
  display_status: z.enum(["matched", "possible_match", "unmatched", "excluded"]),
  matched_movements: z.number().int().nonnegative(),
  candidate_count: z.number().int().nonnegative(),
  exclusion_reason: z.string().nullable(),
});
export const workspaceSchema = z.array(workspaceLineSchema);
export type WorkspaceLine = z.infer<typeof workspaceLineSchema>;

export const reconciliationStatusRowSchema = z.object({
  financial_account_id: z.uuid(),
  name: z.string(),
  last_reconciled_until: isoDateSchema.nullable(),
  last_statement_closing: signedDecimalTextSchema.nullable(),
  session_in_progress: z.boolean(),
  unresolved_lines: z.number().int().nonnegative(),
  outstanding_movements: z.number().int().nonnegative(),
  last_difference: signedDecimalTextSchema.nullable(),
});
export const reconciliationStatusSchema = z.array(reconciliationStatusRowSchema);
export type ReconciliationStatusRow = z.infer<typeof reconciliationStatusRowSchema>;

export const accountActivityRowSchema = z.object({
  movement_id: z.uuid(),
  movement_date: isoDateSchema,
  direction: z.enum(["in", "out"]),
  amount: signedDecimalTextSchema,
  currency: z.string(),
  base_amount: signedDecimalTextSchema,
  running_balance: signedDecimalTextSchema,
  source_type: z.string(),
  source_id: z.uuid().nullable(),
  component: z.string(),
  description: z.string().nullable(),
  journal_id: z.uuid(),
  journal_number: z.string().nullable(),
  reverses_movement_id: z.uuid().nullable(),
});
export const accountActivitySchema = z.array(accountActivityRowSchema);
export type AccountActivityRow = z.infer<typeof accountActivityRowSchema>;

export const unreconciledMovementSchema = z.object({
  movement_id: z.uuid(),
  movement_date: isoDateSchema,
  direction: z.enum(["in", "out"]),
  signed_amount: signedDecimalTextSchema,
  source_type: z.string(),
  component: z.string(),
  description: z.string().nullable(),
});
export const unreconciledMovementsSchema = z.array(unreconciledMovementSchema);

export const candidateSchema = z.object({
  movement_id: z.uuid(),
  movement_date: isoDateSchema,
  direction: z.enum(["in", "out"]),
  signed_amount: signedDecimalTextSchema,
  source_type: z.string(),
  description: z.string().nullable(),
  day_difference: z.number().int().nonnegative(),
});
export const candidatesSchema = z.array(candidateSchema);
