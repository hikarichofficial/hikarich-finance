import "server-only";
import { z, type ZodType } from "zod";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { AuthzError, parseAuthzCode } from "@/domain/authz/errors";
import { isoDateSchema, uuidResultSchema } from "@/schemas/accounting";
import {
  activateAssetInputSchema,
  assetControlSchema,
  assetDetailSchema,
  assetFilterSchema,
  assetIdInputSchema,
  assetRegisterSchema,
  cancelAssetInputSchema,
  depreciationDueSchema,
  depreciationReportInputSchema,
  depreciationReportSchema,
  disposeAssetInputSchema,
  fiscalScheduleSchema,
  loadOpeningAssetsInputSchema,
  pendingAssetLinesSchema,
  postDepreciationInputSchema,
  postDepreciationResultSchema,
  registerPendingAssetInputSchema,
  replanAssetInputSchema,
  reverseDepreciationInputSchema,
  reverseDisposalInputSchema,
  setAssetConditionInputSchema,
  setFiscalClassInputSchema,
  splitAssetInputSchema,
  transferAssetInputSchema,
  updateAssetDetailsInputSchema,
  type AssetControlRow,
  type AssetDetail,
  type AssetRow,
  type DepreciationDueRow,
  type DepreciationLineRow,
  type FiscalScheduleRow,
  type PendingAssetLineRow,
  type PostDepreciationResult,
} from "@/schemas/assets";

/**
 * Thin, typed wrappers over the fixed-asset RPCs (P8). Every call runs as the signed-in person; the database
 * decides who may do what per Entity (`assets.view`, `assets.manage`) and applies every rule
 * (registration from purchase lines, depreciation plans, month-end posting, disposal accounting, immutability,
 * idempotency) inside the transaction. This layer validates the input shape, maps the database's error prefixes to
 * AuthzError without leaking detail, and validates what comes back. It holds no accounting rule of its own
 * (Step 15 §12, Step 16 §16, Step 13 §9). Labels and the plan preview live in `@/domain/assets`.
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
    throw new Error("Operasi aset gagal diproses.");
  }
  const parsed = schema.safeParse(data);
  if (!parsed.success) throw new Error("Respons aset tidak dikenali.");
  return parsed.data;
}

const uuid = (value: string) => uuidResultSchema.parse(value);
const dateArg = (value?: string) => (value ? isoDateSchema.parse(value) : null);
const nothing = z.null();
const uuidList = z.array(z.uuid());
const count = z.number().int().nonnegative();

// ---- registering and looking after assets
/** Registers a draft asset from an approved purchase line that is still waiting (`asset_link_status = pending`). */
export async function registerPendingAsset(
  input: z.input<typeof registerPendingAssetInputSchema>,
): Promise<string> {
  const v = registerPendingAssetInputSchema.parse(input);
  return callRpc("asset_register_pending", { p_kind: v.kind, p_line: v.line_id }, uuidResultSchema);
}

export async function updateAssetDetails(
  input: z.input<typeof updateAssetDetailsInputSchema>,
): Promise<void> {
  const v = updateAssetDetailsInputSchema.parse(input);
  await callRpc(
    "asset_update_details",
    {
      p_asset: v.asset_id,
      p_name: v.name,
      p_description: v.description ?? null,
      p_serial: v.serial_number ?? null,
    },
    nothing,
  );
}

export async function transferAsset(
  input: z.input<typeof transferAssetInputSchema>,
): Promise<void> {
  const v = transferAssetInputSchema.parse(input);
  await callRpc(
    "asset_transfer",
    {
      p_asset: v.asset_id,
      p_location: v.location ?? null,
      p_custodian: v.custodian ?? null,
      p_date: v.date,
      p_note: v.note ?? null,
    },
    nothing,
  );
}

export async function setAssetCondition(
  input: z.input<typeof setAssetConditionInputSchema>,
): Promise<void> {
  const v = setAssetConditionInputSchema.parse(input);
  await callRpc(
    "asset_set_condition",
    { p_asset: v.asset_id, p_condition: v.condition, p_date: v.date, p_note: v.note ?? null },
    nothing,
  );
}

/** Splits a draft asset that came from one purchase line into several; returns the ids, the original first. */
export async function splitAsset(input: z.input<typeof splitAssetInputSchema>): Promise<string[]> {
  const v = splitAssetInputSchema.parse(input);
  return callRpc(
    "asset_split",
    { p_asset: v.asset_id, p_key: v.idempotency_key, p_parts: v.parts },
    uuidList,
  );
}

/** Puts the asset in service and writes its depreciation plan. Returns the number of months planned. */
export async function activateAsset(
  input: z.input<typeof activateAssetInputSchema>,
): Promise<number> {
  const v = activateAssetInputSchema.parse(input);
  return callRpc(
    "asset_activate",
    {
      p_asset: v.asset_id,
      p_key: v.idempotency_key,
      p_in_service: v.in_service_date,
      p_method: v.method,
      p_life_months: v.life_months ?? null,
      p_residual: v.residual ?? "0",
      p_fiscal_class: v.fiscal_class ?? null,
      p_fiscal_method: v.fiscal_method ?? null,
    },
    count,
  );
}

/** Re-plans the months still to come (a change of method, life or residual); posted months stay as they are. */
export async function replanAsset(input: z.input<typeof replanAssetInputSchema>): Promise<number> {
  const v = replanAssetInputSchema.parse(input);
  return callRpc(
    "asset_replan",
    {
      p_asset: v.asset_id,
      p_key: v.idempotency_key,
      p_method: v.method,
      p_remaining_months: v.remaining_months,
      p_residual: v.residual,
      p_reason: v.reason,
    },
    count,
  );
}

