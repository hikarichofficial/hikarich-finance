"use server";

import { randomUUID } from "node:crypto";
import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import { AuthzError, describeAuthzError } from "@/domain/authz/errors";
import type { PlanPeriodType, RecurringFrequency, RecurringKind } from "@/domain/planning/planning";
import {
  activateBudget,
  activateRevenueTarget,
  closeBudget,
  closeRevenueTarget,
  createBudget,
  createRecurringRule,
  createRevenueTarget,
  endRecurringRule,
  pauseRecurringRule,
  resumeRecurringRule,
  runDueRecurringOccurrences,
  setBudgetLines,
  setRevenueTargetLines,
  updateRecurringRule,
} from "@/services/planning/planning";

/**
 * Server actions behind Planning's simple status-transition buttons (P13 Part 3h, fourth increment, Step 09
 * §13, §18): Recurring Rule pause/resume/end plus the entity-wide manual "generate now" action
 * (`planning.recurring_run`), and Budget/Revenue Target activate/close (`planning.budget_edit`, shared by
 * both per decision 184); and, from the fifth increment, Budget/Revenue Target create and "set lines"
 * (`planning.budget_edit` again, the same permission `create_budget`/`create_revenue_target`/
 * `set_budget_lines`/`set_revenue_target_lines` all check). Every call is an unmodified P10 RPC -- this layer
 * only shapes form input and turns a thrown `AuthzError` into the same user-safe Indonesian copy every other
 * screen uses, mirroring `src/features/money/transferActions.ts` exactly (including its own
 * `redirect()`-after-success shape for the two create actions). From the sixth increment: Recurring Rule's
 * own create/edit template builder (`createRecurringRuleAction`/`updateRecurringRuleAction`, gated by
 * `planning.recurring_edit`, the exact permission `create_recurring_rule`/`update_recurring_rule` themselves
 * check). `RecurringRuleForm` never assembles the per-kind `template` object itself -- it submits flat,
 * kind-specific named fields (`customer_id`, `vendor_id`, `account_id`, ...) plus one hidden `lines` JSON
 * field (`RecurringLinesEditor`'s own serialization, the same `parseLinesJson` shape `setBudgetLinesAction`
 * already established), and `buildRecurringTemplate` below assembles the actual jsonb template server-side,
 * keyed off the same `kind` the form also sends as a hidden field. This is simpler than replicating Budget's
 * two-RPC create-then-"set-lines" split: `create_recurring_rule`/`update_recurring_rule` both take the whole
 * template as one jsonb parameter, so one form and one submit covers header fields and lines together.
 */

export interface PlanningActionState {
  status: "idle" | "ok" | "error";
  message?: string;
}

