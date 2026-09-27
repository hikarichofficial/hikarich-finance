"use server";

import { revalidatePath } from "next/cache";
import { AuthzError, authzErrorMessage } from "@/domain/authz/errors";
import {
  activateBudget,
  activateRevenueTarget,
  closeBudget,
  closeRevenueTarget,
  endRecurringRule,
  pauseRecurringRule,
  resumeRecurringRule,
  runDueRecurringOccurrences,
} from "@/services/planning/planning";

/**
 * Server actions behind Planning's simple status-transition buttons (P13 Part 3h, fourth increment, Step 09
 * §13, §18): Recurring Rule pause/resume/end plus the entity-wide manual "generate now" action
 * (`planning.recurring_run`), and Budget/Revenue Target activate/close (`planning.budget_edit`, shared by
 * both per decision 184). Every call is an unmodified P10 RPC -- this layer only shapes form input and turns
 * a thrown `AuthzError` into the same user-safe Indonesian copy every other screen uses, mirroring
 * `src/features/money/transferActions.ts` exactly. Budget/Target "set lines" and Recurring's own per-kind
 * template create/edit builder are a separate, later increment (decision 164's own ordering) -- not here.
 */

export interface PlanningActionState {
  status: "idle" | "ok" | "error";
  message?: string;
}

const IDLE: PlanningActionState = { status: "idle" };
export const idlePlanningActionState = IDLE;

function text(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function optionalText(formData: FormData, name: string): string | undefined {
  const value = text(formData, name);
  return value === "" ? undefined : value;
}

function errorState(error: unknown, fallback: string): PlanningActionState {
  if (error instanceof AuthzError) {
    return { status: "error", message: authzErrorMessage(error.code) };
  }
  return { status: "error", message: fallback };
}

function revalidateRecurringRule(ruleId: string): void {
  revalidatePath("/planning/recurring");
  revalidatePath(`/planning/recurring/${ruleId}`);
}

function revalidateBudget(budgetId: string): void {
  revalidatePath("/planning/budgets");
  revalidatePath(`/planning/budgets/${budgetId}`);
}

function revalidateRevenueTarget(targetId: string): void {
  revalidatePath("/planning/targets");
  revalidatePath(`/planning/targets/${targetId}`);
}

// ---------------------------------------------------------------- recurring rules

export async function pauseRecurringRuleAction(
  _previous: PlanningActionState,
  formData: FormData,
): Promise<PlanningActionState> {
  const ruleId = text(formData, "rule_id");
  try {
    await pauseRecurringRule({ rule_id: ruleId, reason: text(formData, "reason") });
  } catch (error) {
    return errorState(error, "Aturan berulang tidak dapat dijeda.");
  }
  revalidateRecurringRule(ruleId);
  return { status: "ok" };
}

export async function resumeRecurringRuleAction(
  _previous: PlanningActionState,
  formData: FormData,
): Promise<PlanningActionState> {
  const ruleId = text(formData, "rule_id");
  try {
    await resumeRecurringRule({ rule_id: ruleId });
  } catch (error) {
    return errorState(error, "Aturan berulang tidak dapat dilanjutkan.");
  }
  revalidateRecurringRule(ruleId);
  return { status: "ok" };
}

export async function endRecurringRuleAction(
  _previous: PlanningActionState,
  formData: FormData,
): Promise<PlanningActionState> {
  const ruleId = text(formData, "rule_id");
  try {
    await endRecurringRule({ rule_id: ruleId, reason: text(formData, "reason") });
  } catch (error) {
    return errorState(error, "Aturan berulang tidak dapat diakhiri.");
  }
  revalidateRecurringRule(ruleId);
  return { status: "ok" };
}

export interface RunDueActionState {
  status: "idle" | "ok" | "error";
  message?: string;
  count?: number;
}

const RUN_DUE_IDLE: RunDueActionState = { status: "idle" };
export const idleRunDueActionState = RUN_DUE_IDLE;

/** The manual "generate now" action (Step 13 §14) -- entity-wide, not per-rule, so it lives on the Register
 * screen rather than a Recurring Rule Detail screen. */
export async function runDueRecurringOccurrencesAction(
  _previous: RunDueActionState,
  formData: FormData,
): Promise<RunDueActionState> {
  const entityId = text(formData, "entity_id");
  let count: number;
  try {
    count = await runDueRecurringOccurrences({
      entity_id: entityId,
      as_of: optionalText(formData, "as_of"),
    });
  } catch (error) {
    return errorState(error, "Kejadian berulang tidak dapat dijalankan.");
  }
  revalidatePath("/planning/recurring");
  return {
    status: "ok",
    count,
    message:
      count === 0 ? "Tidak ada kejadian yang jatuh tempo." : `${count} kejadian berhasil dibuat.`,
  };
}

// ---------------------------------------------------------------- budgets

export async function activateBudgetAction(
  _previous: PlanningActionState,
  formData: FormData,
): Promise<PlanningActionState> {
  const budgetId = text(formData, "budget_id");
  try {
    await activateBudget({ budget_id: budgetId });
  } catch (error) {
    return errorState(error, "Anggaran tidak dapat diaktifkan.");
  }
  revalidateBudget(budgetId);
  return { status: "ok" };
}

export async function closeBudgetAction(
  _previous: PlanningActionState,
  formData: FormData,
): Promise<PlanningActionState> {
  const budgetId = text(formData, "budget_id");
  try {
    await closeBudget({ budget_id: budgetId });
  } catch (error) {
    return errorState(error, "Anggaran tidak dapat ditutup.");
  }
  revalidateBudget(budgetId);
  return { status: "ok" };
}

// ---------------------------------------------------------------- revenue targets

export async function activateRevenueTargetAction(
  _previous: PlanningActionState,
  formData: FormData,
): Promise<PlanningActionState> {
  const targetId = text(formData, "target_id");
  try {
    await activateRevenueTarget({ target_id: targetId });
  } catch (error) {
    return errorState(error, "Target pendapatan tidak dapat diaktifkan.");
  }
  revalidateRevenueTarget(targetId);
  return { status: "ok" };
}

export async function closeRevenueTargetAction(
  _previous: PlanningActionState,
  formData: FormData,
): Promise<PlanningActionState> {
  const targetId = text(formData, "target_id");
  try {
    await closeRevenueTarget({ target_id: targetId });
  } catch (error) {
    return errorState(error, "Target pendapatan tidak dapat ditutup.");
  }
  revalidateRevenueTarget(targetId);
  return { status: "ok" };
}
