import "server-only";
import { z, type ZodType } from "zod";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { AuthzError, parseAuthzCode } from "@/domain/authz/errors";
import { entityCurrencyRowSchema } from "@/schemas/dashboard";
import {
  accountingPeriodRowsSchema,
  createJournalInputSchema,
  journalEntryRowSchema,
  journalEntryRowsSchema,
  journalLineRowsSchema,
  ledgerAccountRowsSchema,
  openingBalanceInputSchema,
  periodChecksSchema,
  periodStatusSchema,
  postJournalInputSchema,
  reopenPeriodInputSchema,
  reverseJournalInputSchema,
  reversingJournalRowSchema,
  signedDecimalTextSchema,
  trialBalanceSchema,
  uuidResultSchema,
  type AccountingPeriodRow,
  type CreateJournalInput,
  type JournalEntryRow,
  type JournalLineRow,
  type LedgerAccountRow,
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

// ---- direct reads (P13 Part 3d): no RPC lists or reads a journal, a ledger account or a period -- only the
// write commands above exist. Each read below is a plain `.from(table).select(...)` covered by that table's
// own pre-existing `accounting.view`-gated RLS policy, extending the direct-table-read pattern (decisions
// 161/167/170/171) to `public.journal_entries`/`journal_lines`/`ledger_accounts`/`accounting_periods`.

const JOURNAL_ENTRY_COLUMNS =
  "id, entity_id, journal_number, entry_date, period_id, status, entry_type, description, source_type, source_id, posting_key, reverses_journal_id, control_override_reason, posted_at, created_at, version";

export async function listJournals(entityId: string): Promise<JournalEntryRow[]> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("journal_entries")
    .select(JOURNAL_ENTRY_COLUMNS)
    .eq("entity_id", uuidResultSchema.parse(entityId))
    .order("entry_date", { ascending: false })
    .order("created_at", { ascending: false });
  if (error) throw new Error("Gagal memuat daftar jurnal.");
  const parsed = journalEntryRowsSchema.safeParse(data);
  if (!parsed.success) throw new Error("Respons jurnal tidak dikenali.");
  return parsed.data;
}

/** `null` for a missing or inaccessible journal -- the same answer either way (no existence leak), matching
 * every other direct-read `get*` in this codebase. */
export async function getJournalEntry(journalId: string): Promise<JournalEntryRow | null> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("journal_entries")
    .select(JOURNAL_ENTRY_COLUMNS)
    .eq("id", uuidResultSchema.parse(journalId))
    .maybeSingle();
  if (error) throw new Error("Gagal memuat jurnal.");
  if (!data) return null;
  const parsed = journalEntryRowSchema.safeParse(data);
  if (!parsed.success) throw new Error("Respons jurnal tidak dikenali.");
  return parsed.data;
}

export async function getJournalLines(journalId: string): Promise<JournalLineRow[]> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("journal_lines")
    .select(
      "id, journal_id, line_no, ledger_account_id, debit, credit, description, original_currency, original_amount, exchange_rate",
    )
    .eq("journal_id", uuidResultSchema.parse(journalId))
    .order("line_no", { ascending: true });
  if (error) throw new Error("Gagal memuat baris jurnal.");
  const parsed = journalLineRowsSchema.safeParse(data);
  if (!parsed.success) throw new Error("Respons baris jurnal tidak dikenali.");
  return parsed.data;
}

/** The journal (if any) whose own `reverses_journal_id` points back at this one -- "was this journal
 * reversed, and by which one" is the reverse direction of the column, so it needs its own small lookup
 * rather than a field already on the row (see the schema's own doc comment). */
export async function getReversingJournal(
  journalId: string,
): Promise<{ id: string; journal_number: string | null } | null> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("journal_entries")
    .select("id, journal_number")
    .eq("reverses_journal_id", uuidResultSchema.parse(journalId))
    .maybeSingle();
  if (error) throw new Error("Gagal memuat status pembalikan jurnal.");
  if (!data) return null;
  const parsed = reversingJournalRowSchema.safeParse(data);
  if (!parsed.success) throw new Error("Respons jurnal tidak dikenali.");
  return parsed.data;
}

export async function listLedgerAccounts(entityId: string): Promise<LedgerAccountRow[]> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("ledger_accounts")
    .select(
      "id, entity_id, code, name, account_class, normal_balance, system_key, parent_id, is_group, is_control, allows_manual_posting, status",
    )
    .eq("entity_id", uuidResultSchema.parse(entityId))
    .order("code", { ascending: true });
  if (error) throw new Error("Gagal memuat bagan akun.");
  const parsed = ledgerAccountRowsSchema.safeParse(data);
  if (!parsed.success) throw new Error("Respons bagan akun tidak dikenali.");
  return parsed.data;
}

/** `journal_lines.debit`/`credit` are always base-currency amounts (Step 04 §14; the table's own column
 * comment), so the Journal Detail lines table needs the Entity's base currency to format them -- the same
 * direct read decision 161 established for the Dashboard, repeated here per that decision's own precedent of
 * each service module reading it independently rather than sharing a cross-module accessor. */
export async function getEntityBaseCurrency(entityId: string): Promise<string> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("entities")
    .select("base_currency")
    .eq("id", uuidResultSchema.parse(entityId))
    .single();
  if (error) throw new Error("Gagal memuat mata uang dasar Entity.");
  const parsed = entityCurrencyRowSchema.safeParse(data);
  if (!parsed.success) throw new Error("Respons mata uang dasar Entity tidak dikenali.");
  return parsed.data.base_currency;
}

export async function listAccountingPeriods(entityId: string): Promise<AccountingPeriodRow[]> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("accounting_periods")
    .select(
      "id, entity_id, fiscal_year, period_start, period_end, status, closed_at, reopened_at, reopen_reason",
    )
    .eq("entity_id", uuidResultSchema.parse(entityId))
    .order("period_start", { ascending: false });
  if (error) throw new Error("Gagal memuat periode akuntansi.");
  const parsed = accountingPeriodRowsSchema.safeParse(data);
  if (!parsed.success) throw new Error("Respons periode akuntansi tidak dikenali.");
  return parsed.data;
}
