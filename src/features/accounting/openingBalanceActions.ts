"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { AuthzError, authzErrorMessage } from "@/domain/authz/errors";
import { requirePermission } from "@/services/identity/access";
import { completeOpeningBalances, postOpeningBalances } from "@/services/accounting/ledger";

/**
 * Opening Balances actions (Step 15 §24, decision 245): `post_opening_balances` and
 * `complete_opening_balances` (P3), both gated `system.import` inside the database. Lines arrive as one
 * JSON field already checked by `checkOpeningLines`; the RPC re-validates everything.
 */

export interface OpeningActionState {
  status: "idle" | "ok" | "error";
  message?: string;
}

export const idleOpeningActionState: OpeningActionState = { status: "idle" };

function text(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function errorState(error: unknown, fallback: string): OpeningActionState {
  if (error instanceof AuthzError)
    return { status: "error", message: authzErrorMessage(error.code) };
  return { status: "error", message: fallback };
}

export async function postOpeningBalancesAction(
  _previous: OpeningActionState,
  formData: FormData,
): Promise<OpeningActionState> {
  const entity = text(formData, "entity");
  let lines: unknown;
  try {
    lines = JSON.parse(text(formData, "lines") || "[]");
  } catch {
    return { status: "error", message: "Baris saldo awal tidak valid." };
  }
  try {
    const { membership } = await requirePermission("system.import", { entityCode: entity });
    await postOpeningBalances({
      entity_id: membership.entity_id,
      idempotency_key: randomUUID(),
      cutover_date: text(formData, "cutover_date"),
      note: text(formData, "note") || undefined,
      lines: lines as never,
    });
  } catch (error) {
    return errorState(
      error,
      "Saldo awal tidak dapat diposting. Pastikan periode tanggal cutover terbuka, semua akun adalah akun neraca, dan saldo awal belum diselesaikan.",
    );
  }
  revalidatePath("/accounting/opening-balances");
  return { status: "ok", message: "Saldo awal berhasil diposting." };
}

export async function completeOpeningBalancesAction(
  _previous: OpeningActionState,
  formData: FormData,
): Promise<OpeningActionState> {
  const entity = text(formData, "entity");
  let residual: string;
  try {
    const { membership } = await requirePermission("system.import", { entityCode: entity });
    residual = await completeOpeningBalances(
      membership.entity_id,
      text(formData, "note") || undefined,
    );
  } catch (error) {
    return errorState(error, "Saldo awal tidak dapat diselesaikan.");
  }
  revalidatePath("/accounting/opening-balances");
  return {
    status: "ok",
    message: `Saldo awal diselesaikan. Sisa akun penampung (clearing): ${residual}.`,
  };
}
