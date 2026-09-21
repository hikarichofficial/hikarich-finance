import "server-only";
import { z, type ZodType } from "zod";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { AuthzError, parseAuthzCode } from "@/domain/authz/errors";
import { isoDateSchema, uuidResultSchema } from "@/schemas/accounting";
import {
  addAdjustmentInputSchema,
  annualReconciliationInputSchema,
  annualReconciliationSchema,
  bpjsEnrolmentSchema,
  compensationSchema,
  correctRunInputSchema,
  createEmployeeInputSchema,
  createRunInputSchema,
  employeeAsOfInputSchema,
  employeeFilterSchema,
  employeeListSchema,
  employmentHistorySchema,
  endEmployeeInputSchema,
  payrollAdjustmentsSchema,
  payrollAsOfInputSchema,
  payrollControlSchema,
  payrollLinesSchema,
  payrollLiabilitySchema,
  payrollPaymentsSchema,
  payrollPeriodInputSchema,
  payrollRunDetailSchema,
  payrollRunListSchema,
  payrollSummarySchema,
  payslipDetailSchema,
  payslipFilterSchema,
  payslipListSchema,
  recordEmploymentInputSchema,
  recordPayrollPaymentInputSchema,
  reopenRunInputSchema,
  reversePayrollPaymentInputSchema,
  runCommandInputSchema,
  runFilterSchema,
  runReasonInputSchema,
  setBpjsInputSchema,
  setCompensationInputSchema,
  setTaxOpeningInputSchema,
  setTaxProfileInputSchema,
  taxIdentifierSchema,
  taxLedgerInputSchema,
  taxLedgerSchema,
  taxProfileSchema,
  updateEmployeeInputSchema,
  type AnnualReconciliationRow,
  type BpjsEnrolment,
  type Compensation,
  type EmployeeRow,
  type EmploymentHistoryRow,
  type PayrollAdjustmentRow,
  type PayrollControlRow,
  type PayrollLine,
  type PayrollLiabilityRow,
  type PayrollPaymentRow,
  type PayrollRunDetail,
  type PayrollRunRow,
  type PayrollSummaryRow,
  type PayslipDetail,
  type PayslipRow,
  type TaxLedgerRow,
  type TaxProfile,
} from "@/schemas/payroll";

/**
 * Thin, typed wrappers over the payroll RPCs (P9): employees, compensation, tax facts and BPJS enrolment, the
 * monthly run and its workflow, payments, payslips and the reports. Every call runs as the signed-in person; the
 * database decides who may do what per Entity (`payroll.*`, `payroll.compensation_view`, `payroll.tax_view`,
 * step-up, maker-checker) and applies every rule (PPh 21, BPJS, posting, one live run per month, immutability,
 * idempotency) inside the transaction. This layer validates the input shape, maps the database's error prefixes to
 * AuthzError without leaking detail, and validates what comes back. It holds no payroll, tax or accounting rule of
 * its own (Step 05 §15, Step 12). Labels and flag descriptions live in `@/domain/payroll`.
 *
 * Payroll data is personal and sensitive: nothing here logs a payload, and the full employee tax number is only
 * returned by `getEmployeeTaxIdentifier`, which the database limits to `payroll.tax_view` and a recent step-up.
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
    throw new Error("Operasi penggajian gagal diproses.");
  }
  const parsed = schema.safeParse(data);
  if (!parsed.success) throw new Error("Respons penggajian tidak dikenali.");
  return parsed.data;
}

const uuid = (value: string) => uuidResultSchema.parse(value);
const dateArg = (value?: string) => (value ? isoDateSchema.parse(value) : null);
const nothing = z.null();
const count = z.number().int();

// ================================================================ employees
export async function createEmployee(
  input: z.input<typeof createEmployeeInputSchema>,
): Promise<string> {
  const v = createEmployeeInputSchema.parse(input);
  return callRpc(
    "employee_create",
    {
      p_entity: v.entity_id,
      p_key: v.idempotency_key,
      p_name: v.full_name,
      p_join_date: v.join_date,
      p_employment_type: v.employment_type,
      p_position: v.position_title,
      p_department: v.department ?? null,
    },
    uuidResultSchema,
  );
}

export async function updateEmployee(
  input: z.input<typeof updateEmployeeInputSchema>,
): Promise<void> {
  const v = updateEmployeeInputSchema.parse(input);
  await callRpc(
    "employee_update",
    { p_employee: v.employee_id, p_name: v.full_name, p_join_date: v.join_date ?? null },
    nothing,
  );
}

/** Ends employment from an exit date; the last payroll month settles the year with the annual computation. */
export async function endEmployee(input: z.input<typeof endEmployeeInputSchema>): Promise<void> {
  const v = endEmployeeInputSchema.parse(input);
  await callRpc(
    "employee_end",
    {
      p_employee: v.employee_id,
      p_key: v.idempotency_key,
      p_exit_date: v.exit_date,
      p_reason: v.reason,
    },
    nothing,
  );
}

