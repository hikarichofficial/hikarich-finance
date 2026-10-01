import { z } from "zod";

/**
 * Direct Expense rows (decision 245), read straight from `public.expenses`/`public.expense_lines` under
 * their own `bills.view` RLS policies -- no RPC lists or reads an expense, the same direct-table-read
 * precedent decisions 161/167/170-173/239/242 established. Every write still goes through the P6 RPCs.
 */
export const expenseStatusSchema = z.enum([
  "draft",
  "submitted",
  "confirmed",
  "reversed",
  "cancelled",
]);
export type ExpenseStatus = z.infer<typeof expenseStatusSchema>;

const amount = z.union([z.string(), z.number()]).transform((v) => String(v));

export const expenseRowSchema = z.object({
  id: z.uuid(),
  status: expenseStatusSchema,
  expense_number: z.string().nullable(),
  payee_id: z.uuid().nullable(),
  payee_name: z.string().nullable(),
  receipt_reference: z.string().nullable(),
  financial_account_id: z.uuid(),
  currency: z.string(),
  expense_date: z.string(),
  notes: z.string().nullable(),
  subtotal: amount,
  tax_total: amount,
  total: amount,
  journal_id: z.uuid().nullable(),
  reversal_journal_id: z.uuid().nullable(),
  reject_reason: z.string().nullable(),
  closed_reason: z.string().nullable(),
  replaces_expense_id: z.uuid().nullable(),
  replaced_by_expense_id: z.uuid().nullable(),
  created_at: z.string(),
  version: z.number().int(),
});
export const expenseListSchema = z.array(expenseRowSchema);
export type ExpenseRow = z.infer<typeof expenseRowSchema>;

export const expenseLineRowSchema = z.object({
  id: z.uuid(),
  line_no: z.number().int(),
  description: z.string(),
  quantity: amount,
  unit_price: amount,
  line_subtotal: amount,
  tax_amount: amount,
  line_total: amount,
  treatment: z.enum(["expense", "asset", "prepaid"]),
  category_id: z.uuid().nullable(),
});
export const expenseLineListSchema = z.array(expenseLineRowSchema);
export type ExpenseLineRow = z.infer<typeof expenseLineRowSchema>;
