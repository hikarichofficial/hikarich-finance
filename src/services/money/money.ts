import "server-only";
import { z, type ZodType } from "zod";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { AuthzError, parseAuthzCode } from "@/domain/authz/errors";
import {
  uuidResultSchema,
  signedDecimalTextSchema,
  isoDateSchema,
} from "@/schemas/accounting";
import {
  accountActivitySchema,
  addStatementLinesInputSchema,
  addStatementLinesResultSchema,
  balanceAdjustmentInputSchema,
  cancelTransferInputSchema,
  candidatesSchema,
  completeReconciliationInputSchema,
  confirmTransferInputSchema,
  createFinancialAccountInputSchema,
  createReconciliationInputSchema,
  createTransferInputSchema,
  matchStatementLineInputSchema,
  moneyControlSchema,
  reasonInputSchema,
  reconciliationStatusSchema,
  reopenReconciliationInputSchema,
  reverseTransferInputSchema,
  journalNumberRowSchema,
  moneyMovementRowSchema,
  setFinancialAccountActiveInputSchema,
  transferRowSchema,
  unreconciledMovementsSchema,
  updateFinancialAccountInputSchema,
  workspaceSchema,
  type AccountActivityRow,
  type MoneyControlRow,
  type MoneyMovementRow,
  type ReconciliationStatusRow,
  type TransferRow,
  type WorkspaceLine,
} from "@/schemas/money";

/**
 * Thin, typed wrappers over the money RPCs (P4). Every call runs as the signed-in person; the database decides
 * who may do what per Entity and enforces every rule (currency, negative balances, approval, periods,
 * idempotency, immutability, matching, reconciliation) inside the transaction. This layer validates the input
 * shape, maps the database's error prefixes to AuthzError without leaking detail, and validates what comes
 * back. It holds no money rules of its own (Step 04, Step 07, Step 08, Step 13 §9).
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
    throw new Error("Operasi keuangan gagal diproses.");
  }
  const parsed = schema.safeParse(data);
  if (!parsed.success) throw new Error("Respons keuangan tidak dikenali.");
  return parsed.data;
}

// ---- financial accounts
export async function createFinancialAccount(
  input: z.input<typeof createFinancialAccountInputSchema>,
): Promise<string> {
  const v = createFinancialAccountInputSchema.parse(input);
  return callRpc(
    "create_financial_account",
    {
      p_entity: v.entity_id,
      p_key: v.idempotency_key,
      p_kind: v.kind,
      p_name: v.name,
      p_currency: v.currency,
      p_ledger_account: v.ledger_account_id ?? null,
      p_institution: v.institution_name ?? null,
      p_account_number: v.account_number ?? null,
      p_holder: v.account_holder ?? null,
    },
    uuidResultSchema,
  );
}

/** Returns the new version number. Only descriptive fields can change (never currency or ledger mapping). */
export async function updateFinancialAccount(
  input: z.input<typeof updateFinancialAccountInputSchema>,
): Promise<number> {
  const v = updateFinancialAccountInputSchema.parse(input);
  return callRpc(
    "update_financial_account",
    {
      p_account: v.account_id,
      p_patch: v.patch,
      p_expected_version: v.expected_version ?? null,
    },
    z.number().int(),
  );
}

export async function setFinancialAccountActive(
  input: z.input<typeof setFinancialAccountActiveInputSchema>,
): Promise<boolean> {
  const v = setFinancialAccountActiveInputSchema.parse(input);
  return callRpc(
    "set_financial_account_active",
    { p_account: v.account_id, p_active: v.active, p_reason: v.reason },
    z.boolean(),
  );
}

export async function getMoneyControl(
  entityId: string,
  asOf?: string,
): Promise<MoneyControlRow[]> {
  return callRpc(
    "money_control",
    {
      p_entity: uuidResultSchema.parse(entityId),
      p_as_of: asOf ? isoDateSchema.parse(asOf) : null,
    },
    moneyControlSchema,
  );
}