export async function recordEmployment(
  input: z.input<typeof recordEmploymentInputSchema>,
): Promise<string> {
  const v = recordEmploymentInputSchema.parse(input);
  return callRpc(
    "employee_record_employment",
    {
      p_employee: v.employee_id,
      p_effective_from: v.effective_from,
      p_employment_type: v.employment_type,
      p_position: v.position_title,
      p_department: v.department ?? null,
      p_note: v.note ?? null,
    },
    uuidResultSchema,
  );
}

/** Records the compensation components from a date; returns how many were recorded. */
export async function setCompensation(
  input: z.input<typeof setCompensationInputSchema>,
): Promise<number> {
  const v = setCompensationInputSchema.parse(input);
  return callRpc(
    "employee_set_compensation",
    {
      p_employee: v.employee_id,
      p_key: v.idempotency_key,
      p_effective_from: v.effective_from,
      p_items: v.items,
    },
    count,
  );
}

export async function setTaxProfile(
  input: z.input<typeof setTaxProfileInputSchema>,
): Promise<string> {
  const v = setTaxProfileInputSchema.parse(input);
  return callRpc(
    "employee_set_tax_profile",
    {
      p_employee: v.employee_id,
      p_key: v.idempotency_key,
      p_effective_from: v.effective_from,
      p_tax_id_status: v.tax_id_status,
      p_tax_id: v.tax_id ?? null,
      p_ptkp_status: v.ptkp_status,
      p_tax_method: v.tax_method,
      p_note: v.note ?? null,
    },
    uuidResultSchema,
  );
}

export async function setBpjs(input: z.input<typeof setBpjsInputSchema>): Promise<number> {
  const v = setBpjsInputSchema.parse(input);
  return callRpc(
    "employee_set_bpjs",
    {
      p_employee: v.employee_id,
      p_key: v.idempotency_key,
      p_effective_from: v.effective_from,
      p_items: v.items,
    },
    count,
  );
}

/** Records the taxable income and PPh 21 already withheld this tax year before the books start. */
export async function setTaxOpening(
  input: z.input<typeof setTaxOpeningInputSchema>,
): Promise<string> {
  const v = setTaxOpeningInputSchema.parse(input);
  return callRpc(
    "employee_set_tax_opening",
    {
      p_employee: v.employee_id,
      p_key: v.idempotency_key,
      p_year: v.tax_year,
      p_through_month: v.through_month,
      p_gross: v.taxable_gross,
      p_pension: v.pension_deduction,
      p_tax: v.pph21_withheld,
      p_note: v.note ?? null,
    },
    uuidResultSchema,
  );
}

export async function listEmployees(
  input: z.input<typeof employeeFilterSchema>,
): Promise<EmployeeRow[]> {
  const v = employeeFilterSchema.parse(input);
  return callRpc(
    "employee_list",
    { p_entity: v.entity_id, p_include_ended: v.include_ended ?? true },
    employeeListSchema,
  );
}

export async function getEmploymentHistory(employeeId: string): Promise<EmploymentHistoryRow[]> {
  return callRpc(
    "employee_employment_history",
    { p_employee: uuid(employeeId) },
    employmentHistorySchema,
  );
}

export async function getCompensation(
  input: z.input<typeof employeeAsOfInputSchema>,
): Promise<Compensation> {
  const v = employeeAsOfInputSchema.parse(input);
  return callRpc(
    "employee_compensation_get",
    { p_employee: v.employee_id, p_date: dateArg(v.date) },
    compensationSchema,
  );
}

export async function getBpjsEnrolment(
  input: z.input<typeof employeeAsOfInputSchema>,
): Promise<BpjsEnrolment> {
  const v = employeeAsOfInputSchema.parse(input);
  return callRpc(
    "employee_bpjs_get",
    { p_employee: v.employee_id, p_date: dateArg(v.date) },
    bpjsEnrolmentSchema,
  );
}

/** The tax facts in force; the tax number comes back masked. */
export async function getTaxProfile(
  input: z.input<typeof employeeAsOfInputSchema>,
): Promise<TaxProfile> {
  const v = employeeAsOfInputSchema.parse(input);
  return callRpc(
    "employee_tax_profile_get",
    { p_employee: v.employee_id, p_date: dateArg(v.date) },
    taxProfileSchema,
  );
}

