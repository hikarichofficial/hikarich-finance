"use server";

import { randomUUID } from "node:crypto";
import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import { AuthzError, authzErrorMessage } from "@/domain/authz/errors";
import {
  beginPeriodClose,
  cancelPeriodClose,
  closePeriod,
  discardJournalDraft,
  postJournal,
  reopenPeriod,
  reverseJournal,
} from "@/services/accounting/ledger";

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

/**
 * Server actions behind Accounting Periods Detail's status actions (P13, Step 09 §14). Every call is an
 * unmodified P3 RPC (`begin_period_close`, `cancel_period_close`, `close_period`, `reopen_period`) -- this
 * layer only shapes form input and turns a thrown `AuthzError` into the same user-safe Indonesian copy,
 * mirroring `postJournalAction`/`reverseJournalAction` above exactly. None of these take an idempotency key
 * (the RPCs themselves have none -- a period transition is not itself a financial posting).
 */

export interface PeriodActionState {
  status: "idle" | "ok" | "error";
  message?: string;
}

const PERIOD_IDLE: PeriodActionState = { status: "idle" };
export const idlePeriodActionState = PERIOD_IDLE;

function revalidatePeriod(periodId: string): void {
  revalidatePath("/accounting/periods");
  revalidatePath(`/accounting/periods/${periodId}`);
}

export async function beginPeriodCloseAction(
  _previous: PeriodActionState,
  formData: FormData,
): Promise<PeriodActionState> {
  const periodId = text(formData, "period_id");
  try {
    await beginPeriodClose(periodId);
  } catch (error) {
    return errorState(error, "Periode tidak dapat masuk tinjauan penutupan.");
  }
  revalidatePeriod(periodId);
  return { status: "ok" };
}

export async function cancelPeriodCloseAction(
  _previous: PeriodActionState,
  formData: FormData,
): Promise<PeriodActionState> {
  const periodId = text(formData, "period_id");
  try {
    await cancelPeriodClose(periodId);
  } catch (error) {
    return errorState(error, "Tinjauan penutupan tidak dapat dibatalkan.");
  }
  revalidatePeriod(periodId);
  return { status: "ok" };
}

export async function closePeriodAction(
  _previous: PeriodActionState,
  formData: FormData,
): Promise<PeriodActionState> {
  const periodId = text(formData, "period_id");
  try {
    await closePeriod(periodId);
  } catch (error) {
    return errorState(error, "Periode tidak dapat ditutup.");
  }
  revalidatePeriod(periodId);
  return { status: "ok" };
}

/** OWNER-level; `reopen_period` itself also demands a recent step-up and a written reason (Step 04 §12,
 * Step 06 §8) -- a caller without a recent step-up gets `STEP_UP_REQUIRED`'s own friendly copy back and
 * re-authenticates via `/auth/step-up` before retrying, the same generic error-mapping shape every other
 * step-up-gated action in this codebase already relies on. */
export async function reopenPeriodAction(
  _previous: PeriodActionState,
  formData: FormData,
): Promise<PeriodActionState> {
  const periodId = text(formData, "period_id");
  try {
    await reopenPeriod({ period_id: periodId, reason: text(formData, "reason") });
  } catch (error) {
    return errorState(error, "Periode tidak dapat dibuka kembali.");
  }
  revalidatePeriod(periodId);
  return { status: "ok" };
}
