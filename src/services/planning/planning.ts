import "server-only";
import { z, type ZodType } from "zod";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { AuthzError, parseAuthzCode } from "@/domain/authz/errors";
import { uuidResultSchema } from "@/schemas/accounting";
import { entityCurrencyRowSchema } from "@/schemas/dashboard";
import {
  activateBudgetInputSchema,
  activateRevenueTargetInputSchema,
  budgetListSchema,
  budgetLineListSchema,
  budgetReportSchema,
  closeBudgetInputSchema,
  closeRevenueTargetInputSchema,
  createBudgetInputSchema,
  createRecurringRuleInputSchema,
  createRevenueTargetInputSchema,
  endRecurringRuleInputSchema,
  listBudgetsInputSchema,
  listRecurringOccurrencesInputSchema,
  listRecurringRulesInputSchema,
  listRevenueTargetsInputSchema,
  pauseRecurringRuleInputSchema,
  recurringOccurrenceListSchema,
  recurringRuleListSchema,
  resumeRecurringRuleInputSchema,
  revenueTargetListSchema,
  revenueTargetLineListSchema,
  revenueTargetReportSchema,
  runDueRecurringOccurrencesInputSchema,
  setBudgetLinesInputSchema,
  setRevenueTargetLinesInputSchema,
  updateRecurringRuleInputSchema,
  type BudgetReportRow,
  type BudgetRow,
  type RecurringOccurrenceRow,
  type RecurringRuleRow,
  type RevenueTargetReportRow,
  type RevenueTargetRow,
} from "@/schemas/planning";

/**
 * Thin, typed wrappers over the planning RPCs (P10, Step 01 #22/#23/#26, Step 15 Phase 10): recurring rules
 * and their generated occurrences, budgets and revenue targets. Every call runs as the signed-in person; the
 * database decides who may act (`planning.*`) and owns every rule (idempotent generation, pause/resume/end,
 * Budget/Actual/Committed computed on read). This layer validates the input shape, maps the database's error
 * prefixes to AuthzError without leaking detail, and validates what comes back. It holds no business rule of
 * its own. Labels live in `@/domain/planning`.
 */

async function callRpc<T>(
  name: string,
  args: Record<string, unknown>,
  schema: ZodType<T>,
): Promise<T> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc(name, args);
  if (error) {
    const code = parseAuthzCode(error.message);
    if (code) throw new AuthzError(code);
    throw new Error("Operasi perencanaan gagal diproses.");
  }
  const parsed = schema.safeParse(data);
  if (!parsed.success) throw new Error("Respons perencanaan tidak dikenali.");
  return parsed.data;
}

const nothing = z.null();
const integerResultSchema = z.number().int();
const uuid = (value: string) => uuidResultSchema.parse(value);

/** Duplicated per module (the established precedent -- accounting/tax/assets/financing/payroll each carry
 * their own copy rather than a shared import) so a screen can format money without a second round trip
 * through a cross-module import. */
export async function getEntityBaseCurrency(entityId: string): Promise<string> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("entities")
    .select("base_currency")
    .eq("id", uuid(entityId))
    .single();
  if (error) throw new Error("Gagal memuat mata uang dasar Entity.");
  const parsed = entityCurrencyRowSchema.safeParse(data);
  if (!parsed.success) throw new Error("Respons mata uang dasar Entity tidak dikenali.");
  return parsed.data.base_currency;
}

// ================================================================ recurring rules
export async function createRecurringRule(
  input: z.input<typeof createRecurringRuleInputSchema>,
): Promise<string> {
  const v = createRecurringRuleInputSchema.parse(input);
  return callRpc(
    "create_recurring_rule",
    {
      p_entity: v.entity_id,
      p_key: v.idempotency_key,
      p_kind: v.kind,
      p_label: v.label,
      p_frequency: v.frequency,
      p_start_date: v.start_date,
      p_template: v.template,
      p_interval: v.interval_count,
      p_due_offset_days: v.due_offset_days,
      p_end_date: v.end_date ?? null,
      p_note: v.note ?? null,
    },
    uuidResultSchema,
  );
}

export async function updateRecurringRule(
  input: z.input<typeof updateRecurringRuleInputSchema>,
): Promise<number> {
  const v = updateRecurringRuleInputSchema.parse(input);
  return callRpc(
    "update_recurring_rule",
    { p_rule: v.rule_id, p_patch: v.patch, p_expected_version: v.expected_version ?? null },
    integerResultSchema,
  );
}

export async function pauseRecurringRule(
  input: z.input<typeof pauseRecurringRuleInputSchema>,
): Promise<void> {
  const v = pauseRecurringRuleInputSchema.parse(input);
  await callRpc("pause_recurring_rule", { p_rule: v.rule_id, p_reason: v.reason }, nothing);
}

export async function resumeRecurringRule(
  input: z.input<typeof resumeRecurringRuleInputSchema>,
): Promise<void> {
  const v = resumeRecurringRuleInputSchema.parse(input);
  await callRpc("resume_recurring_rule", { p_rule: v.rule_id }, nothing);
}

export async function endRecurringRule(
  input: z.input<typeof endRecurringRuleInputSchema>,
): Promise<void> {
  const v = endRecurringRuleInputSchema.parse(input);
  await callRpc("end_recurring_rule", { p_rule: v.rule_id, p_reason: v.reason }, nothing);
}

export async function listRecurringRules(
  input: z.input<typeof listRecurringRulesInputSchema>,
): Promise<RecurringRuleRow[]> {
  const v = listRecurringRulesInputSchema.parse(input);
  return callRpc(
    "list_recurring_rules",
    { p_entity: v.entity_id, p_status: v.status ?? null },
    recurringRuleListSchema,
  );
}

