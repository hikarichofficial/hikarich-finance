"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { AuthzError, authzErrorMessage } from "@/domain/authz/errors";
import { parseStatementText } from "@/domain/money/reconciliationSession";
import { requirePermission } from "@/services/identity/access";
import {
  addStatementLines,
  completeReconciliation,
  createReconciliationSession,
  discardReconciliationSession,
  excludeStatementLine,
  includeStatementLine,
  matchStatementLine,
  reopenReconciliation,
  unmatchStatementLine,
} from "@/services/money/money";

/**
 * Reconciliation workspace actions (Step 09 §13, decision 251). Every action is an unmodified P4 RPC that
 * re-checks `money.reconcile` and its own rule (exact match totals, continuity of the opening balance, a
 * reason for a non-zero difference, completed sessions locked until reopened).
 */

export interface ReconActionState {
  status: "idle" | "ok" | "error";
  message?: string;
  errors?: string[];
}

export const idleReconActionState: ReconActionState = { status: "idle" };

function text(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function sessionHref(id: string, entity: string, extra = ""): string {
  const params = new URLSearchParams();
  if (entity) params.set("entity", entity);
  const qs = params.toString();
  return `/money/reconciliation/${id}${qs ? `?${qs}` : ""}${extra}`;
}

/** The database's own explanation after an `INVALID:`/`CONFLICT:` prefix. */
function detailOf(message: string): string | undefined {
  const match = /^(?:INVALID|CONFLICT):\s*([\s\S]+)$/.exec(message.trim());
  return match ? match[1] : undefined;
}

function fail(error: unknown, fallback: string): ReconActionState {
  if (error instanceof AuthzError) {
    const detail = detailOf(error.message);
    return {
      status: "error",
      message: authzErrorMessage(error.code),
      errors: detail ? [`Detail dari sistem: ${detail}`] : undefined,
    };
  }
  return { status: "error", message: fallback };
}

function refresh(sessionId: string): void {
  revalidatePath("/money/reconciliation");
  revalidatePath(`/money/reconciliation/${sessionId}`);
}

export async function createSessionAction(
  _previous: ReconActionState,
  formData: FormData,
): Promise<ReconActionState> {
  const entity = text(formData, "entity");
  let id: string;
  try {
    const { membership } = await requirePermission("money.reconcile", { entityCode: entity });
    id = await createReconciliationSession({
      entity_id: membership.entity_id,
      idempotency_key: randomUUID(),
      account_id: text(formData, "account_id"),
      period_start: text(formData, "period_start"),
      period_end: text(formData, "period_end"),
      statement_opening: text(formData, "statement_opening"),
      statement_closing: text(formData, "statement_closing"),
      note: text(formData, "note") || undefined,
    });
  } catch (error) {
    return fail(
      error,
      "Sesi tidak dapat dibuat. Periksa periode dan saldo (angka dengan titik desimal).",
    );
  }
  refresh(id);
  redirect(sessionHref(id, entity));
}

export async function addLinesAction(
  _previous: ReconActionState,
  formData: FormData,
): Promise<ReconActionState> {
  const sessionId = text(formData, "session_id");
  const parsed = parseStatementText(String(formData.get("lines") ?? ""));
  if (!parsed.ok)
    return { status: "error", message: "Baris mutasi belum valid.", errors: parsed.errors };
  try {
    const result = await addStatementLines({ session_id: sessionId, lines: parsed.lines });
    refresh(sessionId);
    return {
      status: "ok",
      message: `${result.added} baris ditambahkan${result.skipped ? `, ${result.skipped} sudah ada dan dilewati` : ""}.`,
    };
  } catch (error) {
    return fail(error, "Baris mutasi tidak dapat ditambahkan.");
  }
}

export async function matchLineAction(
  _previous: ReconActionState,
  formData: FormData,
): Promise<ReconActionState> {
  const sessionId = text(formData, "session_id");
  const entity = text(formData, "entity");
  const movementIds = formData
    .getAll("movement_id")
    .filter((v): v is string => typeof v === "string");
  if (movementIds.length === 0)
    return { status: "error", message: "Pilih minimal satu pergerakan kas untuk dicocokkan." };
  try {
    await matchStatementLine({
      line_id: text(formData, "line_id"),
      movement_ids: movementIds,
      manual_reason: text(formData, "manual_reason") || undefined,
    });
  } catch (error) {
    return fail(error, "Baris tidak dapat dicocokkan. Total pergerakan harus sama persis.");
  }
  refresh(sessionId);
  redirect(sessionHref(sessionId, entity));
}

export async function unmatchLineAction(
  _previous: ReconActionState,
  formData: FormData,
): Promise<ReconActionState> {
  const sessionId = text(formData, "session_id");
  try {
    await unmatchStatementLine({
      line_id: text(formData, "line_id"),
      reason: text(formData, "reason"),
    });
  } catch (error) {
    return fail(error, "Pencocokan tidak dapat dibatalkan. Alasan minimal 5 karakter.");
  }
  refresh(sessionId);
  return { status: "ok", message: "Pencocokan dibatalkan." };
}

export async function excludeLineAction(
  _previous: ReconActionState,
  formData: FormData,
): Promise<ReconActionState> {
  const sessionId = text(formData, "session_id");
  try {
    await excludeStatementLine({
      line_id: text(formData, "line_id"),
      reason: text(formData, "reason"),
    });
  } catch (error) {
    return fail(error, "Baris tidak dapat dikecualikan. Alasan minimal 5 karakter.");
  }
  refresh(sessionId);
  return { status: "ok", message: "Baris dikecualikan." };
}

export async function includeLineAction(
  _previous: ReconActionState,
  formData: FormData,
): Promise<ReconActionState> {
  const sessionId = text(formData, "session_id");
  try {
    await includeStatementLine(text(formData, "line_id"));
  } catch (error) {
    return fail(error, "Baris tidak dapat dikembalikan.");
  }
  refresh(sessionId);
  return { status: "ok", message: "Baris dikembalikan." };
}

export async function completeSessionAction(
  _previous: ReconActionState,
  formData: FormData,
): Promise<ReconActionState> {
  const sessionId = text(formData, "session_id");
  try {
    const difference = await completeReconciliation({
      session_id: sessionId,
      accept_reason: text(formData, "accept_reason") || undefined,
    });
    refresh(sessionId);
    return { status: "ok", message: `Rekonsiliasi selesai. Selisih: ${difference}.` };
  } catch (error) {
    return fail(
      error,
      "Rekonsiliasi belum dapat diselesaikan. Bila ada selisih, isi alasan minimal 10 karakter.",
    );
  }
}

export async function reopenSessionAction(
  _previous: ReconActionState,
  formData: FormData,
): Promise<ReconActionState> {
  const sessionId = text(formData, "session_id");
  try {
    await reopenReconciliation({ session_id: sessionId, reason: text(formData, "reason") });
  } catch (error) {
    return fail(error, "Sesi tidak dapat dibuka kembali. Alasan minimal 10 karakter.");
  }
  refresh(sessionId);
  return { status: "ok", message: "Sesi dibuka kembali." };
}

export async function discardSessionAction(
  _previous: ReconActionState,
  formData: FormData,
): Promise<ReconActionState> {
  const sessionId = text(formData, "session_id");
  const entity = text(formData, "entity");
  try {
    await discardReconciliationSession(sessionId);
  } catch (error) {
    return fail(error, "Sesi tidak dapat dibuang.");
  }
  revalidatePath("/money/reconciliation");
  redirect(
    entity ? `/money/reconciliation?entity=${encodeURIComponent(entity)}` : "/money/reconciliation",
  );
}
