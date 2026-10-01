import { z } from "zod";

/** Opening balance batches (Step 15 §24, decision 245), read directly from `public.opening_balance_batches`
 * under its `accounting.view` RLS policy; posting/completion go through the P3 RPCs. */
export const openingBatchRowSchema = z.object({
  id: z.uuid(),
  cutover_date: z.string(),
  status: z.enum(["posted", "completed"]),
  note: z.string().nullable(),
  clearing_residual: z
    .union([z.string(), z.number()])
    .nullable()
    .transform((v) => (v === null ? null : String(v))),
  completion_note: z.string().nullable(),
  completed_at: z.string().nullable(),
  created_at: z.string(),
});
export const openingBatchListSchema = z.array(openingBatchRowSchema);
export type OpeningBatchRow = z.infer<typeof openingBatchRowSchema>;
