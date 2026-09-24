import {
  ASSET_CONDITION_LABELS,
  ASSET_STATUS_LABELS,
  type AssetCondition,
  type AssetStatus,
} from "@/domain/assets/assets";
import type { AssetDetail, AssetRow } from "@/schemas/assets";

/**
 * Pure helpers for Asset Register (List) and Asset Detail (P13 Part 3f, Step 09 §9-§10, §16). Nothing here
 * calls the database: `listAssets`/`getAsset` (`src/services/assets/assets.ts`) already carry everything these
 * functions need. Depreciation arithmetic itself stays in `@/domain/assets/assets` (Step 15 §12, Step 16 §16);
 * this module only adds the List/Detail-specific badges, filters and event labels on top of it.
 */

export type AssetListTone = "neutral" | "progress" | "attention" | "success" | "critical";

export interface AssetListBadge {
  text: string;
  tone: AssetListTone;
}

export const ASSET_STATUS_TONE: Readonly<Record<AssetStatus, AssetListTone>> = {
  draft: "neutral",
  active: "success",
  sold: "neutral",
  disposed: "neutral",
  cancelled: "critical",
};

export function assetStatusBadge(status: AssetStatus): AssetListBadge {
  return { text: ASSET_STATUS_LABELS[status], tone: ASSET_STATUS_TONE[status] };
}

export const ASSET_CONDITION_TONE: Readonly<Record<AssetCondition, AssetListTone>> = {
  in_use: "success",
  in_storage: "neutral",
  under_repair: "attention",
  damaged: "critical",
  lost: "critical",
};

export function assetConditionBadge(condition: AssetCondition): AssetListBadge {
  return { text: ASSET_CONDITION_LABELS[condition], tone: ASSET_CONDITION_TONE[condition] };
}

/** How an asset entered the register (Step 16 §16's "acquisition source"): registered from an approved
 * purchase/expense line (Step 08 §5's `asset_link_status`), or carried forward at the cut-over. */
export const ASSET_SOURCE_LABELS: Readonly<Record<AssetRow["source_type"], string>> = {
  bill_line: "Baris Tagihan Pembelian",
  expense_line: "Baris Beban",
  opening: "Saldo Awal",
};

export interface AssetStatusFilterOption {
  value: AssetStatus | null;
  label: string;
}

export const ASSET_STATUS_FILTER_OPTIONS: readonly AssetStatusFilterOption[] = [
  { value: null, label: "Semua Status" },
  ...(Object.entries(ASSET_STATUS_LABELS) as [AssetStatus, string][]).map(([value, label]) => ({
    value,
    label,
  })),
];

export function parseAssetStatusFilter(value: string | undefined): AssetStatus | undefined {
  const option = ASSET_STATUS_FILTER_OPTIONS.find((o) => o.value === value);
  return option?.value ?? undefined;
}

function normalize(text: string): string {
  return text.trim().toLowerCase();
}

/** `status` itself is filtered server-side (`asset_register`'s own `p_status` argument); only the free-text
 * search has no RPC parameter to send it to. */
export function matchesAssetQuery(row: AssetRow, query: string): boolean {
  const needle = normalize(query);
  if (needle === "") return true;
  return normalize(row.asset_code).includes(needle) || normalize(row.name).includes(needle);
}

export function filterAssetRows(rows: readonly AssetRow[], query: string): AssetRow[] {
  return rows.filter((row) => matchesAssetQuery(row, query));
}

// ---- Asset Detail's own lifecycle timeline (Step 16 §16's "lifecycle")

export type AssetEventType = AssetDetail["events"][number]["type"];

/** The exact vocabulary `public.asset_events.event_type` checks (`20260926100000_p8_asset_register.sql`);
 * unrecognised text still renders (as itself, neutral) rather than throwing. */
export const ASSET_EVENT_LABELS: Readonly<Record<string, string>> = {
  registered: "Didaftarkan",
  split: "Dipecah",
  activated: "Diaktifkan",
  replanned: "Rencana Penyusutan Diubah",
  condition_changed: "Kondisi Diubah",
  transferred: "Dipindahkan",
  details_changed: "Detail Diubah",
  cancelled: "Dibatalkan",
  depreciation_posted: "Penyusutan Diposting",
  depreciation_reversed: "Penyusutan Dibalik",
  disposed: "Dilepas",
  disposal_reversed: "Pelepasan Dibalik",
  opening_loaded: "Dimuat dari Saldo Awal",
  fiscal_class_set: "Golongan Fiskal Ditetapkan",
};

export interface AssetEventDisplay {
  text: string;
  tone: AssetListTone;
}

const EVENT_TONE: Readonly<Record<string, AssetListTone>> = {
  registered: "neutral",
  split: "neutral",
  activated: "success",
  replanned: "attention",
  condition_changed: "attention",
  transferred: "neutral",
  details_changed: "neutral",
  cancelled: "critical",
  depreciation_posted: "progress",
  depreciation_reversed: "attention",
  disposed: "neutral",
  disposal_reversed: "attention",
  opening_loaded: "neutral",
  fiscal_class_set: "neutral",
};

export function assetEventDisplay(type: string): AssetEventDisplay {
  return { text: ASSET_EVENT_LABELS[type] ?? type, tone: EVENT_TONE[type] ?? "neutral" };
}

export const DEPRECIATION_LINE_STATUS_LABELS: Readonly<
  Record<AssetDetail["schedule"][number]["status"], string>
> = {
  scheduled: "Terjadwal",
  posted: "Terposting",
  reversed: "Dibalik",
  cancelled: "Dibatalkan",
};

export const DEPRECIATION_LINE_STATUS_TONE: Readonly<
  Record<AssetDetail["schedule"][number]["status"], AssetListTone>
> = {
  scheduled: "neutral",
  posted: "success",
  reversed: "attention",
  cancelled: "critical",
};

export function depreciationLineStatusBadge(
  status: AssetDetail["schedule"][number]["status"],
): AssetListBadge {
  return {
    text: DEPRECIATION_LINE_STATUS_LABELS[status],
    tone: DEPRECIATION_LINE_STATUS_TONE[status],
  };
}
