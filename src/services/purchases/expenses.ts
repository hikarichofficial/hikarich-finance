import "server-only";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import {
  expenseLineListSchema,
  expenseListSchema,
  expenseRowSchema,
  type ExpenseLineRow,
  type ExpenseRow,
} from "@/schemas/expenses";

/** Direct Expense reads (decision 245); writes stay in `@/services/purchases/purchases` (P6 RPCs). */

const EXPENSE_COLUMNS =
  "id, status, expense_number, payee_id, payee_name, receipt_reference, financial_account_id, currency, expense_date, notes, subtotal::text, tax_total::text, total::text, journal_id, reversal_journal_id, reject_reason, closed_reason, replaces_expense_id, replaced_by_expense_id, created_at, version";

const EXPENSE_LINE_COLUMNS =
  "id, line_no, description, quantity::text, unit_price::text, line_subtotal::text, tax_amount::text, line_total::text, treatment, category_id";

export async function listExpenses(entityId: string): Promise<ExpenseRow[]> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("expenses")
    .select(EXPENSE_COLUMNS)
    .eq("entity_id", entityId)
    .order("expense_date", { ascending: false })
    .order("created_at", { ascending: false });
  if (error) throw new Error("Gagal memuat pengeluaran.");
  const parsed = expenseListSchema.safeParse(data);
  if (!parsed.success) throw new Error("Respons pengeluaran tidak dikenali.");
  return parsed.data;
}

export async function getExpense(entityId: string, expenseId: string): Promise<ExpenseRow | null> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("expenses")
    .select(EXPENSE_COLUMNS)
    .eq("entity_id", entityId)
    .eq("id", expenseId)
    .maybeSingle();
  if (error) throw new Error("Gagal memuat pengeluaran.");
  if (!data) return null;
  const parsed = expenseRowSchema.safeParse(data);
  if (!parsed.success) throw new Error("Respons pengeluaran tidak dikenali.");
  return parsed.data;
}

export async function getExpenseLines(expenseId: string): Promise<ExpenseLineRow[]> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("expense_lines")
    .select(EXPENSE_LINE_COLUMNS)
    .eq("expense_id", expenseId)
    .order("line_no", { ascending: true });
  if (error) throw new Error("Gagal memuat baris pengeluaran.");
  const parsed = expenseLineListSchema.safeParse(data);
  if (!parsed.success) throw new Error("Respons baris pengeluaran tidak dikenali.");
  return parsed.data;
}
