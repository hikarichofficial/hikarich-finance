"use server";

import { randomUUID } from "node:crypto";
import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import { AuthzError, authzErrorMessage } from "@/domain/authz/errors";
import { discardJournalDraft, postJournal, reverseJournal } from "@/services/accounting/ledger";

/**
 * Server actions behind Journal Detail's status actions (P13 Part 3d, Step 09 §14). Every call is an
 * unmodified P3 RPC (`post_journal`, `reverse_journal`, `discard_journal_draft`) -- this layer only shapes
 * form input and turns a thrown `AuthzError` into the same user-safe Indonesian copy every other screen uses,
 * mirroring `src/features/money/transferActions.ts` exactly. Only `manual`/`adjusting` journals ever reach
 * these actions in the UI (`JournalActions`'s own gate), matching what each RPC itself refuses.
 */

export interface JournalActionState {
  status: "idle" | "ok" | "error";
  message?: string;
}

const IDLE: JournalActionState = { status: "idle" };
export const idleJournalActionState = IDLE;

function text(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function errorState(error: unknown, fallback: string): JournalActionState {
  if (error instanceof AuthzError) {
    return { status: "error", message: authzErrorMessage(error.code) };
  }
  return { status: "error", message: fallback };
}

function revalidateJournal(journalId: string): void {
  revalidatePath("/accounting/journal");
  revalidatePath(`/accounting/journal/${journalId}`);
}

export async function postJournalAction(
  _previous: JournalActionState,
  formData: FormData,
): Promise<JournalActionState> {
  const journalId = text(formData, "journal_id");
  try {
    await postJournal({ journal_id: journalId, idempotency_key: randomUUID() });
  } catch (error) {
    return errorState(error, "Jurnal tidak dapat diposting.");
  }
  revalidateJournal(journalId);
  return { status: "ok" };
}

export async function reverseJournalAction(
  _previous: JournalActionState,
  formData: FormData,
): Promise<JournalActionState> {
  const journalId = text(formData, "journal_id");
  try {
    await reverseJournal({
      journal_id: journalId,
      idempotency_key: randomUUID(),
      reversal_date: text(formData, "reversal_date"),
      reason: text(formData, "reason"),
    });
  } catch (error) {
    return errorState(error, "Jurnal tidak dapat dibalik.");
  }
  revalidateJournal(journalId);
  return { status: "ok" };
}

/** Discarding actually deletes the draft journal (`discard_journal_draft`'s own SQL), so unlike Post/Reverse
 * there is no journal left to show afterward -- this redirects to the Journal List instead of returning an
 * `ok` state, the same `redirect()`-after-success shape used throughout this codebase's server actions
 * (`redirect()` throws internally and must run outside the try/catch). */
export async function discardJournalAction(
  _previous: JournalActionState,
  formData: FormData,
): Promise<JournalActionState> {
  const journalId = text(formData, "journal_id");
  const entity = text(formData, "entity");
  try {
    await discardJournalDraft(journalId);
  } catch (error) {
    return errorState(error, "Draf jurnal tidak dapat dibuang.");
  }
  revalidatePath("/accounting/journal");
  redirect(
    entity ? `/accounting/journal?entity=${encodeURIComponent(entity)}` : "/accounting/journal",
  );
}
