import { Decimal, type RoundingMode } from "@/domain/money/decimal";
import { addMonthsClamped, divideRounded } from "@/domain/financing/financing";

/**
 * Fixed assets (P8, Step 15 §12, Step 16 §16). The database owns the register and posts every entry; this module
 * holds the labels and the depreciation arithmetic a screen needs for early feedback, with the same rounding as
 * `app_private.asset_plan`. A plan shown on a form is a preview: the plan that binds is the one the database writes
 * when the asset is activated, and depreciation is posted month by month only after the month is over.
 */

export type AssetStatus = "draft" | "active" | "sold" | "disposed" | "cancelled";
export type AssetCondition = "in_use" | "in_storage" | "under_repair" | "damaged" | "lost";
export type DepreciationMethod = "none" | "straight_line" | "declining_balance";
export type DisposalType = "sale" | "scrapped" | "lost" | "damaged" | "donated";
export type DepreciationLineStatus = "scheduled" | "posted" | "reversed" | "cancelled";

export const ASSET_STATUS_LABELS: Readonly<Record<AssetStatus, string>> = {
  draft: "Draf (belum dipakai)",
  active: "Aktif",
  sold: "Terjual",
  disposed: "Dilepas",
  cancelled: "Dibatalkan",
};

export const ASSET_CONDITION_LABELS: Readonly<Record<AssetCondition, string>> = {
  in_use: "Dipakai",
  in_storage: "Disimpan",
  under_repair: "Diperbaiki",
  damaged: "Rusak",
  lost: "Hilang",
};

export const DEPRECIATION_METHOD_LABELS: Readonly<Record<DepreciationMethod, string>> = {
  none: "Tidak disusutkan",
  straight_line: "Garis lurus",
  declining_balance: "Saldo menurun",
};

export const DISPOSAL_TYPE_LABELS: Readonly<Record<DisposalType, string>> = {
  sale: "Dijual",
  scrapped: "Dihapus (rusak/tidak terpakai)",
  lost: "Hilang",
  damaged: "Rusak berat",
  donated: "Dihibahkan",
};

/** Personal assets are not depreciated (DECISIONS 104); only a company depreciates. */
export function methodsFor(entityType: "company" | "personal"): DepreciationMethod[] {
  return entityType === "personal" ? ["none"] : ["none", "straight_line", "declining_balance"];
}

/** Book value: cost less accumulated depreciation, never below zero. */
export function netBookValue(cost: string, accumulated: string): Decimal {
  const result = Decimal.parse(cost).sub(Decimal.parse(accumulated));
  return result.isNegative() ? Decimal.zero(result.scale) : result;
}

export interface DepreciationPlanInput {
  method: Exclude<DepreciationMethod, "none">;
  /** The value to depreciate from (cost, or book value when the plan is re-made). */
  netBookValue: string;
  residual: string;
  months: number;
  /** Life in months, the divisor of the declining-balance rate (double the straight-line rate). */
  lifeMonths: number;
  /** Any date in the first month of depreciation (depreciation starts in the month of service). */
  from: string;
  scale?: number;
}

export interface DepreciationPlanRow {
  /** The first day of the month the amount belongs to. */
  periodMonth: string;
  amount: Decimal;
}

export type DepreciationPlanProblem = "method" | "value" | "residual" | "months" | "life" | "from";

export type DepreciationPlanResult =
  | { ok: true; rows: DepreciationPlanRow[]; total: Decimal }
  | { ok: false; problem: DepreciationPlanProblem };

const HALF_UP: RoundingMode = "half_up";

/**
 * Monthly depreciation (mirrors `app_private.asset_plan`): straight-line is (value - residual) / months; declining
 * balance takes the larger of double the straight-line rate on the remaining book value and an even spread of what is
 * left, so the asset always reaches its residual by the last month. The last month absorbs the rounding.
 */
export function depreciationPlan(input: DepreciationPlanInput): DepreciationPlanResult {
  const scale = input.scale ?? 2;
  const nbv = Decimal.tryParse(input.netBookValue);
  const residual = Decimal.tryParse(input.residual);
  if (!["straight_line", "declining_balance"].includes(input.method))
    return { ok: false, problem: "method" };
  if (!nbv || nbv.isNegative() || !nbv.fitsScale(scale)) return { ok: false, problem: "value" };
  if (!residual || residual.isNegative() || !residual.fitsScale(scale) || residual.cmp(nbv) > 0) {
    return { ok: false, problem: "residual" };
  }
  if (!Number.isInteger(input.months) || input.months < 1) return { ok: false, problem: "months" };
  if (!Number.isInteger(input.lifeMonths) || input.lifeMonths < 1)
    return { ok: false, problem: "life" };
  if (!/^\d{4}-\d{2}-\d{2}$/.test(input.from)) return { ok: false, problem: "from" };

  const rows: DepreciationPlanRow[] = [];
  const depreciable = nbv.sub(residual);
  let total = Decimal.zero(scale);
  if (depreciable.isZero()) return { ok: true, rows, total };

  const firstMonth = `${input.from.slice(0, 7)}-01`;
  let left = nbv;
  for (let k = 1; k <= input.months; k += 1) {
    const room = left.sub(residual);
    let amount: Decimal;
    if (k === input.months) {
      amount = room;
    } else if (input.method === "straight_line") {
      const even = divideRounded(depreciable, Decimal.fromInteger(input.months), scale);
      amount = even.cmp(room) < 0 ? even : room;
    } else {
      const declining = divideRounded(
        left.mul(Decimal.fromInteger(2)),
        Decimal.fromInteger(input.lifeMonths),
        scale,
      );
      const spread = divideRounded(room, Decimal.fromInteger(input.months - k + 1), scale);
      const bigger = declining.cmp(spread) > 0 ? declining : spread;
      amount = bigger.cmp(room) < 0 ? bigger : room;
    }
    if (amount.isPositive()) {
      rows.push({
        periodMonth: addMonthsClamped(firstMonth, k - 1),
        amount: amount.round(scale, HALF_UP),
      });
      left = left.sub(amount);
      total = total.add(amount);
    }
  }
  return { ok: true, rows, total };
}

export function depreciationPlanProblemMessage(problem: DepreciationPlanProblem): string {
  switch (problem) {
    case "method":
      return "Metode penyusutan tidak dikenal.";
    case "value":
      return "Nilai yang disusutkan tidak valid.";
    case "residual":
      return "Nilai sisa tidak boleh melebihi nilai yang disusutkan.";
    case "months":
      return "Jumlah bulan minimal 1.";
    case "life":
      return "Umur manfaat minimal 1 bulan.";
    case "from":
      return "Tanggal mulai tidak valid.";
  }
}
