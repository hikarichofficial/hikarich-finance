import { z } from "zod";
import { moneyTextSchema, uuidResultSchema } from "@/schemas/accounting";

/**
 * `personal_tax_summary` and `tax_group_turnover` (decision 365): the amounts the Pajak Pribadi calculation needs,
 * read from the posted documents, plus the rule data (rates, brackets, PTKP). The tax itself is computed in
 * `@/domain/tax/personalTax` from these figures, so it can be tested apart from the database.
 */

export const PTKP_STATUSES = [
  "TK/0",
  "TK/1",
  "TK/2",
  "TK/3",
  "K/0",
  "K/1",
  "K/2",
  "K/3",
  "K/I/0",
  "K/I/1",
  "K/I/2",
  "K/I/3",
] as const;
export const ptkpStatusSchema = z.enum(PTKP_STATUSES);
export type PtkpStatus = z.infer<typeof ptkpStatusSchema>;

const months = z.array(moneyTextSchema).length(12);

export const personalTariffParamsSchema = z.object({
  brackets: z.array(z.object({ up_to: moneyTextSchema.nullable(), rate: z.string() })).min(1),
  ptkp: z.record(z.string(), moneyTextSchema),
  pkp_round_down_to: moneyTextSchema,
});
export type PersonalTariffParams = z.infer<typeof personalTariffParamsSchema>;

export const finalRuleParamsSchema = z.object({
  rate: z.string(),
  annual_ceiling: moneyTextSchema,
  exempt_band: z.record(z.string(), moneyTextSchema),
});
export type FinalRuleParams = z.infer<typeof finalRuleParamsSchema>;

export const personalTaxSummarySchema = z.discriminatedUnion("applicable", [
  z.object({ applicable: z.literal(false) }),
  z.object({
    applicable: z.literal(true),
    entity_id: uuidResultSchema,
    year: z.number().int(),
    currency: z.string(),
    status: z.enum(["running", "settled"]),
    ptkp_status: ptkpStatusSchema.nullable(),
    business: z.object({
      turnover: moneyTextSchema,
      months,
      withheld_not_credited: moneyTextSchema,
    }),
    freelance: z.object({
      own_gross: moneyTextSchema,
      own_withheld: moneyTextSchema,
      pt_gross: moneyTextSchema,
      pt_withheld: moneyTextSchema,
      months,
    }),
    costs: z.object({ total: moneyTextSchema, months }),
    /** Tax the person has already paid in: PPh Final UMKM and the monthly PPh 25 instalment (decision 366). */
    payments: z.object({
      final: moneyTextSchema,
      installment: moneyTextSchema,
      installment_months: months,
    }),
    linked_pt: z.array(
      z.object({
        entity_id: uuidResultSchema,
        entity_name: z.string(),
        contact_id: uuidResultSchema,
        contact_name: z.string(),
        documents: z.number().int(),
        gross: moneyTextSchema,
        withheld: moneyTextSchema,
      }),
    ),
    group: z.object({
      own_turnover: moneyTextSchema,
      others: z.array(
        z.object({
          entity_id: uuidResultSchema,
          name: z.string(),
          entity_type: z.string(),
          turnover: moneyTextSchema,
        }),
      ),
    }),
    rules: z.object({
      final: z
        .object({ code: z.string(), version: z.number().int(), params: finalRuleParamsSchema })
        .nullable(),
      tariff: z
        .object({ code: z.string(), version: z.number().int(), params: personalTariffParamsSchema })
        .nullable(),
    }),
  }),
]);
export type PersonalTaxSummary = Extract<
  z.infer<typeof personalTaxSummarySchema>,
  { applicable: true }
>;

export const taxGroupTurnoverSchema = z.object({
  year: z.number().int(),
  own_turnover: moneyTextSchema,
  ceiling: moneyTextSchema.nullable(),
  others: z.array(
    z.object({
      entity_id: uuidResultSchema,
      name: z.string(),
      entity_type: z.string(),
      turnover: moneyTextSchema,
    }),
  ),
});
export type TaxGroupTurnover = z.infer<typeof taxGroupTurnoverSchema>;

export const setPtkpInputSchema = z.object({
  entity_id: uuidResultSchema,
  year: z.number().int().min(2000).max(2999),
  status: ptkpStatusSchema,
});