/** The full tax number, for a person with `payroll.tax_view` and a fresh step-up who really needs it (for a filing). */
export async function getEmployeeTaxIdentifier(
  input: z.input<typeof employeeAsOfInputSchema>,
): Promise<string | null> {
  const v = employeeAsOfInputSchema.parse(input);
  return callRpc(
    "employee_tax_identifier",
    { p_employee: v.employee_id, p_date: dateArg(v.date) },
    taxIdentifierSchema,
  );
}

// ================================================================ the run
export async function createPayrollRun(
  input: z.input<typeof createRunInputSchema>,
): Promise<string> {
  const v = createRunInputSchema.parse(input);
  return callRpc(
    "payroll_run_create",
    {
      p_entity: v.entity_id,
      p_key: v.idempotency_key,
      p_period: v.period,
      p_pay_date: v.pay_date,
      p_note: v.note ?? null,
    },
    uuidResultSchema,
  );
}

/** Calculates (or recalculates) every line from the compensation, tax facts, BPJS and rules in force. */
export async function calculatePayrollRun(runId: string): Promise<void> {
  await callRpc("payroll_run_calculate", { p_run: uuid(runId) }, nothing);
}

export async function addPayrollAdjustment(
  input: z.input<typeof addAdjustmentInputSchema>,
): Promise<string> {
  const v = addAdjustmentInputSchema.parse(input);
  return callRpc(
    "payroll_adjustment_add",
    {
      p_run: v.run_id,
      p_key: v.idempotency_key,
      p_employee: v.employee_id,
      p_kind: v.kind,
      p_label: v.label,
      p_amount: v.amount,
      p_taxable: v.taxable,
    },
    uuidResultSchema,
  );
}

export async function removePayrollAdjustment(adjustmentId: string): Promise<void> {
  await callRpc("payroll_adjustment_remove", { p_adjustment: uuid(adjustmentId) }, nothing);
}

export async function submitPayrollRun(
  input: z.input<typeof runCommandInputSchema>,
): Promise<void> {
  const v = runCommandInputSchema.parse(input);
  await callRpc("payroll_run_submit", { p_run: v.run_id, p_key: v.idempotency_key }, nothing);
}

/** Needs `payroll.approve`; the maker-checker rule of the Entity can bar the person who submitted the run. */
export async function approvePayrollRun(
  input: z.input<typeof runCommandInputSchema>,
): Promise<void> {
  const v = runCommandInputSchema.parse(input);
  await callRpc("payroll_run_approve", { p_run: v.run_id, p_key: v.idempotency_key }, nothing);
}

export async function returnPayrollRun(input: z.input<typeof runReasonInputSchema>): Promise<void> {
  const v = runReasonInputSchema.parse(input);
  await callRpc("payroll_run_return", { p_run: v.run_id, p_reason: v.reason }, nothing);
}

export async function discardPayrollRun(
  input: z.input<typeof runReasonInputSchema>,
): Promise<void> {
  const v = runReasonInputSchema.parse(input);
  await callRpc("payroll_run_discard", { p_run: v.run_id, p_reason: v.reason }, nothing);
}

/** Posts the journal, the PPh 21 determination and the payslips; returns the journal id. */
export async function postPayrollRun(
  input: z.input<typeof runCommandInputSchema>,
): Promise<string> {
  const v = runCommandInputSchema.parse(input);
  return callRpc(
    "payroll_run_post",
    { p_run: v.run_id, p_key: v.idempotency_key },
    uuidResultSchema,
  );
}

export async function closePayrollRun(input: z.input<typeof runCommandInputSchema>): Promise<void> {
  const v = runCommandInputSchema.parse(input);
  await callRpc("payroll_run_close", { p_run: v.run_id, p_key: v.idempotency_key }, nothing);
}

export async function reopenPayrollRun(input: z.input<typeof reopenRunInputSchema>): Promise<void> {
  const v = reopenRunInputSchema.parse(input);
  await callRpc(
    "payroll_run_reopen",
    { p_run: v.run_id, p_key: v.idempotency_key, p_reason: v.reason },
    nothing,
  );
}

/**
 * Corrects a posted run: reverses its entries (payments must be reversed first; latest posted month of the tax year
 * first; needs a fresh step-up) and returns the id of the new revision, a draft.
 */
export async function correctPayrollRun(
  input: z.input<typeof correctRunInputSchema>,
): Promise<string> {
  const v = correctRunInputSchema.parse(input);
  return callRpc(
    "payroll_run_correct",
    { p_run: v.run_id, p_key: v.idempotency_key, p_date: v.date, p_reason: v.reason },
    uuidResultSchema,
  );
}

export async function listPayrollRuns(
  input: z.input<typeof runFilterSchema>,
): Promise<PayrollRunRow[]> {
  const v = runFilterSchema.parse(input);
  return callRpc(
    "payroll_run_list",
    { p_entity: v.entity_id, p_status: v.status ?? null, p_limit: v.limit ?? 100 },
    payrollRunListSchema,
  );
}

