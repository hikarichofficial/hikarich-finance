import { z } from "zod";
import { Decimal } from "@/domain/money/decimal";
import { journalTotals } from "@/domain/accounting/journal";

/**
 * Input and output contracts of the accounting RPCs (P3). Money is ALWAYS exact decimal text, never a
 * JavaScript number (Step 13 §25): inputs are validated as text, outputs arrive as text.
 */

export const moneyTextSchema = z
  .string()
  .regex(/^\d{1,16}(\.\d{1,4})?$/, "Jumlah harus berupa angka desimal (maks. 4 desimal)");

export const exchangeRateTextSchema = z
  .string()
  .regex(/^\d{1,10}(\.\d{1,10})?$/, "Kurs harus berupa angka desimal (maks. 10 desimal)");

export const isoDateSchema = z
  .string()
  .regex(/^\d{4}-\d{2}-\d{2}$/, "Tanggal harus berformat YYYY-MM-DD")
  .refine((value) => {
    const parsed = new Date(`${value}T00:00:00Z`);
    return !Number.isNaN(parsed.getTime()) && parsed.toISOString().startsWith(value);
  }, "Tanggal tidak valid");

/** One request = one key. 8-200 characters, matching the database (Step 13 §9). */
export const idempotencyKeySchema = z.string().min(8).max(200);

export const journalLineInputSchema = z
  .object({
    account_id: z.uuid().optional(),
    account_key: z
      .string()
      .regex(/^[A-Z][A-Z0-9_]*$/)
      .optional(),
    debit: moneyTextSchema.optional(),
    credit: moneyTextSchema.optional(),
    description: z.string().trim().max(500).optional(),
    original_currency: z
      .string()
      .regex(/^[A-Z]{3}$/)
      .optional(),
    original_amount: moneyTextSchema.optional(),
    exchange_rate: exchangeRateTextSchema.optional(),
  })
  .superRefine((line, ctx) => {
    if ((line.account_id === undefined) === (line.account_key === undefined)) {
      ctx.addIssue({ code: "custom", message: "Isi salah satu: account_id atau account_key" });
    }
    // Malformed amounts are reported by the field schemas; here we only judge well-formed ones.
    const debit = line.debit === undefined ? Decimal.zero() : Decimal.tryParse(line.debit);
    const credit = line.credit === undefined ? Decimal.zero() : Decimal.tryParse(line.credit);
    if (debit && credit && debit.isPositive() === credit.isPositive()) {
      ctx.addIssue({
        code: "custom",
        message: "Isi tepat satu sisi (debit atau kredit) lebih dari nol",
      });
    }
    const foreign = [line.original_currency, line.original_amount, line.exchange_rate].filter(
      (f) => f !== undefined,
    ).length;
    if (foreign !== 0 && foreign !== 3) {
      ctx.addIssue({
        code: "custom",
        message: "Mata uang asal, jumlah asal, dan kurs harus diisi bersamaan",
      });
    }
  });

export type JournalLineInput = z.infer<typeof journalLineInputSchema>;

/** true/false when every amount is well-formed, null otherwise (field errors are reported elsewhere). */
function linesBalanced(lines: readonly JournalLineInput[]): boolean | null {
  const wellFormed = lines
    .flatMap((l) => [l.debit, l.credit])
    .every((v) => v === undefined || Decimal.tryParse(v) !== null);
  return wellFormed ? journalTotals(lines).balanced : null;
}

export const createJournalInputSchema = z
  .object({
    entity_id: z.uuid(),
    idempotency_key: idempotencyKeySchema,
    entry_type: z.enum(["manual", "adjusting"]),
    entry_date: isoDateSchema,
    description: z.string().trim().min(1).max(500),
    lines: z.array(journalLineInputSchema).min(2).max(200),
    override_reason: z.string().trim().min(1).max(500).optional(),
  })
  .superRefine((input, ctx) => {
    if (input.entry_type === "adjusting" && input.description.length < 10) {
      ctx.addIssue({
        code: "custom",
        path: ["description"],
        message: "Jurnal penyesuaian memerlukan penjelasan minimal 10 karakter",
      });
    }
    if (linesBalanced(input.lines) === false) {
      ctx.addIssue({
        code: "custom",
        path: ["lines"],
        message: "Total debit dan kredit belum seimbang",
      });
    }
  });

export type CreateJournalInput = z.infer<typeof createJournalInputSchema>;

export const postJournalInputSchema = z.object({
  journal_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  expected_version: z.number().int().positive().optional(),
});

export const reverseJournalInputSchema = z.object({
  journal_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  reversal_date: isoDateSchema,
  reason: z.string().trim().min(5).max(500),
});

export const openingBalanceInputSchema = z.object({
  entity_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  cutover_date: isoDateSchema,
  note: z.string().trim().max(500).optional(),
  lines: z.array(journalLineInputSchema).min(1).max(500),
});

export const periodStatusSchema = z.enum(["open", "closing_review", "closed", "reopened"]);
export type PeriodStatus = z.infer<typeof periodStatusSchema>;

export const reopenPeriodInputSchema = z.object({
  period_id: z.uuid(),
  reason: z.string().trim().min(10).max(500),
});

// ---- RPC results
export const trialBalanceRowSchema = z.object({
  account_id: z.uuid(),
  code: z.string(),
  name: z.string(),
  account_class: z.string(),
  debit: moneyTextSchema,
  credit: moneyTextSchema,
});
export const trialBalanceSchema = z.array(trialBalanceRowSchema);
export type TrialBalanceRow = z.infer<typeof trialBalanceRowSchema>;

export const periodCheckSchema = z.object({
  code: z.string(),
  severity: z.enum(["blocker", "warning"]),
  message: z.string(),
  item_count: z.number().int().nonnegative(),
});
export const periodChecksSchema = z.array(periodCheckSchema);
export type PeriodCheck = z.infer<typeof periodCheckSchema>;

export const uuidResultSchema = z.uuid();
/** Signed exact decimal text (a clearing residual may be negative). */
export const signedDecimalTextSchema = z.string().regex(/^-?\d+(\.\d+)?$/);