export async function listRecurringOccurrences(
  input: z.input<typeof listRecurringOccurrencesInputSchema>,
): Promise<RecurringOccurrenceRow[]> {
  const v = listRecurringOccurrencesInputSchema.parse(input);
  return callRpc(
    "list_recurring_occurrences",
    { p_rule: v.rule_id, p_limit: v.limit ?? null },
    recurringOccurrenceListSchema,
  );
}

/** Manual "generate now" (`planning.recurring_run`). The scheduled path calls the same database function
 * with the service key and no signed-in user (DECISIONS 136) — this wrapper is for the manual action only. */
export async function runDueRecurringOccurrences(
  input: z.input<typeof runDueRecurringOccurrencesInputSchema>,
): Promise<number> {
  const v = runDueRecurringOccurrencesInputSchema.parse(input);
  return callRpc(
    "run_due_recurring_occurrences",
    { p_entity: v.entity_id, p_as_of: v.as_of ?? null },
    integerResultSchema,
  );
}

// ================================================================ budgets
export async function createBudget(
  input: z.input<typeof createBudgetInputSchema>,
): Promise<string> {
  const v = createBudgetInputSchema.parse(input);
  return callRpc(
    "create_budget",
    {
      p_entity: v.entity_id,
      p_key: v.idempotency_key,
      p_name: v.name,
      p_period_type: v.period_type,
      p_start_date: v.start_date,
      p_end_date: v.end_date,
      p_fiscal_year: v.fiscal_year ?? null,
      p_note: v.note ?? null,
    },
    uuidResultSchema,
  );
}

export async function setBudgetLines(
  input: z.input<typeof setBudgetLinesInputSchema>,
): Promise<number> {
  const v = setBudgetLinesInputSchema.parse(input);
  return callRpc(
    "set_budget_lines",
    { p_budget: v.budget_id, p_lines: v.lines, p_expected_version: v.expected_version ?? null },
    integerResultSchema,
  );
}

export async function activateBudget(
  input: z.input<typeof activateBudgetInputSchema>,
): Promise<void> {
  const v = activateBudgetInputSchema.parse(input);
  await callRpc("activate_budget", { p_budget: v.budget_id }, nothing);
}

export async function closeBudget(input: z.input<typeof closeBudgetInputSchema>): Promise<void> {
  const v = closeBudgetInputSchema.parse(input);
  await callRpc("close_budget", { p_budget: v.budget_id }, nothing);
}

export async function listBudgets(
  input: z.input<typeof listBudgetsInputSchema>,
): Promise<BudgetRow[]> {
  const v = listBudgetsInputSchema.parse(input);
  return callRpc(
    "list_budgets",
    { p_entity: v.entity_id, p_status: v.status ?? null },
    budgetListSchema,
  );
}

export async function getBudgetLines(budgetId: string) {
  return callRpc("get_budget_lines", { p_budget: budgetId }, budgetLineListSchema);
}

/** Budget vs Actual vs Committed vs Remaining vs %Used vs Variance, computed live (never stored). */
export async function getBudgetReport(budgetId: string): Promise<BudgetReportRow[]> {
  return callRpc("get_budget_report", { p_budget: budgetId }, budgetReportSchema);
}

// ================================================================ revenue targets
export async function createRevenueTarget(
  input: z.input<typeof createRevenueTargetInputSchema>,
): Promise<string> {
  const v = createRevenueTargetInputSchema.parse(input);
  return callRpc(
    "create_revenue_target",
    {
      p_entity: v.entity_id,
      p_key: v.idempotency_key,
      p_name: v.name,
      p_period_type: v.period_type,
      p_start_date: v.start_date,
      p_end_date: v.end_date,
      p_fiscal_year: v.fiscal_year ?? null,
      p_note: v.note ?? null,
    },
    uuidResultSchema,
  );
}

export async function setRevenueTargetLines(
  input: z.input<typeof setRevenueTargetLinesInputSchema>,
): Promise<number> {
  const v = setRevenueTargetLinesInputSchema.parse(input);
  return callRpc(
    "set_revenue_target_lines",
    { p_target: v.target_id, p_lines: v.lines, p_expected_version: v.expected_version ?? null },
    integerResultSchema,
  );
}

export async function activateRevenueTarget(
  input: z.input<typeof activateRevenueTargetInputSchema>,
): Promise<void> {
  const v = activateRevenueTargetInputSchema.parse(input);
  await callRpc("activate_revenue_target", { p_target: v.target_id }, nothing);
}

export async function closeRevenueTarget(
  input: z.input<typeof closeRevenueTargetInputSchema>,
): Promise<void> {
  const v = closeRevenueTargetInputSchema.parse(input);
  await callRpc("close_revenue_target", { p_target: v.target_id }, nothing);
}

export async function listRevenueTargets(
  input: z.input<typeof listRevenueTargetsInputSchema>,
): Promise<RevenueTargetRow[]> {
  const v = listRevenueTargetsInputSchema.parse(input);
  return callRpc(
    "list_revenue_targets",
    { p_entity: v.entity_id, p_status: v.status ?? null },
    revenueTargetListSchema,
  );
}

export async function getRevenueTargetLines(targetId: string) {
  return callRpc("get_revenue_target_lines", { p_target: targetId }, revenueTargetLineListSchema);
}

/** Target vs Actual (issued revenue) vs open AR, computed live (never stored). */
export async function getRevenueTargetReport(targetId: string): Promise<RevenueTargetReportRow[]> {
  return callRpc("get_revenue_target_report", { p_target: targetId }, revenueTargetReportSchema);
}
