import { z } from "zod";
import {
  idempotencyKeySchema,
  isoDateSchema,
  moneyTextSchema,
  signedDecimalTextSchema,
} from "@/schemas/accounting";

/**
 * Input and output contracts of the fixed-asset RPCs (P8, Step 15 §12, Step 16 §16). Money is exact decimal
 * text; the database recomputes every plan and figure and posts every entry. Assets are registered from approved
 * purchase lines (`treatment: "asset"`) or loaded at the cut-over; a person activates them (in service date, method,
 * life) and depreciation is posted month by month once the month is over.
 */

const reasonSchema = z.string().trim().min(5).max(1000);
const optionalText = (max: number) => z.string().trim().max(max).optional();

export const assetStatusSchema = z.enum(["draft", "active", "sold", "disposed", "cancelled"]);
export const assetConditionSchema = z.enum([
  "in_use",
  "in_storage",
  "under_repair",
  "damaged",
  "lost",
]);
export const depreciationMethodSchema = z.enum(["none", "straight_line", "declining_balance"]);
export const fiscalMethodSchema = z.enum(["straight_line", "declining_balance"]);
export const disposalTypeSchema = z.enum(["sale", "scrapped", "lost", "damaged", "donated"]);
export const proceedsMethodSchema = z.enum(["cash", "receivable", "none"]);
export const assetSourceKindSchema = z.enum(["bill_line", "expense_line"]);

const lifeMonthsSchema = z.number().int().min(1).max(1200);

// ---- inputs
export const assetIdInputSchema = z.object({ asset_id: z.uuid() });

export const updateAssetDetailsInputSchema = z.object({
  asset_id: z.uuid(),
  name: z.string().trim().min(1).max(200),
  description: optionalText(2000),
  serial_number: optionalText(100),
});

/** At least one of location and custodian is needed; an empty one keeps what the asset has. */
export const transferAssetInputSchema = z
  .object({
    asset_id: z.uuid(),
    location: optionalText(200),
    custodian: optionalText(200),
    date: isoDateSchema,
    note: optionalText(1000),
  })
  .refine((v) => Boolean(v.location) || Boolean(v.custodian), {
    path: ["location"],
    message: "Isi lokasi atau penanggung jawab baru",
  });

export const setAssetConditionInputSchema = z.object({
  asset_id: z.uuid(),
  condition: assetConditionSchema,
  date: isoDateSchema,
  note: optionalText(1000),
});

export const splitAssetInputSchema = z.object({
  asset_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  /** 2 to 50 parts whose costs add up to the cost of the purchase line; the first part keeps the original asset. */
  parts: z
    .array(z.object({ name: z.string().trim().min(1).max(200), cost: moneyTextSchema }))
    .min(2)
    .max(50),
});

export const activateAssetInputSchema = z
  .object({
    asset_id: z.uuid(),
    idempotency_key: idempotencyKeySchema,
    in_service_date: isoDateSchema,
    method: depreciationMethodSchema,
    /** Useful life in months; needed unless the method is `none` (land and other undepreciated assets). */
    life_months: lifeMonthsSchema.nullable().optional(),
    residual: moneyTextSchema.optional(),
    /** The statutory group of Art. 11 UU PPh (a rule-master key such as `group_1`), for the fiscal schedule. */
    fiscal_class: z
      .string()
      .regex(/^[a-z][a-z0-9_]{1,40}$/)
      .optional(),
    fiscal_method: fiscalMethodSchema.optional(),
  })
  .refine((v) => v.method === "none" || (v.life_months !== null && v.life_months !== undefined), {
    path: ["life_months"],
    message: "Isi umur manfaat (bulan)",
  });

export const replanAssetInputSchema = z.object({
  asset_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  method: fiscalMethodSchema,
  remaining_months: lifeMonthsSchema,
  residual: moneyTextSchema,
  reason: reasonSchema,
});

export const cancelAssetInputSchema = z.object({
  asset_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  reason: reasonSchema,
});

export const registerPendingAssetInputSchema = z.object({
  kind: assetSourceKindSchema,
  line_id: z.uuid(),
});

/** Depreciation is posted for every complete month up to a month-end. */
export const postDepreciationInputSchema = z.object({
  entity_id: z.uuid(),
  through: isoDateSchema,
});

export const reverseDepreciationInputSchema = z.object({
  line_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  reason: reasonSchema,
  date: isoDateSchema.optional(),
});

