"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { AuthzError, describeAuthzError } from "@/domain/authz/errors";
import { requirePermission } from "@/services/identity/access";
import {
  createMarketplaceStore,
  recordMarketplaceSettlement,
  reverseMarketplaceSettlement,
} from "@/services/sales/sales";

/**
 * Server actions behind the Marketplace screen (decision 260): adding a store, recording a settlement
 * (payout) and reversing one. The database computes the tax, posts the journal and the cash movement.
 */

export interface MarketplaceActionState {
  status: "idle" | "ok" | "error";
  message?: string;
}

function text(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function errorState(error: unknown, fallback: string): MarketplaceActionState {
  if (error instanceof AuthzError) {
    return { status: "error", message: describeAuthzError(error) };
  }
  return { status: "error", message: fallback };
}

export async function createStoreAction(
  _previous: MarketplaceActionState,
  formData: FormData,
): Promise<MarketplaceActionState> {
  try {
    const { membership } = await requirePermission("invoices.create", {
      entityCode: text(formData, "entity"),
    });
    await createMarketplaceStore({
      entity_id: membership.entity_id,
      idempotency_key: randomUUID(),
      platform: text(formData, "platform"),
      name: text(formData, "name"),
      account_id: text(formData, "account_id") || undefined,
      pph22_exempt: text(formData, "pph22_exempt") === "on",
    });
  } catch (error) {
    return errorState(error, "Toko tidak dapat disimpan. Periksa nama toko.");
  }
  revalidatePath("/sales/marketplace");
  return { status: "ok", message: "Toko tersimpan." };
}

export async function recordSettlementAction(
  _previous: MarketplaceActionState,
  formData: FormData,
): Promise<MarketplaceActionState> {
  try {
    const { membership } = await requirePermission("invoices.issue", {
      entityCode: text(formData, "entity"),
    });
    await recordMarketplaceSettlement({
      entity_id: membership.entity_id,
      idempotency_key: randomUUID(),
      store_id: text(formData, "store_id"),
      period_start: text(formData, "period_start"),
      period_end: text(formData, "period_end"),
      settlement_date: text(formData, "settlement_date"),
      account_id: text(formData, "account_id"),
      gross: text(formData, "gross"),
      fees: text(formData, "fees") || undefined,
      pph22: text(formData, "pph22") || undefined,
      reference: text(formData, "reference") || undefined,
      note: text(formData, "note") || undefined,
    });
  } catch (error) {
    return errorState(
      error,
      "Pencairan tidak dapat dicatat. Periksa tanggal dan angka (tanpa titik atau koma ribuan).",
    );
  }
  revalidatePath("/sales/marketplace");
  return { status: "ok", message: "Pencairan tercatat." };
}

export async function reverseSettlementAction(
  _previous: MarketplaceActionState,
  formData: FormData,
): Promise<MarketplaceActionState> {
  try {
    await reverseMarketplaceSettlement({
      settlement_id: text(formData, "settlement_id"),
      idempotency_key: randomUUID(),
      date: text(formData, "date"),
      reason: text(formData, "reason"),
    });
  } catch (error) {
    return errorState(error, "Pencairan tidak dapat dibatalkan. Isi alasan minimal 5 karakter.");
  }
  revalidatePath("/sales/marketplace");
  return { status: "ok", message: "Pencairan dibatalkan." };
}