export async function getAccountActivity(
  accountId: string,
  range: { from?: string; to?: string; limit?: number } = {},
): Promise<AccountActivityRow[]> {
  return callRpc(
    "account_activity",
    {
      p_account: uuidResultSchema.parse(accountId),
      p_from: range.from ? isoDateSchema.parse(range.from) : null,
      p_to: range.to ? isoDateSchema.parse(range.to) : null,
      p_limit: range.limit ?? 200,
    },
    accountActivitySchema,
  );
}

/** A correction with an explicit counter account and a written reason; never silent (Step 08 §20). */
export async function recordBalanceAdjustment(
  input: z.input<typeof balanceAdjustmentInputSchema>,
): Promise<string> {
  const v = balanceAdjustmentInputSchema.parse(input);
  return callRpc(
    "record_balance_adjustment",
    {
      p_entity: v.entity_id,
      p_key: v.idempotency_key,
      p_account: v.account_id,
      p_direction: v.direction,
      p_amount: v.amount,
      p_rate: v.exchange_rate ?? null,
      p_date: v.movement_date,
      p_counter_account: v.counter_account_id,
      p_reason: v.reason,
    },
    uuidResultSchema,
  );
}

// ---- transfers
export async function createTransfer(
  input: z.input<typeof createTransferInputSchema>,
): Promise<string> {
  const v = createTransferInputSchema.parse(input);
  return callRpc(
    "create_transfer",
    {
      p_entity: v.entity_id,
      p_key: v.idempotency_key,
      p_from: v.from_account_id,
      p_to: v.to_account_id,
      p_date: v.transfer_date,
      p_amount_out: v.amount_out,
      p_amount_in: v.amount_in ?? null,
      p_fee: v.fee ?? "0",
      p_rate_out: v.rate_out ?? null,
      p_rate_in: v.rate_in ?? null,
      p_description: v.description ?? null,
      p_reference: v.reference ?? null,
      p_confirm: v.confirm ?? false,
    },
    uuidResultSchema,
  );
}

export async function confirmTransfer(
  input: z.input<typeof confirmTransferInputSchema>,
): Promise<string> {
  const v = confirmTransferInputSchema.parse(input);
  return callRpc(
    "confirm_transfer",
    { p_transfer: v.transfer_id, p_key: v.idempotency_key },
    uuidResultSchema,
  );
}

export async function cancelTransfer(
  input: z.input<typeof cancelTransferInputSchema>,
): Promise<string> {
  const v = cancelTransferInputSchema.parse(input);
  return callRpc(
    "cancel_transfer",
    { p_transfer: v.transfer_id, p_reason: v.reason ?? null },
    z.string(),
  );
}

/** Returns the reversal journal id. A matched (cleared) transfer must be unmatched first. */
export async function reverseTransfer(
  input: z.input<typeof reverseTransferInputSchema>,
): Promise<string> {
  const v = reverseTransferInputSchema.parse(input);
  return callRpc(
    "reverse_transfer",
    {
      p_transfer: v.transfer_id,
      p_key: v.idempotency_key,
      p_date: v.reversal_date,
      p_reason: v.reason,
    },
    uuidResultSchema,
  );
}

/** Every transfer of the Entity, newest first -- a direct read of `public.transfers` (see `transferRowSchema`'s
 * doc comment: covered by the pre-existing `transfers_select` RLS policy, no RPC reads a transfer today). */
export async function listTransfers(entityId: string): Promise<TransferRow[]> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("transfers")
    .select(
      "id, entity_id, transfer_number, status, transfer_date, from_account_id, to_account_id, amount_out, amount_in, fee_amount, rate_out, rate_in, base_out, base_in, base_fee, fx_difference, description, reference, journal_id, reversal_journal_id, confirmed_at, cancelled_at, reversed_at, reverse_reason, created_at",
    )
    .eq("entity_id", uuidResultSchema.parse(entityId))
    .order("transfer_date", { ascending: false });
  if (error) throw new Error("Gagal memuat transfer.");
  const parsed = z.array(transferRowSchema).safeParse(data);
  if (!parsed.success) throw new Error("Respons transfer tidak dikenali.");
  return parsed.data;
}