export const disposeAssetInputSchema = z
  .object({
    asset_id: z.uuid(),
    idempotency_key: idempotencyKeySchema,
    type: disposalTypeSchema,
    date: isoDateSchema,
    /** Only a sale has proceeds; every other disposal is `0` with method `none`. */
    proceeds: moneyTextSchema.default("0"),
    proceeds_method: proceedsMethodSchema.default("none"),
    /** The cash or bank account that received the proceeds (method `cash`). */
    account_id: z.uuid().optional(),
    /** Who owes the proceeds and by when (method `receivable`). */
    counterparty: optionalText(200),
    due_date: isoDateSchema.optional(),
    reason: z.string().trim().min(3).max(1000),
  })
  .superRefine((v, ctx) => {
    if (v.type !== "sale" && v.proceeds_method !== "none") {
      ctx.addIssue({
        code: "custom",
        path: ["proceeds_method"],
        message: "Hanya penjualan yang punya hasil",
      });
    }
    if (v.proceeds_method === "cash" && !v.account_id) {
      ctx.addIssue({
        code: "custom",
        path: ["account_id"],
        message: "Pilih akun kas/bank penerima",
      });
    }
    if (v.proceeds_method === "receivable" && !v.counterparty) {
      ctx.addIssue({ code: "custom", path: ["counterparty"], message: "Isi pihak yang berutang" });
    }
  });

export const reverseDisposalInputSchema = z.object({
  disposal_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  reason: reasonSchema,
  date: isoDateSchema.optional(),
});

export const setFiscalClassInputSchema = z.object({
  asset_id: z.uuid(),
  fiscal_class: z.string().regex(/^[a-z][a-z0-9_]{1,40}$/),
  method: fiscalMethodSchema.default("straight_line"),
});

/** One asset loaded at the cut-over (Step 15 §24): the book value carried forward with its accumulated depreciation. */
export const openingAssetSchema = z.object({
  name: z.string().trim().min(1).max(200),
  description: optionalText(2000),
  serial_number: optionalText(100),
  location: optionalText(200),
  custodian: optionalText(200),
  /** The fixed-asset ledger account of the cost (an account of this Entity). */
  cost_account: z.uuid(),
  acquisition_date: isoDateSchema,
  in_service_date: isoDateSchema,
  cutover_date: isoDateSchema,
  cost: moneyTextSchema,
  accumulated: moneyTextSchema.optional(),
  method: depreciationMethodSchema.optional(),
  life_months: lifeMonthsSchema.optional(),
  residual: moneyTextSchema.optional(),
  fiscal_class: z
    .string()
    .regex(/^[a-z][a-z0-9_]{1,40}$/)
    .optional(),
  fiscal_method: fiscalMethodSchema.optional(),
});
export const loadOpeningAssetsInputSchema = z.object({
  entity_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  assets: z.array(openingAssetSchema).min(1).max(500),
});

export const assetFilterSchema = z.object({
  entity_id: z.uuid(),
  status: assetStatusSchema.optional(),
  as_of: isoDateSchema.optional(),
  limit: z.number().int().min(1).max(1000).optional(),
});

export const depreciationReportInputSchema = z.object({
  entity_id: z.uuid(),
  from: isoDateSchema.optional(),
  to: isoDateSchema.optional(),
  limit: z.number().int().min(1).max(5000).optional(),
});

// ---- outputs
export const assetRowSchema = z.object({
  asset_id: z.uuid(),
  asset_code: z.string(),
  name: z.string(),
  status: assetStatusSchema,
  condition: assetConditionSchema,
  location: z.string().nullable(),
  custodian: z.string().nullable(),
  source_type: z.enum(["bill_line", "expense_line", "opening"]),
  acquisition_date: isoDateSchema,
  in_service_date: isoDateSchema.nullable(),
  acquisition_cost: signedDecimalTextSchema,
  accumulated: signedDecimalTextSchema,
  net_book_value: signedDecimalTextSchema,
  depreciation_method: depreciationMethodSchema.nullable(),
  useful_life_months: z.number().int().nullable(),
  residual_value: signedDecimalTextSchema.nullable(),
  fiscal_class_key: z.string().nullable(),
});
export const assetRegisterSchema = z.array(assetRowSchema);
export type AssetRow = z.infer<typeof assetRowSchema>;

