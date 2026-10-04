"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { AuthzError, describeAuthzError } from "@/domain/authz/errors";
import { requirePermission } from "@/services/identity/access";
import {
  loadOpeningAssets,
  activateAsset,
  cancelAsset,
  disposeAsset,
  postDepreciation,
  registerPendingAsset,
  replanAsset,
  reverseDepreciation,
  reverseDisposal,
  setAssetCondition,
  setAssetFiscalClass,
  transferAsset,
  updateAssetDetails,
} from "@/services/assets/assets";

/**
 * Server actions behind the fixed-asset write screens. Every write is an unmodified P8 RPC, all gated on
 * `assets.manage` inside the database; this layer only shapes form input and maps `AuthzError` to
 * user-safe copy, adding the database's own reason when it gives one.
 */

export interface AssetActionState {
  status: "idle" | "ok" | "error";
  message?: string;
  stepUp?: boolean;
}

function text(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function errorState(error: unknown, fallback: string): AssetActionState {
  if (error instanceof AuthzError) {
    return {
      status: "error",
      message: describeAuthzError(error),
      stepUp: error.code === "STEP_UP_REQUIRED",
    };
  }
  return { status: "error", message: fallback };
}

function revalidateAsset(assetId: string): void {
  revalidatePath("/assets");
  revalidatePath("/assets/depreciation");
  if (assetId) revalidatePath(`/assets/${assetId}`);
}

export async function registerPendingAssetAction(
  _previous: AssetActionState,
  formData: FormData,
): Promise<AssetActionState> {
  const entity = text(formData, "entity");
  let assetId: string;
  try {
    assetId = await registerPendingAsset({
      kind: text(formData, "kind") as never,
      line_id: text(formData, "line_id"),
    });
  } catch (error) {
    return errorState(error, "Aset tidak dapat didaftarkan dari baris ini.");
  }
  revalidatePath("/assets");
  revalidatePath("/assets/new");
  redirect(
    entity ? `/assets/${assetId}?entity=${encodeURIComponent(entity)}` : `/assets/${assetId}`,
  );
}

export async function activateAssetAction(
  _previous: AssetActionState,
  formData: FormData,
): Promise<AssetActionState> {
  const assetId = text(formData, "asset_id");
  const method = text(formData, "method");
  const life = text(formData, "life_months");
  const fiscalClass = text(formData, "fiscal_class");
  let months: number;
  try {
    months = await activateAsset({
      asset_id: assetId,
      idempotency_key: randomUUID(),
      in_service_date: text(formData, "in_service_date"),
      method: method as never,
      life_months: method === "none" || !life ? null : Number(life),
      residual: method === "none" ? undefined : text(formData, "residual") || undefined,
      fiscal_class: fiscalClass || undefined,
      fiscal_method: fiscalClass ? (text(formData, "fiscal_method") as never) : undefined,
    });
  } catch (error) {
    return errorState(
      error,
      "Aset tidak dapat diaktifkan. Periksa tanggal, umur manfaat dan nilai sisa.",
    );
  }
  revalidateAsset(assetId);
  return { status: "ok", message: `Aset aktif. ${months} bulan penyusutan dijadwalkan.` };
}

export async function updateAssetDetailsAction(
  _previous: AssetActionState,
  formData: FormData,
): Promise<AssetActionState> {
  const assetId = text(formData, "asset_id");
  try {
    await updateAssetDetails({
      asset_id: assetId,
      name: text(formData, "name"),
      description: text(formData, "description") || undefined,
      serial_number: text(formData, "serial_number") || undefined,
    });
  } catch (error) {
    return errorState(error, "Data aset tidak dapat disimpan. Periksa isian.");
  }
  revalidateAsset(assetId);
  return { status: "ok", message: "Data aset tersimpan." };
}

export async function setAssetConditionAction(
  _previous: AssetActionState,
  formData: FormData,
): Promise<AssetActionState> {
  const assetId = text(formData, "asset_id");
  try {
    await setAssetCondition({
      asset_id: assetId,
      condition: text(formData, "condition") as never,
      date: text(formData, "date"),
      note: text(formData, "note") || undefined,
    });
  } catch (error) {
    return errorState(error, "Kondisi aset tidak dapat disimpan. Periksa isian.");
  }
  revalidateAsset(assetId);
  return { status: "ok", message: "Kondisi aset tersimpan." };
}

export async function setAssetFiscalClassAction(
  _previous: AssetActionState,
  formData: FormData,
): Promise<AssetActionState> {
  const assetId = text(formData, "asset_id");
  try {
    await setAssetFiscalClass({
      asset_id: assetId,
      fiscal_class: text(formData, "fiscal_class"),
      method: text(formData, "fiscal_method") as never,
    });
  } catch (error) {
    return errorState(error, "Golongan fiskal tidak dapat disimpan. Periksa isian.");
  }
  revalidateAsset(assetId);
  return { status: "ok", message: "Golongan fiskal tersimpan." };
}

export async function replanAssetAction(
  _previous: AssetActionState,
  formData: FormData,
): Promise<AssetActionState> {
  const assetId = text(formData, "asset_id");
  let months: number;
  try {
    months = await replanAsset({
      asset_id: assetId,
      idempotency_key: randomUUID(),
      method: text(formData, "method") as never,
      remaining_months: Number(text(formData, "remaining_months")),
      residual: text(formData, "residual") || "0",
      reason: text(formData, "reason"),
    });
  } catch (error) {
    return errorState(
      error,
      "Rencana penyusutan tidak dapat diubah. Periksa sisa bulan, nilai sisa dan alasan.",
    );
  }
  revalidateAsset(assetId);
  return { status: "ok", message: `Rencana baru tersimpan: ${months} bulan dijadwalkan.` };
}

export async function transferAssetAction(
  _previous: AssetActionState,
  formData: FormData,
): Promise<AssetActionState> {
  const assetId = text(formData, "asset_id");
  try {
    await transferAsset({
      asset_id: assetId,
      location: text(formData, "location") || undefined,
      custodian: text(formData, "custodian") || undefined,
      date: text(formData, "date"),
      note: text(formData, "note") || undefined,
    });
  } catch (error) {
    return errorState(
      error,
      "Aset tidak dapat dipindahkan. Isi lokasi atau penanggung jawab baru dan tanggalnya.",
    );
  }
  revalidateAsset(assetId);
  return { status: "ok", message: "Pemindahan aset tersimpan." };
}

export async function disposeAssetAction(
  _previous: AssetActionState,
  formData: FormData,
): Promise<AssetActionState> {
  const assetId = text(formData, "asset_id");
  const type = text(formData, "type");
  const method = type === "sale" ? text(formData, "proceeds_method") : "none";
  const due = text(formData, "due_date");
  try {
    await disposeAsset({
      asset_id: assetId,
      idempotency_key: randomUUID(),
      type: type as never,
      date: text(formData, "date"),
      proceeds: method === "none" ? "0" : text(formData, "proceeds") || "0",
      proceeds_method: method as never,
      account_id: method === "cash" ? text(formData, "account_id") || undefined : undefined,
      counterparty:
        method === "receivable" ? text(formData, "counterparty") || undefined : undefined,
      due_date: method === "receivable" && due ? due : undefined,
      reason: text(formData, "reason"),
    });
  } catch (error) {
    return errorState(
      error,
      "Aset tidak dapat dilepas. Periksa tanggal, hasil penjualan, rekening dan alasan.",
    );
  }
  revalidateAsset(assetId);
  revalidatePath("/assets/other-receivables");
  return { status: "ok", message: "Pelepasan aset tercatat." };
}

export async function reverseDisposalAction(
  _previous: AssetActionState,
  formData: FormData,
): Promise<AssetActionState> {
  const assetId = text(formData, "asset_id");
  try {
    await reverseDisposal({
      disposal_id: text(formData, "disposal_id"),
      idempotency_key: randomUUID(),
      date: text(formData, "date") || undefined,
      reason: text(formData, "reason"),
    });
  } catch (error) {
    return errorState(error, "Pelepasan tidak dapat dibatalkan. Periksa tanggal dan alasan.");
  }
  revalidateAsset(assetId);
  revalidatePath("/assets/other-receivables");
  return { status: "ok", message: "Pelepasan dibatalkan. Aset aktif kembali." };
}

export async function cancelAssetAction(
  _previous: AssetActionState,
  formData: FormData,
): Promise<AssetActionState> {
  const assetId = text(formData, "asset_id");
  try {
    await cancelAsset({
      asset_id: assetId,
      idempotency_key: randomUUID(),
      reason: text(formData, "reason"),
    });
  } catch (error) {
    return errorState(error, "Aset tidak dapat dibatalkan. Isi alasan minimal 5 huruf.");
  }
  revalidateAsset(assetId);
  revalidatePath("/assets/new");
  return { status: "ok", message: "Aset dibatalkan." };
}

export async function reverseDepreciationAction(
  _previous: AssetActionState,
  formData: FormData,
): Promise<AssetActionState> {
  const assetId = text(formData, "asset_id");
  try {
    await reverseDepreciation({
      line_id: text(formData, "line_id"),
      idempotency_key: randomUUID(),
      date: text(formData, "date") || undefined,
      reason: text(formData, "reason"),
    });
  } catch (error) {
    return errorState(
      error,
      "Penyusutan tidak dapat dibatalkan. Pilih bulan, lalu isi tanggal dan alasan.",
    );
  }
  revalidateAsset(assetId);
  return { status: "ok", message: "Penyusutan bulan itu dibatalkan." };
}

export async function postDepreciationAction(
  _previous: AssetActionState,
  formData: FormData,
): Promise<AssetActionState> {
  const entity = text(formData, "entity");
  let posted: number;
  try {
    const { membership } = await requirePermission("assets.manage", { entityCode: entity });
    const result = await postDepreciation({
      entity_id: membership.entity_id,
      through: text(formData, "through"),
    });
    posted = result.posted;
  } catch (error) {
    return errorState(
      error,
      "Penyusutan tidak dapat diposting. Pilih tanggal akhir bulan yang sudah lewat.",
    );
  }
  revalidatePath("/assets");
  revalidatePath("/assets/depreciation");
  return {
    status: "ok",
    message:
      posted === 0
        ? "Tidak ada penyusutan yang perlu diposting."
        : `${posted} baris penyusutan diposting.`,
  };
}

/**
 * Loads one asset the business already owned before it started using this app (`asset_load_opening`,
 * `system.import`). The cost, the depreciation already taken up to the cut-over date and the plan for the
 * remaining months are all the database's; this only shapes the form.
 */
export async function loadOpeningAssetAction(
  _previous: AssetActionState,
  formData: FormData,
): Promise<AssetActionState> {
  const entity = text(formData, "entity");
  const method = text(formData, "method") || "none";
  const life = text(formData, "life_months");
  const fiscalClass = text(formData, "fiscal_class");
  const fxCurrency = text(formData, "fx_currency");
  let assetId: string | undefined;
  try {
    const { membership } = await requirePermission("system.import", { entityCode: entity });
    const ids = await loadOpeningAssets({
      entity_id: membership.entity_id,
      idempotency_key: randomUUID(),
      assets: [
        {
          name: text(formData, "name"),
          description: text(formData, "description") || undefined,
          serial_number: text(formData, "serial_number") || undefined,
          location: text(formData, "location") || undefined,
          cost_account: text(formData, "cost_account"),
          acquisition_date: text(formData, "acquisition_date"),
          in_service_date: text(formData, "in_service_date"),
          cutover_date: text(formData, "cutover_date"),
          cost: text(formData, "cost"),
          accumulated: text(formData, "accumulated") || undefined,
          method: method as never,
          life_months: method === "none" || !life ? undefined : Number(life),
          residual: method === "none" ? undefined : text(formData, "residual") || undefined,
          fiscal_class: fiscalClass || undefined,
          fiscal_method: fiscalClass ? (text(formData, "fiscal_method") as never) : undefined,
          fx_currency: fxCurrency || undefined,
          fx_cost: fxCurrency ? text(formData, "fx_cost") : undefined,
          fx_rate: fxCurrency ? text(formData, "fx_rate") : undefined,
        },
      ],
    });
    assetId = ids[0];
  } catch (error) {
    return errorState(
      error,
      "Aset tidak dapat disimpan. Periksa akun, tanggal, harga perolehan dan umur manfaat.",
    );
  }
  revalidatePath("/assets");
  revalidatePath("/assets/depreciation");
  if (!assetId) return { status: "ok", message: "Aset tersimpan." };
  redirect(
    entity ? `/assets/${assetId}?entity=${encodeURIComponent(entity)}` : `/assets/${assetId}`,
  );
}
