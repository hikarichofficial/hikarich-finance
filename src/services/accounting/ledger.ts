import "server-only";
import { z, type ZodType } from "zod";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { AuthzError, parseAuthzCode } from "@/domain/authz/errors";
import {
  createJournalInputSchema,
  openingBalanceInputSchema,
  periodChecksSchema,
  periodStatusSchema,
  postJournalInputSchema,
  reopenPeriodInputSchema,
  reverseJournalInputSchema,
  signedDecimalTextSchema,
  trialBalanceSchema,
  uuidResultSchema,
  type CreateJournalInput,
  type PeriodCheck,
  type PeriodStatus,
  type TrialBalanceRow,
} from "@/schemas/accounting";

/**
 * Thin, typed wrappers over the accounting RPCs (P3). Every call runs as the signed-in person, so the
 * database decides who may do what per Entity; this layer validates input shape, maps the database's error
 * prefixes to AuthzError (never leaking database detail) and validates what comes back. It contains no
 * accounting rules of its own: balance, periods, protected accounts, idempotency and immutability are
 * enforced by the database inside the posting transaction (Step 04, Step 13 §9).
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
    throw new Error("Operasi akuntansi gagal diproses.");
  }
  const parsed = schema.safeParse(data);
  if (!parsed.success) throw new Error("Respons akuntansi tidak dikenali.");
  return parsed.data;
}

function lineToRpc(line: CreateJournalInput["lines"][number]) {
  return {
    account_id: line.account_id,
    account_key: line.account_key,
    debit: line.debit ?? "0",
    credit: line.credit ?? "0",
    description: line.description,
    original_currency: line.original_currency,
    original_amount: line.original_amount,
    exchange_rate: line.exchange_rate,
  };
}

/** Creates a manual/adjusting DRAFT journal. Same key + same request replays the same draft. */
export async function createJournalDraft(input: CreateJournalInput): Promise<string> {
  const v = createJournalInputSchema.parse(input);
  return callRpc(
    "create_journal_draft",
    {
      p_entity: v.entity_id,
      p_key: v.idempotency_key,
      p_entry_type: v.entry_type,
      p_date: v.entry_date,
      p_description: v.description,
      p_lines: v.lines.map(lineToRpc),
      p_override_reason: v.override_reason ?? null,
    },
    uuidResultSchema,
  );
}

export async function discardJournalDraft(journalId: string): Promise<void> {
  const id = uuidResultSchema.parse(journalId);
  // A void function answers with an empty body; only success/failure matters.
  await callRpc("discard_journal_draft", { p_journal: id }, z.unknown());
}

export async function postJournal(input: z.input<typeof postJournalInputSchema>): Promise<string> {
  const v = postJournalInputSchema.parse(input);
  return callRpc(
    "post_journal",
    {
      p_journal: v.journal_id,
      p_key: v.idempotency_key,
      p_expected_version: v.expected_version ?? null,
    },
    uuidResultSchema,
  );
}

export async function reverseJournal(
  input: z.input<typeof reverseJournalInputSchema>,
): Promise<string> {
  const v = reverseJournalInputSchema.parse(input);
  return callRpc(
    "reverse_journal",
    {
      p_journal: v.journal_id,
      p_key: v.idempotency_key,
      p_date: v.reversal_date,
      p_reason: v.reason,
    },
    uuidResultSchema,
  );
}

export async function getTrialBalance(entityId: string, asOf?: string): Promise<TrialBalanceRow[]> {
  return callRpc(
    "trial_balance",
    { p_entity: uuidResultSchema.parse(entityId), p_as_of: asOf ?? null },
    trialBalanceSchema,
  );
}

// ---- periods
export async function getPeriodChecks(periodId: string): Promise<PeriodCheck[]> {
  return callRpc(
    "period_close_checks",
    { p_period: uuidResultSchema.parse(periodId) },
    periodChecksSchema,
  );
}

export async function beginPeriodClose(periodId: string): Promise<PeriodStatus> {
  return callRpc(
    "begin_period_close",
    { p_period: uuidResultSchema.parse(periodId) },
    periodStatusSchema,
  );
}

export async function cancelPeriodClose(periodId: string): Promise<PeriodStatus> {
  return callRpc(
    "cancel_period_close",
    { p_period: uuidResultSchema.parse(periodId) },
    periodStatusSchema,
  );
}

export async function closePeriod(periodId: string): Promise<PeriodStatus> {
  return callRpc(
    "close_period",
    { p_period: uuidResultSchema.parse(periodId) },
    periodStatusSchema,
  );
}

/** OWNER-level; the database also demands a recent step-up (STEP_UP_REQUIRED) and a written reason. */
export async function reopenPeriod(
  input: z.input<typeof reopenPeriodInputSchema>,
): Promise<PeriodStatus> {
  const v = reopenPeriodInputSchema.parse(input);
  return callRpc(
    "reopen_period",
    { p_period: v.period_id, p_reason: v.reason },
    periodStatusSchema,
  );
}

// ---- opening balances
export async function postOpeningBalances(
  input: z.input<typeof openingBalanceInputSchema>,
): Promise<string> {
  const v = openingBalanceInputSchema.parse(input);
  return callRpc(
    "post_opening_balances",
    {
      p_entity: v.entity_id,
      p_key: v.idempotency_key,
      p_cutover: v.cutover_date,
      p_lines: v.lines.map(lineToRpc),
      p_note: v.note ?? null,
    },
    uuidResultSchema,
  );
}

/** Returns the clearing residual as exact decimal text ("0.0000" when fully reconciled). */
export async function completeOpeningBalances(entityId: string, note?: string): Promise<string> {
  return callRpc(
    "complete_opening_balances",
    { p_entity: uuidResultSchema.parse(entityId), p_note: note ?? null },
    signedDecimalTextSchema,
  );
}