export const assetDetailSchema = z.object({
  asset: z.object({
    id: z.uuid(),
    code: z.string(),
    name: z.string(),
    description: z.string().nullable(),
    serial_number: z.string().nullable(),
    status: assetStatusSchema,
    condition: assetConditionSchema,
    location: z.string().nullable(),
    custodian: z.string().nullable(),
    source_type: z.enum(["bill_line", "expense_line", "opening"]),
    bill_line_id: z.uuid().nullable(),
    expense_line_id: z.uuid().nullable(),
    cost_account_id: z.uuid(),
    acquisition_date: isoDateSchema,
    in_service_date: isoDateSchema.nullable(),
    acquisition_cost: signedDecimalTextSchema,
    depreciation_method: depreciationMethodSchema.nullable(),
    useful_life_months: z.number().int().nullable(),
    residual_value: signedDecimalTextSchema.nullable(),
    opening_accumulated: signedDecimalTextSchema.nullable(),
    opening_cutover: isoDateSchema.nullable(),
    plan_version: z.number().int().nonnegative(),
    fiscal_class_key: z.string().nullable(),
    fiscal_method: fiscalMethodSchema.nullable(),
    accumulated: signedDecimalTextSchema,
    net_book_value: signedDecimalTextSchema,
    split_from_asset_id: z.uuid().nullable(),
    cancelled_date: isoDateSchema.nullable(),
    cancel_reason: z.string().nullable(),
    version: z.number().int().positive(),
  }),
  schedule: z.array(
    z.object({
      id: z.uuid(),
      month: z.string().regex(/^\d{4}-\d{2}$/),
      amount: signedDecimalTextSchema,
      status: z.enum(["scheduled", "posted", "reversed", "cancelled"]),
      plan_version: z.number().int().nonnegative(),
      journal_id: z.uuid().nullable(),
      reversal_journal_id: z.uuid().nullable(),
    }),
  ),
  events: z.array(
    z.object({
      type: z.string(),
      date: isoDateSchema,
      details: z.record(z.string(), z.unknown()),
      note: z.string().nullable(),
      at: z.string(),
    }),
  ),
  disposal: z
    .object({
      id: z.uuid(),
      type: disposalTypeSchema,
      date: isoDateSchema,
      status: z.string(),
      proceeds: signedDecimalTextSchema,
      proceeds_method: proceedsMethodSchema,
      cost_removed: signedDecimalTextSchema,
      accumulated_removed: signedDecimalTextSchema,
      net_book_value: signedDecimalTextSchema,
      gain_loss: signedDecimalTextSchema,
      journal_id: z.uuid().nullable(),
      obligation_id: z.uuid().nullable(),
    })
    .nullable(),
});
export type AssetDetail = z.infer<typeof assetDetailSchema>;

export const depreciationLineRowSchema = z.object({
  asset_id: z.uuid(),
  asset_code: z.string(),
  asset_name: z.string(),
  period_month: isoDateSchema,
  amount: signedDecimalTextSchema,
  status: z.enum(["scheduled", "posted", "reversed", "cancelled"]),
  plan_version: z.number().int().nonnegative(),
  journal_id: z.uuid().nullable(),
});
export const depreciationReportSchema = z.array(depreciationLineRowSchema);
export type DepreciationLineRow = z.infer<typeof depreciationLineRowSchema>;

export const depreciationDueRowSchema = z.object({
  asset_id: z.uuid(),
  asset_code: z.string(),
  period_month: isoDateSchema,
  amount: signedDecimalTextSchema,
  journal_date: isoDateSchema,
  /** False when the accounting period of the month-end no longer accepts postings. */
  postable: z.boolean(),
});
export const depreciationDueSchema = z.array(depreciationDueRowSchema);
export type DepreciationDueRow = z.infer<typeof depreciationDueRowSchema>;

export const pendingAssetLineRowSchema = z.object({
  source_type: assetSourceKindSchema,
  line_id: z.uuid(),
  document_id: z.uuid(),
  document_number: z.string().nullable(),
  description: z.string(),
  base_amount: signedDecimalTextSchema,
  posted_account_id: z.uuid().nullable(),
  document_date: isoDateSchema,
});
export const pendingAssetLinesSchema = z.array(pendingAssetLineRowSchema);
export type PendingAssetLineRow = z.infer<typeof pendingAssetLineRowSchema>;

export const fiscalScheduleRowSchema = z.object({
  fiscal_year: z.number().int(),
  opening_value: signedDecimalTextSchema,
  depreciation: signedDecimalTextSchema,
  closing_value: signedDecimalTextSchema,
  rule_version: z.number().int().positive(),
});
export const fiscalScheduleSchema = z.array(fiscalScheduleRowSchema);
export type FiscalScheduleRow = z.infer<typeof fiscalScheduleRowSchema>;

export const assetControlRowSchema = z.object({
  account_key: z.string(),
  sub_ledger: signedDecimalTextSchema,
  ledger_workflow: signedDecimalTextSchema,
  ledger_other: signedDecimalTextSchema,
  ledger_total: signedDecimalTextSchema,
  difference: signedDecimalTextSchema,
});
export const assetControlSchema = z.array(assetControlRowSchema);
export type AssetControlRow = z.infer<typeof assetControlRowSchema>;

export const postDepreciationResultSchema = z.object({
  posted: z.number().int().nonnegative(),
  total: signedDecimalTextSchema,
  through: isoDateSchema,
});
export type PostDepreciationResult = z.infer<typeof postDepreciationResultSchema>;