/** `null` for a missing or inaccessible transfer -- the same answer either way (no existence leak), matching
 * every P6/P4 command's own "not found or not allowed" convention. */
export async function getTransfer(
  transferId: string,
): Promise<TransferRow | null> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("transfers")
    .select(
      "id, entity_id, transfer_number, status, transfer_date, from_account_id, to_account_id, amount_out, amount_in, fee_amount, rate_out, rate_in, base_out, base_in, base_fee, fx_difference, description, reference, journal_id, reversal_journal_id, confirmed_at, cancelled_at, reversed_at, reverse_reason, created_at",
    )
    .eq("id", uuidResultSchema.parse(transferId))
    .maybeSingle();
  if (error) throw new Error("Gagal memuat transfer.");
  if (!data) return null;
  const parsed = transferRowSchema.safeParse(data);
  if (!parsed.success) throw new Error("Respons transfer tidak dikenali.");
  return parsed.data;
}

/** Every money movement of the Entity within a date range, newest first -- a direct read of
 * `public.money_movements` (see `moneyMovementRowSchema`'s doc comment). This is the Cash/Bank Activity
 * screen's Entity-wide feed (Step 09 §13), distinct from `getAccountActivity`'s single-account ledger. */
export async function listCashActivity(
  entityId: string,
  range: { from: string; to: string },
  limit = 300,
): Promise<MoneyMovementRow[]> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("money_movements")
    .select(
      "id, financial_account_id, currency, direction, amount, base_amount, movement_date, source_type, source_id, component, journal_id, reverses_movement_id, description",
    )
    .eq("entity_id", uuidResultSchema.parse(entityId))
    .gte("movement_date", isoDateSchema.parse(range.from))
    .lte("movement_date", isoDateSchema.parse(range.to))
    .order("movement_date", { ascending: false })
    .limit(limit);
  if (error) throw new Error("Gagal memuat aktivitas kas/bank.");
  const parsed = z.array(moneyMovementRowSchema).safeParse(data);
  if (!parsed.success)
    throw new Error("Respons aktivitas kas/bank tidak dikenali.");
  return parsed.data;
}

/**
 * Journal numbers for the given journal ids, as a `Map<id, journal_number | null>`. Reading `journal_entries`
 * needs `accounting.view` -- a DIFFERENT permission from `money.view` (confirmed in
 * `20260920100100_p2_permission_catalog.sql`: `finance_staff` and `approver` hold `money.view` without
 * `accounting.view`), the same shape of gap decision 168 already found and filed for `contacts.view`/
 * `bills.view`. This is written defensively for the same reason `getVendorNames` is: it never throws, an
 * empty result (RLS-filtered, not an error) just means the caller falls back to a generic label.
 */
export async function getJournalNumbers(
  journalIds: readonly string[],
): Promise<Map<string, string | null>> {
  if (journalIds.length === 0) return new Map();
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("journal_entries")
    .select("id, journal_number")
    .in(
      "id",
      journalIds.map((id) => uuidResultSchema.parse(id)),
    );
  if (error) return new Map();
  const parsed = z.array(journalNumberRowSchema).safeParse(data);
  if (!parsed.success) return new Map();
  return new Map(parsed.data.map((row) => [row.id, row.journal_number]));
}

// ---- reconciliation
export async function createReconciliationSession(
  input: z.input<typeof createReconciliationInputSchema>,
): Promise<string> {
  const v = createReconciliationInputSchema.parse(input);
  return callRpc(
    "create_reconciliation_session",
    {
      p_entity: v.entity_id,
      p_key: v.idempotency_key,
      p_account: v.account_id,
      p_start: v.period_start,
      p_end: v.period_end,
      p_opening: v.statement_opening,
      p_closing: v.statement_closing,
      p_note: v.note ?? null,
    },
    uuidResultSchema,
  );
}