export async function cancelAsset(input: z.input<typeof cancelAssetInputSchema>): Promise<number> {
  const v = cancelAssetInputSchema.parse(input);
  return callRpc(
    "asset_cancel",
    { p_asset: v.asset_id, p_key: v.idempotency_key, p_reason: v.reason },
    count,
  );
}

export async function setAssetFiscalClass(
  input: z.input<typeof setFiscalClassInputSchema>,
): Promise<void> {
  const v = setFiscalClassInputSchema.parse(input);
  await callRpc(
    "asset_set_fiscal_class",
    { p_asset: v.asset_id, p_class: v.fiscal_class, p_method: v.method },
    nothing,
  );
}

// ---- depreciation and disposal
/** Posts the depreciation of every complete month up to the month-end `through`; safe to repeat. */
export async function postDepreciation(
  input: z.input<typeof postDepreciationInputSchema>,
): Promise<PostDepreciationResult> {
  const v = postDepreciationInputSchema.parse(input);
  return callRpc(
    "asset_post_depreciation",
    { p_entity: v.entity_id, p_through: v.through },
    postDepreciationResultSchema,
  );
}

export async function reverseDepreciation(
  input: z.input<typeof reverseDepreciationInputSchema>,
): Promise<string> {
  const v = reverseDepreciationInputSchema.parse(input);
  return callRpc(
    "asset_reverse_depreciation",
    {
      p_line: v.line_id,
      p_key: v.idempotency_key,
      p_date: v.date ?? null,
      p_reason: v.reason,
    },
    uuidResultSchema,
  );
}

/** Sells, scraps or otherwise removes an asset from the register (needs `assets.manage`). Returns the disposal id. */
export async function disposeAsset(
  input: z.input<typeof disposeAssetInputSchema>,
): Promise<string> {
  const v = disposeAssetInputSchema.parse(input);
  return callRpc(
    "asset_dispose",
    {
      p_asset: v.asset_id,
      p_key: v.idempotency_key,
      p_type: v.type,
      p_date: v.date,
      p_proceeds: v.proceeds,
      p_method: v.proceeds_method,
      p_account: v.account_id ?? null,
      p_counterparty: v.counterparty ?? null,
      p_due: v.due_date ?? null,
      p_reason: v.reason,
    },
    uuidResultSchema,
  );
}

export async function reverseDisposal(
  input: z.input<typeof reverseDisposalInputSchema>,
): Promise<string> {
  const v = reverseDisposalInputSchema.parse(input);
  return callRpc(
    "asset_reverse_disposal",
    {
      p_disposal: v.disposal_id,
      p_key: v.idempotency_key,
      p_date: v.date ?? null,
      p_reason: v.reason,
    },
    uuidResultSchema,
  );
}

/** Loads assets at the cut-over (Step 15 §24). Returns the new asset ids in order. */
export async function loadOpeningAssets(
  input: z.input<typeof loadOpeningAssetsInputSchema>,
): Promise<string[]> {
  const v = loadOpeningAssetsInputSchema.parse(input);
  return callRpc(
    "asset_load_opening",
    { p_entity: v.entity_id, p_key: v.idempotency_key, p_assets: v.assets },
    uuidList,
  );
}

// ---- reading
export async function listAssets(input: z.input<typeof assetFilterSchema>): Promise<AssetRow[]> {
  const v = assetFilterSchema.parse(input);
  return callRpc(
    "asset_register",
    {
      p_entity: v.entity_id,
      p_status: v.status ?? null,
      p_as_of: dateArg(v.as_of),
      p_limit: v.limit ?? 200,
    },
    assetRegisterSchema,
  );
}

export async function getAsset(input: z.input<typeof assetIdInputSchema>): Promise<AssetDetail> {
  const v = assetIdInputSchema.parse(input);
  return callRpc("asset_detail", { p_asset: v.asset_id }, assetDetailSchema);
}

export async function depreciationReport(
  input: z.input<typeof depreciationReportInputSchema>,
): Promise<DepreciationLineRow[]> {
  const v = depreciationReportInputSchema.parse(input);
  return callRpc(
    "asset_depreciation_report",
    {
      p_entity: v.entity_id,
      p_from: dateArg(v.from),
      p_to: dateArg(v.to),
      p_limit: v.limit ?? 500,
    },
    depreciationReportSchema,
  );
}

/** Months that are over and not posted yet (default: up to the end of the last complete month). */
export async function depreciationDue(
  entityId: string,
  through?: string,
): Promise<DepreciationDueRow[]> {
  return callRpc(
    "asset_depreciation_due",
    { p_entity: uuid(entityId), p_through: dateArg(through) },
    depreciationDueSchema,
  );
}

/** Approved purchase lines booked as fixed assets that no asset has been registered for. */
export async function listPendingAssetLines(entityId: string): Promise<PendingAssetLineRow[]> {
  return callRpc("asset_pending_lines", { p_entity: uuid(entityId) }, pendingAssetLinesSchema);
}

export async function fiscalSchedule(assetId: string): Promise<FiscalScheduleRow[]> {
  return callRpc("asset_fiscal_schedule", { p_asset: uuid(assetId) }, fiscalScheduleSchema);
}

/** The register against the General Ledger (cost and accumulated depreciation), as of a date. */
export async function assetControl(entityId: string, asOf?: string): Promise<AssetControlRow[]> {
  return callRpc(
    "asset_control_report",
    { p_entity: uuid(entityId), p_as_of: dateArg(asOf) },
    assetControlSchema,
  );
}
