import { z } from "zod";
import { isoDateSchema } from "@/schemas/accounting";

/**
 * Output contract of `public.cash_statement` (decision 326): the "Rekening Koran" monthly view of the cash and
 * bank accounts, built from the posted journal. Amounts are exact decimal text in the Entity's base currency.
 */
const amountText = z.string();

export const cashStatementRowSchema = z.object({
  rn: z.number().int(),
  entry_date: isoDateSchema,
  journal_id: z.uuid(),
  journal_number: z.string().nullable(),
  description: z.string().nullable(),
  account_name: z.string(),
  masuk: amountText,
  keluar: amountText,
  saldo: amountText,
});

export const cashStatementMonthSchema = z.object({
  month: isoDateSchema,
  masuk: amountText,
  keluar: amountText,
  saldo_akhir: amountText,
});

export const cashStatementSchema = z.object({
  month_start: isoDateSchema,
  month_end: isoDateSchema,
  opening: amountText,
  total_in: amountText,
  total_out: amountText,
  closing: amountText,
  total_rows: z.number().int(),
  rows: z.array(cashStatementRowSchema),
  months: z.array(cashStatementMonthSchema),
});
export type CashStatement = z.infer<typeof cashStatementSchema>;
export type CashStatementRow = z.infer<typeof cashStatementRowSchema>;

export const cashAccountOptionSchema = z.object({ id: z.uuid(), name: z.string() });
export type CashAccountOption = z.infer<typeof cashAccountOptionSchema>;