function text(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function optionalText(formData: FormData, name: string): string | undefined {
  const value = text(formData, name);
  return value === "" ? undefined : value;
}

function optionalNumber(formData: FormData, name: string): number | undefined {
  const raw = text(formData, name);
  if (raw === "") return undefined;
  const parsed = Number(raw);
  return Number.isFinite(parsed) ? parsed : undefined;
}

type SetBudgetLinesLines = Parameters<typeof setBudgetLines>[0]["lines"];
type SetRevenueTargetLinesLines = Parameters<typeof setRevenueTargetLines>[0]["lines"];

/** The "set lines" grids (`BudgetLinesEditor`/`RevenueTargetLinesEditor`) serialize their own row state into
 * one hidden `lines` JSON field per submit (P13 Part 3h, fifth increment) -- simpler and more testable than
 * reconstructing a dynamic set of `amount__<key>__<month>` fields server-side. `set_budget_lines`/
 * `set_revenue_target_lines` wholesale-replace the entire line set, so an empty array is a valid, deliberate
 * "clear every line" request, not an error. Malformed JSON (or anything not an array) fails the action with
 * a plain message; the real shape check happens where it always does, in the schema at the service call. */
function parseLinesJson(formData: FormData, name: string): unknown[] | null {
  const raw = text(formData, name);
  if (raw === "") return [];
  try {
    const parsed: unknown = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

function errorState(error: unknown, fallback: string): PlanningActionState {
  if (error instanceof AuthzError) {
    return { status: "error", message: describeAuthzError(error) };
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

type RecurringTemplateInput = Parameters<typeof createRecurringRule>[0]["template"];

/** Assembles the per-kind `template` jsonb from the form's own flat, kind-specific fields plus the lines
 * editor's already-parsed array -- the one place that maps `RecurringRuleForm`'s named inputs onto the
 * exact shape `create_recurring_rule`/`update_recurring_rule` expect (mirroring `create_invoice_draft`/
 * `create_bill_draft`/`create_expense_draft`'s own header fields minus `entity_id`/`idempotency_key`/dates,
 * the shape the P10 migration's own comment already documents). A field the form did not render for this
 * kind is simply absent from `formData`, so `optionalText` naturally leaves it out of the template too. */
function buildRecurringTemplate(
  formData: FormData,
  kind: RecurringKind,
  lines: unknown[],
): Record<string, unknown> {
  if (kind === "invoice") {
    return {
      customer_id: text(formData, "customer_id"),
      currency: optionalText(formData, "currency"),
      exchange_rate: optionalText(formData, "exchange_rate"),
      payment_account_id: optionalText(formData, "payment_account_id"),
      payment_channel_id: optionalText(formData, "payment_channel_id"),
      notes: optionalText(formData, "notes"),
      terms: optionalText(formData, "terms"),
      payment_note: optionalText(formData, "payment_note"),
      internal_note: optionalText(formData, "internal_note"),
      lines,
    };
  }
  if (kind === "bill") {
    return {
      vendor_id: text(formData, "vendor_id"),
      vendor_reference: optionalText(formData, "vendor_reference"),
      currency: optionalText(formData, "currency"),
      exchange_rate: optionalText(formData, "exchange_rate"),
      notes: optionalText(formData, "notes"),
      internal_note: optionalText(formData, "internal_note"),
      lines,
    };
  }
  return {
    account_id: text(formData, "account_id"),
    payee_id: optionalText(formData, "payee_id"),
    payee_name: optionalText(formData, "payee_name"),
    receipt_reference: optionalText(formData, "receipt_reference"),
    exchange_rate: optionalText(formData, "exchange_rate"),
    notes: optionalText(formData, "notes"),
    internal_note: optionalText(formData, "internal_note"),
    lines,
  };
}

/** Redirects to the new rule's own Detail page on success, the same shape `createBudgetAction` established. */
export async function createRecurringRuleAction(
  _previous: PlanningActionState,
  formData: FormData,
): Promise<PlanningActionState> {
  const entity = text(formData, "entity");
  const kind = text(formData, "kind") as RecurringKind;
  const lines = parseLinesJson(formData, "lines");
  if (lines === null) {
    return { status: "error", message: "Data baris template tidak valid." };
  }
  let ruleId: string;
  try {
    ruleId = await createRecurringRule({
      entity_id: text(formData, "entity_id"),
      idempotency_key: randomUUID(),
      kind,
      label: text(formData, "label"),
      frequency: text(formData, "frequency") as RecurringFrequency,
      start_date: text(formData, "start_date"),
      template: buildRecurringTemplate(formData, kind, lines) as RecurringTemplateInput,
      interval_count: optionalNumber(formData, "interval_count") ?? 1,
      due_offset_days: optionalNumber(formData, "due_offset_days") ?? 0,
      end_date: optionalText(formData, "end_date"),
      note: optionalText(formData, "note"),
    });
  } catch (error) {
    return errorState(error, "Aturan berulang tidak dapat dibuat.");
  }
  revalidatePath("/planning/recurring");
  redirect(
    entity
      ? `/planning/recurring/${ruleId}?entity=${encodeURIComponent(entity)}`
      : `/planning/recurring/${ruleId}`,
  );
}

/** `kind`, `frequency` and `start_date` are immutable after creation (confirmed against
 * `update_recurring_rule`'s own SQL body: its patch never reads any of the three) -- the form sends `kind`
 * only so this action can assemble the right template shape, and never sends `frequency`/`start_date` at
 * all in edit mode. */
export async function updateRecurringRuleAction(
  _previous: PlanningActionState,
  formData: FormData,
): Promise<PlanningActionState> {
  const ruleId = text(formData, "rule_id");
  const kind = text(formData, "kind") as RecurringKind;
  const lines = parseLinesJson(formData, "lines");
  if (lines === null) {
    return { status: "error", message: "Data baris template tidak valid." };
  }
  try {
    await updateRecurringRule({
      rule_id: ruleId,
      expected_version: optionalNumber(formData, "expected_version"),
      patch: {
        label: text(formData, "label"),
        template: buildRecurringTemplate(formData, kind, lines) as RecurringTemplateInput,
        interval_count: optionalNumber(formData, "interval_count"),
        due_offset_days: optionalNumber(formData, "due_offset_days"),
        end_date: optionalText(formData, "end_date") ?? null,
        note: optionalText(formData, "note") ?? null,
      },
    });
  } catch (error) {
    return errorState(error, "Aturan berulang tidak dapat disimpan.");
  }
  revalidateRecurringRule(ruleId);
  return { status: "ok" };
}

// ---------------------------------------------------------------- budgets

/** Redirects to the new budget's Detail page on success -- `redirect()` throws internally, so it is called
 * outside the try/catch, the exact shape `createTransferAction` already established. */
export async function createBudgetAction(
  _previous: PlanningActionState,
  formData: FormData,
): Promise<PlanningActionState> {
  const entity = text(formData, "entity");
  let budgetId: string;
  try {
    budgetId = await createBudget({
      entity_id: text(formData, "entity_id"),
      idempotency_key: randomUUID(),
      name: text(formData, "name"),
      period_type: text(formData, "period_type") as PlanPeriodType,
      start_date: text(formData, "start_date"),
      end_date: text(formData, "end_date"),
      fiscal_year: optionalNumber(formData, "fiscal_year"),
      note: optionalText(formData, "note"),
    });
  } catch (error) {
    return errorState(error, "Anggaran tidak dapat dibuat.");
  }
  revalidatePath("/planning/budgets");
  redirect(
    entity
      ? `/planning/budgets/${budgetId}?entity=${encodeURIComponent(entity)}`
      : `/planning/budgets/${budgetId}`,
  );
}

export async function setBudgetLinesAction(
  _previous: PlanningActionState,
  formData: FormData,
): Promise<PlanningActionState> {
  const budgetId = text(formData, "budget_id");
  const lines = parseLinesJson(formData, "lines");
  if (lines === null) {
    return { status: "error", message: "Data baris anggaran tidak valid." };
  }
  try {
    await setBudgetLines({
      budget_id: budgetId,
      expected_version: optionalNumber(formData, "expected_version"),
      lines: lines as SetBudgetLinesLines,
    });
  } catch (error) {
    return errorState(error, "Baris anggaran tidak dapat disimpan.");
  }
  revalidateBudget(budgetId);
  return { status: "ok" };
}

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

/** Same `redirect()`-after-success shape as `createBudgetAction`. */
export async function createRevenueTargetAction(
  _previous: PlanningActionState,
  formData: FormData,
): Promise<PlanningActionState> {
  const entity = text(formData, "entity");
  let targetId: string;
  try {
    targetId = await createRevenueTarget({
      entity_id: text(formData, "entity_id"),
      idempotency_key: randomUUID(),
      name: text(formData, "name"),
      period_type: text(formData, "period_type") as PlanPeriodType,
      start_date: text(formData, "start_date"),
      end_date: text(formData, "end_date"),
      fiscal_year: optionalNumber(formData, "fiscal_year"),
      note: optionalText(formData, "note"),
    });
  } catch (error) {
    return errorState(error, "Target pendapatan tidak dapat dibuat.");
  }
  revalidatePath("/planning/targets");
  redirect(
    entity
      ? `/planning/targets/${targetId}?entity=${encodeURIComponent(entity)}`
      : `/planning/targets/${targetId}`,
  );
}

export async function setRevenueTargetLinesAction(
  _previous: PlanningActionState,
  formData: FormData,
): Promise<PlanningActionState> {
  const targetId = text(formData, "target_id");
  const lines = parseLinesJson(formData, "lines");
  if (lines === null) {
    return { status: "error", message: "Data baris target pendapatan tidak valid." };
  }
  try {
    await setRevenueTargetLines({
      target_id: targetId,
      expected_version: optionalNumber(formData, "expected_version"),
      lines: lines as SetRevenueTargetLinesLines,
    });
  } catch (error) {
    return errorState(error, "Baris target pendapatan tidak dapat disimpan.");
  }
  revalidateRevenueTarget(targetId);
  return { status: "ok" };
}

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