export async function getPayrollRun(runId: string): Promise<PayrollRunDetail> {
  return callRpc("payroll_run_get", { p_run: uuid(runId) }, payrollRunDetailSchema);
}

export async function getPayrollLines(runId: string): Promise<PayrollLine[]> {
  return callRpc("payroll_run_lines", { p_run: uuid(runId) }, payrollLinesSchema);
}

export async function listPayrollAdjustments(runId: string): Promise<PayrollAdjustmentRow[]> {
  return callRpc("payroll_adjustments_list", { p_run: uuid(runId) }, payrollAdjustmentsSchema);
}

// ================================================================ payments
/** Needs `payroll.pay` and a fresh step-up. Net pay per employee (or all still owed); BPJS as one amount. */
export async function recordPayrollPayment(
  input: z.input<typeof recordPayrollPaymentInputSchema>,
): Promise<string> {
  const v = recordPayrollPaymentInputSchema.parse(input);
  return callRpc(
    "payroll_record_payment",
    {
      p_run: v.run_id,
      p_key: v.idempotency_key,
      p_kind: v.kind,
      p_date: v.date,
      p_account: v.account_id,
      p_amount: v.amount ?? null,
      p_lines: v.lines ?? null,
      p_reference: v.reference ?? null,
      p_note: v.note ?? null,
    },
    uuidResultSchema,
  );
}

export async function reversePayrollPayment(
  input: z.input<typeof reversePayrollPaymentInputSchema>,
): Promise<string> {
  const v = reversePayrollPaymentInputSchema.parse(input);
  return callRpc(
    "payroll_reverse_payment",
    { p_payment: v.payment_id, p_key: v.idempotency_key, p_date: v.date, p_reason: v.reason },
    uuidResultSchema,
  );
}

export async function listPayrollPayments(runId: string): Promise<PayrollPaymentRow[]> {
  return callRpc("payroll_payments_list", { p_run: uuid(runId) }, payrollPaymentsSchema);
}

// ================================================================ payslips
export async function listPayslips(
  input: z.input<typeof payslipFilterSchema>,
): Promise<PayslipRow[]> {
  const v = payslipFilterSchema.parse(input);
  return callRpc(
    "payroll_payslip_list",
    {
      p_entity: v.entity_id,
      p_run: v.run_id ?? null,
      p_employee: v.employee_id ?? null,
      p_limit: v.limit ?? 100,
    },
    payslipListSchema,
  );
}

export async function getPayslip(payslipId: string): Promise<PayslipDetail> {
  return callRpc("payroll_payslip_get", { p_payslip: uuid(payslipId) }, payslipDetailSchema);
}

// ================================================================ reports
export async function getEmployeeTaxLedger(
  input: z.input<typeof taxLedgerInputSchema>,
): Promise<TaxLedgerRow[]> {
  const v = taxLedgerInputSchema.parse(input);
  return callRpc(
    "payroll_employee_tax_ledger",
    { p_entity: v.entity_id, p_year: v.year, p_employee: v.employee_id ?? null },
    taxLedgerSchema,
  );
}

export async function getAnnualReconciliation(
  input: z.input<typeof annualReconciliationInputSchema>,
): Promise<AnnualReconciliationRow[]> {
  const v = annualReconciliationInputSchema.parse(input);
  return callRpc(
    "payroll_annual_reconciliation",
    { p_entity: v.entity_id, p_year: v.year },
    annualReconciliationSchema,
  );
}

export async function getPayrollSummary(
  input: z.input<typeof payrollPeriodInputSchema>,
): Promise<PayrollSummaryRow[]> {
  const v = payrollPeriodInputSchema.parse(input);
  return callRpc(
    "payroll_summary_report",
    { p_entity: v.entity_id, p_from: dateArg(v.from), p_to: dateArg(v.to) },
    payrollSummarySchema,
  );
}

export async function getPayrollLiabilities(
  input: z.input<typeof payrollAsOfInputSchema>,
): Promise<PayrollLiabilityRow[]> {
  const v = payrollAsOfInputSchema.parse(input);
  return callRpc(
    "payroll_liability_report",
    { p_entity: v.entity_id, p_as_of: dateArg(v.as_of) },
    payrollLiabilitySchema,
  );
}

/** The payroll sub-ledger against the control accounts; a difference is a blocker for closing the period. */
export async function getPayrollControl(
  input: z.input<typeof payrollAsOfInputSchema>,
): Promise<PayrollControlRow[]> {
  const v = payrollAsOfInputSchema.parse(input);
  return callRpc(
    "payroll_control_report",
    { p_entity: v.entity_id, p_as_of: dateArg(v.as_of) },
    payrollControlSchema,
  );
}