export async function discardReconciliationSession(
  sessionId: string,
): Promise<void> {
  await callRpc(
    "discard_reconciliation_session",
    { p_session: uuidResultSchema.parse(sessionId) },
    z.unknown(),
  );
}

/** Uploading the same statement twice adds nothing the second time (skipped lines are counted). */
export async function addStatementLines(
  input: z.input<typeof addStatementLinesInputSchema>,
): Promise<{ added: number; skipped: number }> {
  const v = addStatementLinesInputSchema.parse(input);
  return callRpc(
    "add_statement_lines",
    { p_session: v.session_id, p_lines: v.lines },
    addStatementLinesResultSchema,
  );
}

/** The movements must add up to the statement line exactly; a difference is never absorbed by a match. */
export async function matchStatementLine(
  input: z.input<typeof matchStatementLineInputSchema>,
): Promise<number> {
  const v = matchStatementLineInputSchema.parse(input);
  return callRpc(
    "match_statement_line",
    {
      p_line: v.line_id,
      p_movements: v.movement_ids,
      p_manual_reason: v.manual_reason ?? null,
    },
    z.number().int(),
  );
}

export async function unmatchStatementLine(
  input: z.input<typeof reasonInputSchema>,
): Promise<number> {
  const v = reasonInputSchema.parse(input);
  return callRpc(
    "unmatch_statement_line",
    { p_line: v.line_id, p_reason: v.reason },
    z.number().int(),
  );
}

export async function excludeStatementLine(
  input: z.input<typeof reasonInputSchema>,
): Promise<boolean> {
  const v = reasonInputSchema.parse(input);
  return callRpc(
    "exclude_statement_line",
    { p_line: v.line_id, p_reason: v.reason },
    z.boolean(),
  );
}

export async function includeStatementLine(lineId: string): Promise<boolean> {
  return callRpc(
    "include_statement_line",
    { p_line: uuidResultSchema.parse(lineId) },
    z.boolean(),
  );
}

/** Returns the difference as exact decimal text; a non-zero difference needs `accept_reason`. */
export async function completeReconciliation(
  input: z.input<typeof completeReconciliationInputSchema>,
): Promise<string> {
  const v = completeReconciliationInputSchema.parse(input);
  return callRpc(
    "complete_reconciliation",
    { p_session: v.session_id, p_accept_reason: v.accept_reason ?? null },
    signedDecimalTextSchema,
  );
}

export async function reopenReconciliation(
  input: z.input<typeof reopenReconciliationInputSchema>,
): Promise<string> {
  const v = reopenReconciliationInputSchema.parse(input);
  return callRpc(
    "reopen_reconciliation",
    { p_session: v.session_id, p_reason: v.reason },
    z.string(),
  );
}

export async function getReconciliationWorkspace(
  sessionId: string,
): Promise<WorkspaceLine[]> {
  return callRpc(
    "reconciliation_workspace",
    { p_session: uuidResultSchema.parse(sessionId) },
    workspaceSchema,
  );
}

export async function getReconciliationCandidates(lineId: string) {
  return callRpc(
    "reconciliation_candidates",
    { p_line: uuidResultSchema.parse(lineId) },
    candidatesSchema,
  );
}

export async function getUnreconciledMovements(
  accountId: string,
  until?: string,
) {
  return callRpc(
    "unreconciled_movements",
    {
      p_account: uuidResultSchema.parse(accountId),
      p_until: until ? isoDateSchema.parse(until) : null,
    },
    unreconciledMovementsSchema,
  );
}

export async function getReconciliationStatus(
  entityId: string,
): Promise<ReconciliationStatusRow[]> {
  return callRpc(
    "reconciliation_status",
    { p_entity: uuidResultSchema.parse(entityId) },
    reconciliationStatusSchema,
  );
}
