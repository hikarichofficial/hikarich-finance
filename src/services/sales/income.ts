import "server-only";
import { z } from "zod";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { AuthzError, parseAuthzCode } from "@/domain/authz/errors";
import { dedupeNames } from "@/domain/shared/typeahead";
import { isoDateSchema, uuidResultSchema } from "@/schemas/accounting";

/**
 * Income entered without an invoice ("Catat Pendapatan", decision 350). Reads are direct RLS-scoped selects of
 * `public.income_entries` (`invoices.view`); the three commands are RPCs that make the journal, the cash
 * movement and the reversal, so the browser never writes a ledger row.
 */

export interface IncomeCategoryOption {
  id: string;
  name: string;
  account_code: string | null;
  account_name: string | null;
  /** Counts toward the PPh Final 0,5% base (a revenue account) or not (other income). */
  in_turnover: boolean;
  /** Personal books only: which part of the personal tax the category belongs to (decision 365). */
  tax_role: string | null;
  available: boolean;
}

export interface IncomeEntryRow {
  id: string;
  status: "recorded" | "reversed";
  entry_date: string;
  category_id: string;
  currency: string;
  amount: string;
  /** Tax the client withheld; the amount reached the account less this (decision 365). */
  tax_withheld: string;
  financial_account_id: string;
  contact_id: string | null;
  income_account_id: string;
  in_turnover: boolean;
  reference: string | null;
  note: string | null;
  journal_id: string;
  reversal_journal_id: string | null;
  reversed_date: string | null;
  reverse_reason: string | null;
  created_at: string;
}

const ENTRY_COLUMNS =
  "id, status, entry_date, category_id, currency, amount::text, tax_withheld::text, financial_account_id, contact_id, income_account_id, in_turnover, reference, note, journal_id, reversal_journal_id, reversed_date, reverse_reason, created_at";

const categorySchema = z.array(
  z.object({
    id: z.string(),
    name: z.string(),
    account_code: z.string().nullable(),
    account_name: z.string().nullable(),
    in_turnover: z.boolean(),
    tax_role: z
      .string()
      .nullable()
      .optional()
      .transform((v) => v ?? null),
    available: z.boolean(),
  }),
);

const uuid = (value: string) => uuidResultSchema.parse(value);
const amountText = z.string().regex(/^\d{1,16}(\.\d{1,4})?$/);

async function rpc<T>(
  name: string,
  args: Record<string, unknown>,
  schema: z.ZodType<T>,
): Promise<T> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc(name, args);
  if (error) {
    const code = parseAuthzCode(error.message);
    if (code) throw new AuthzError(code, error.message);
    throw new Error("Pencatatan pendapatan gagal diproses.");
  }
  const parsed = schema.safeParse(data);
  if (!parsed.success) throw new Error("Respons pendapatan tidak dikenali.");
  return parsed.data;
}

/** The revenue categories to pick from, with the account each credits and whether it counts for the final tax. */
export async function listIncomeCategories(entityId: string): Promise<IncomeCategoryOption[]> {
  return rpc("list_income_categories", { p_entity: uuid(entityId) }, categorySchema);
}

export async function listIncomeEntries(
  entityId: string,
  range?: { from: string; to: string },
): Promise<IncomeEntryRow[]> {
  const supabase = await createSupabaseServerClient();
  let query = supabase.from("income_entries").select(ENTRY_COLUMNS).eq("entity_id", uuid(entityId));
  if (range) {
    query = query
      .gte("entry_date", isoDateSchema.parse(range.from))
      .lte("entry_date", isoDateSchema.parse(range.to));
  }
  const { data, error } = await query
    .order("entry_date", { ascending: false })
    .order("created_at", { ascending: false })
    .limit(1000);
  if (error) throw new Error("Gagal memuat daftar pendapatan.");
  return (data ?? []) as unknown as IncomeEntryRow[];
}

export async function getIncomeEntry(entityId: string, id: string): Promise<IncomeEntryRow | null> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("income_entries")
    .select(ENTRY_COLUMNS)
    .eq("entity_id", uuid(entityId))
    .eq("id", uuid(id))
    .maybeSingle();
  if (error) throw new Error("Gagal memuat pendapatan.");
  return (data ?? null) as unknown as IncomeEntryRow | null;
}

/** References and notes typed on earlier entries (newest first, one per text), for the popups under those fields.
 * Best effort: a failed read returns empty lists, because a missing convenience must never stop a form opening. */
export async function listIncomeTextSuggestions(
  entityId: string,
): Promise<{ references: string[]; notes: string[] }> {
  try {
    const supabase = await createSupabaseServerClient();
    const { data } = await supabase
      .from("income_entries")
      .select("reference, note")
      .eq("entity_id", uuid(entityId))
      .order("created_at", { ascending: false })
      .limit(600);
    const rows = (data ?? []) as { reference: string | null; note: string | null }[];
    return {
      references: dedupeNames(rows.map((r) => r.reference)),
      notes: dedupeNames(rows.map((r) => r.note)),
    };
  } catch {
    return { references: [], notes: [] };
  }
}

export async function recordIncomeEntry(input: {
  entity_id: string;
  idempotency_key: string;
  category_id: string;
  date: string;
  account_id: string;
  /** The gross amount (what the client owed), not only what reached the account. */
  amount: string;
  /** Tax withheld by the client, a Personal book only. */
  withheld?: string;
  contact_id?: string;
  reference?: string;
  note?: string;
}): Promise<string> {
  return rpc(
    "record_income_entry",
    {
      p_entity: uuid(input.entity_id),
      p_key: input.idempotency_key,
      p_category: uuid(input.category_id),
      p_date: isoDateSchema.parse(input.date),
      p_account: uuid(input.account_id),
      p_amount: amountText.parse(input.amount),
      p_withheld: input.withheld ? amountText.parse(input.withheld) : null,
      p_contact: input.contact_id ? uuid(input.contact_id) : null,
      p_reference: input.reference ?? null,
      p_note: input.note ?? null,
    },
    uuidResultSchema,
  );
}

export async function reverseIncomeEntry(input: {
  entry_id: string;
  idempotency_key: string;
  date: string;
  reason: string;
}): Promise<string> {
  return rpc(
    "reverse_income_entry",
    {
      p_entry: uuid(input.entry_id),
      p_key: input.idempotency_key,
      p_date: isoDateSchema.parse(input.date),
      p_reason: z.string().trim().min(5).max(500).parse(input.reason),
    },
    uuidResultSchema,
  );
}
