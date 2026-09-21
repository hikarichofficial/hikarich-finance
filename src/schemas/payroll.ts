import { z } from "zod";
import {
  idempotencyKeySchema,
  isoDateSchema,
  moneyTextSchema,
  signedDecimalTextSchema,
} from "@/schemas/accounting";

/**
 * Input and output contracts of the payroll RPCs (P9, Step 05 §15, Step 12): employees, effective-dated
 * compensation, tax facts and BPJS enrolment, the monthly run (calculate, submit, approve, post, close, correct),
 * payments, payslips and the payroll reports. Money is exact decimal text. The database calculates PPh 21 and BPJS
 * from effective-dated rule data, posts the run and decides who may act (`payroll.*`, step-up, maker-checker); the
 * tax fields of an output are null for a person who lacks `payroll.tax_view`.
 */

const reasonSchema = z.string().trim().min(5).max(1000);
const shortReasonSchema = z.string().trim().min(5).max(500);
const optionalText = (max: number) => z.string().trim().max(max).optional();
const componentCodeSchema = z
  .string()
  .trim()
  .toLowerCase()
  .regex(
    /^[a-z][a-z0-9_]{1,40}$/,
    "Kode komponen: huruf kecil, angka atau garis bawah (2-41 karakter)",
  );

export const employmentTypeSchema = z.enum(["permanent", "contract", "probation", "part_time"]);
export const employeeStatusSchema = z.enum(["active", "ended"]);
export const compensationKindSchema = z.enum(["earning", "deduction"]);
export const taxIdStatusSchema = z.enum(["has_tax_id", "no_tax_id", "unknown"]);
export const ptkpStatusSchema = z.enum([
  "TK/0",
  "TK/1",
  "TK/2",
  "TK/3",
  "K/0",
  "K/1",
  "K/2",
  "K/3",
  "unknown",
]);
export const taxMethodSchema = z.enum(["employee_borne", "gross_up"]);
export const bpjsComponentSchema = z.enum([
  "bpjs_kes",
  "bpjs_jht",
  "bpjs_jp",
  "bpjs_jkk",
  "bpjs_jkm",
]);
export const payrollStatusSchema = z.enum([
  "draft",
  "calculated",
  "submitted",
  "approved",
  "posted",
  "partially_paid",
  "paid",
  "closed",
  "corrected",
  "discarded",
]);
export const payrollPaymentKindSchema = z.enum(["net_pay", "bpjs"]);
export const payrollPaymentStatusSchema = z.enum(["confirmed", "reversed"]);
export const payslipStatusSchema = z.enum(["issued", "voided"]);
export const payrollTaxModeSchema = z.enum(["ter", "annual"]);

// ================================================================ employees
export const createEmployeeInputSchema = z.object({
  entity_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  full_name: z.string().trim().min(2).max(200),
  join_date: isoDateSchema,
  employment_type: employmentTypeSchema,
  position_title: z.string().trim().min(1).max(120),
  department: optionalText(120),
});

/** The name, and the join date while no payroll has counted the employee yet. */
export const updateEmployeeInputSchema = z.object({
  employee_id: z.uuid(),
  full_name: z.string().trim().min(2).max(200),
  join_date: isoDateSchema.optional(),
});

export const endEmployeeInputSchema = z.object({
  employee_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  exit_date: isoDateSchema,
  reason: shortReasonSchema,
});

export const recordEmploymentInputSchema = z.object({
  employee_id: z.uuid(),
  effective_from: isoDateSchema,
  employment_type: employmentTypeSchema,
  position_title: z.string().trim().min(1).max(120),
  department: optionalText(120),
  note: optionalText(500),
});

export const compensationItemInputSchema = z
  .object({
    component: componentCodeSchema,
    kind: compensationKindSchema,
    label: z.string().trim().min(1).max(120),
    amount: moneyTextSchema,
    /** Counts towards PPh 21 gross income. Defaults to true in the database. */
    taxable: z.boolean().optional(),
    /** Counts towards the BPJS wage base; only an earning can. */
    bpjs_base: z.boolean().optional(),
  })
  .superRefine((v, ctx) => {
    if (v.kind === "deduction" && v.bpjs_base) {
      ctx.addIssue({
        code: "custom",
        path: ["bpjs_base"],
        message: "Hanya penghasilan yang dapat menjadi dasar upah BPJS",
      });
    }
  });

export const setCompensationInputSchema = z
  .object({
    employee_id: z.uuid(),
    idempotency_key: idempotencyKeySchema,
    effective_from: isoDateSchema,
    items: z.array(compensationItemInputSchema).min(1).max(30),
  })
  .superRefine((v, ctx) => {
    const seen = new Set<string>();
    v.items.forEach((item, index) => {
      if (seen.has(item.component)) {
        ctx.addIssue({
          code: "custom",
          path: ["items", index, "component"],
          message: "Komponen muncul dua kali",
        });
      }
      seen.add(item.component);
    });
  });

const digitsOnly = (value: string) => value.replace(/[^0-9]/g, "");

export const setTaxProfileInputSchema = z
  .object({
    employee_id: z.uuid(),
    idempotency_key: idempotencyKeySchema,
    effective_from: isoDateSchema,
    tax_id_status: taxIdStatusSchema,
    /** A 15 or 16 digit tax number (punctuation is ignored), exactly when the status is has_tax_id. */
    tax_id: z.string().trim().max(40).optional(),
    ptkp_status: ptkpStatusSchema,
    tax_method: taxMethodSchema.default("employee_borne"),
    note: optionalText(500),
  })
  .superRefine((v, ctx) => {
    const digits = digitsOnly(v.tax_id ?? "");
    if (v.tax_id_status === "has_tax_id") {
      if (!/^\d{15,16}$/.test(digits)) {
        ctx.addIssue({
          code: "custom",
          path: ["tax_id"],
          message: "Isi NPWP/NIK 15 atau 16 digit",
        });
      }
    } else if (digits.length > 0) {
      ctx.addIssue({
        code: "custom",
        path: ["tax_id"],
        message: "Kosongkan nomor pajak bila statusnya bukan 'punya NPWP/NIK'",
      });
    }
  });

export const bpjsItemInputSchema = z.object({
  component: bpjsComponentSchema,
  enrolled: z.boolean(),
  /** The rate option, for example `grade_1` for JKK. */
  rate_key: z
    .string()
    .regex(/^[a-z][a-z0-9_]{1,30}$/)
    .optional(),
  member_ref: optionalText(60),
});

export const setBpjsInputSchema = z
  .object({
    employee_id: z.uuid(),
    idempotency_key: idempotencyKeySchema,
    effective_from: isoDateSchema,
    items: z.array(bpjsItemInputSchema).min(1).max(10),
  })
  .superRefine((v, ctx) => {
    const seen = new Set<string>();
    v.items.forEach((item, index) => {
      if (seen.has(item.component)) {
        ctx.addIssue({
          code: "custom",
          path: ["items", index, "component"],
          message: "Komponen BPJS muncul dua kali",
        });
      }
      seen.add(item.component);
    });
  });

/** The taxable income and PPh 21 already withheld before the books start, per employee and tax year (Step 17). */
export const setTaxOpeningInputSchema = z.object({
  employee_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  tax_year: z.number().int().min(2000).max(2100),
  through_month: z.number().int().min(1).max(11),
  taxable_gross: moneyTextSchema,
  pension_deduction: moneyTextSchema.default("0"),
  pph21_withheld: moneyTextSchema,
  note: optionalText(500),
});

export const employeeFilterSchema = z.object({
  entity_id: z.uuid(),
  include_ended: z.boolean().optional(),
});

export const employeeAsOfInputSchema = z.object({
  employee_id: z.uuid(),
  date: isoDateSchema.optional(),
});

export const employeeRowSchema = z.object({
  id: z.uuid(),
  employee_code: z.string(),
  full_name: z.string(),
  status: employeeStatusSchema,
  join_date: isoDateSchema,
  exit_date: isoDateSchema.nullable(),
  employment_type: employmentTypeSchema,
  position_title: z.string(),
  department: z.string().nullable(),
});
export const employeeListSchema = z.array(employeeRowSchema);
export type EmployeeRow = z.infer<typeof employeeRowSchema>;

export const employmentHistoryRowSchema = z.object({
  effective_from: isoDateSchema,
  employment_type: employmentTypeSchema,
  position_title: z.string(),
  department: z.string().nullable(),
  note: z.string().nullable(),
});
export const employmentHistorySchema = z.array(employmentHistoryRowSchema);
export type EmploymentHistoryRow = z.infer<typeof employmentHistoryRowSchema>;

export const compensationComponentSchema = z.object({
  component: z.string(),
  kind: compensationKindSchema,
  label: z.string(),
  amount: signedDecimalTextSchema,
  taxable: z.boolean(),
  bpjs_base: z.boolean(),
  effective_from: isoDateSchema,
});
export const compensationSchema = z.object({
  as_of: isoDateSchema,
  components: z.array(compensationComponentSchema),
  earnings_total: signedDecimalTextSchema,
  deductions_total: signedDecimalTextSchema,
});
export type Compensation = z.infer<typeof compensationSchema>;

export const bpjsEnrolmentSchema = z.object({
  as_of: isoDateSchema,
  enrolled: z.array(
    z.object({
      component: bpjsComponentSchema,
      rate_key: z.string().nullable(),
      member_ref: z.string().nullable(),
      effective_from: isoDateSchema,
    }),
  ),
});
export type BpjsEnrolment = z.infer<typeof bpjsEnrolmentSchema>;

/** The tax number is masked here; the full number is only returned by `employee_tax_identifier`. */
export const taxProfileSchema = z.discriminatedUnion("recorded", [
  z.object({ recorded: z.literal(false) }),
  z.object({
    recorded: z.literal(true),
    effective_from: isoDateSchema,
    tax_id_status: taxIdStatusSchema,
    tax_id_masked: z.string().nullable(),
    ptkp_status: ptkpStatusSchema,
    tax_method: taxMethodSchema,
    note: z.string().nullable(),
  }),
]);
export type TaxProfile = z.infer<typeof taxProfileSchema>;

export const taxIdentifierSchema = z.string().nullable();

// ================================================================ the run
export const createRunInputSchema = z
  .object({
    entity_id: z.uuid(),
    idempotency_key: idempotencyKeySchema,
    /** The first day of the payroll month. */
    period: isoDateSchema,
    pay_date: isoDateSchema,
    note: optionalText(1000),
  })
  .superRefine((v, ctx) => {
    if (!v.period.endsWith("-01")) {
      ctx.addIssue({
        code: "custom",
        path: ["period"],
        message: "Periode gaji dimulai pada tanggal 1",
      });
    }
  });

export const runIdInputSchema = z.object({ run_id: z.uuid() });

export const runCommandInputSchema = z.object({
  run_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
});

export const runReasonInputSchema = z.object({
  run_id: z.uuid(),
  reason: shortReasonSchema,
});

export const reopenRunInputSchema = z.object({
  run_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  reason: shortReasonSchema,
});

export const correctRunInputSchema = z.object({
  run_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  /** The date of the reversing entries. */
  date: isoDateSchema,
  reason: reasonSchema,
});

export const addAdjustmentInputSchema = z.object({
  run_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  employee_id: z.uuid(),
  kind: compensationKindSchema,
  label: z.string().trim().min(1).max(120),
  /** Positive; the kind says whether it adds to or reduces pay. */
  amount: moneyTextSchema.refine((v) => Number(v) > 0, "Jumlah harus lebih dari nol"),
  taxable: z.boolean().default(true),
});

export const removeAdjustmentInputSchema = z.object({ adjustment_id: z.uuid() });

export const runFilterSchema = z.object({
  entity_id: z.uuid(),
  status: payrollStatusSchema.optional(),
  limit: z.number().int().min(1).max(500).optional(),
});

/** Tax figures are null for a person without `payroll.tax_view`. */
const taxMoney = signedDecimalTextSchema.nullable();

export const payrollRunRowSchema = z.object({
  run_id: z.uuid(),
  run_number: z.string(),
  revision: z.number().int(),
  period_start: isoDateSchema,
  period_end: isoDateSchema,
  pay_date: isoDateSchema,
  status: payrollStatusSchema,
  corrects_run_id: z.uuid().nullable(),
  journal_id: z.uuid().nullable(),
  employee_count: z.number().int(),
  review_count: z.number().int(),
  gross_pay_total: signedDecimalTextSchema,
  tax_allowance_total: taxMoney,
  employee_bpjs_total: signedDecimalTextSchema,
  employer_bpjs_total: signedDecimalTextSchema,
  pph21_total: taxMoney,
  net_pay_total: signedDecimalTextSchema,
  net_paid: signedDecimalTextSchema,
  bpjs_paid: signedDecimalTextSchema,
});
export const payrollRunListSchema = z.array(payrollRunRowSchema);
export type PayrollRunRow = z.infer<typeof payrollRunRowSchema>;

export const payrollRunDetailSchema = payrollRunRowSchema.extend({
  calc_version: z.number().int(),
  calculated_at: z.string().nullable(),
  tax_base_total: taxMoney,
  rules: z.array(
    z.object({
      code: z.string(),
      rule_version: z.number().int(),
      effective_from: isoDateSchema,
    }),
  ),
  note: z.string().nullable(),
  submitted_at: z.string().nullable(),
  approved_at: z.string().nullable(),
  posted_at: z.string().nullable(),
  posting_date: isoDateSchema.nullable(),
  reversal_journal_id: z.uuid().nullable(),
  closed_at: z.string().nullable(),
  corrected_at: z.string().nullable(),
  correction_reason: z.string().nullable(),
  /** True when an input changed since the calculation: calculate again before submitting. */
  stale: z.boolean(),
  differences: z.array(z.object({ code: z.string(), text: z.string() })),
});
export type PayrollRunDetail = z.infer<typeof payrollRunDetailSchema>;

export const payrollLineSchema = z.object({
  line_id: z.uuid(),
  employee_id: z.uuid(),
  employee_code: z.string(),
  employee_name: z.string(),
  review_flags: z.array(z.string()),
  info_flags: z.array(z.string()),
  earnings_total: signedDecimalTextSchema,
  reductions_total: signedDecimalTextSchema,
  adjustment_earnings: signedDecimalTextSchema,
  adjustment_deductions: signedDecimalTextSchema,
  gross_pay: signedDecimalTextSchema,
  bpjs_wage_base: signedDecimalTextSchema,
  bpjs_employee: signedDecimalTextSchema,
  bpjs_employer: signedDecimalTextSchema,
  tax_base: taxMoney,
  tax_mode: payrollTaxModeSchema.nullable(),
  tax_method: taxMethodSchema.nullable(),
  pph21: taxMoney,
  tax_allowance: taxMoney,
  net_pay: signedDecimalTextSchema,
  net_paid: signedDecimalTextSchema,
  /** The trace of the tax calculation (rule, category, rate, base); null without `payroll.tax_view`. */
  tax_calc: z.record(z.string(), z.unknown()).nullable(),
});
export const payrollLinesSchema = z.array(payrollLineSchema);
export type PayrollLine = z.infer<typeof payrollLineSchema>;

export const payrollAdjustmentRowSchema = z.object({
  adjustment_id: z.uuid(),
  employee_id: z.uuid(),
  employee_code: z.string(),
  kind: compensationKindSchema,
  label: z.string(),
  amount: signedDecimalTextSchema,
  taxable: z.boolean(),
});
export const payrollAdjustmentsSchema = z.array(payrollAdjustmentRowSchema);
export type PayrollAdjustmentRow = z.infer<typeof payrollAdjustmentRowSchema>;

// ================================================================ payments
/**
 * Net pay is paid per employee (`lines`) or, with no lines, everything still owed; BPJS is one `amount` against the
 * run's liability. The two are not mixed. Needs a fresh step-up.
 */
export const recordPayrollPaymentInputSchema = z
  .object({
    run_id: z.uuid(),
    idempotency_key: idempotencyKeySchema,
    kind: payrollPaymentKindSchema,
    date: isoDateSchema,
    account_id: z.uuid(),
    amount: moneyTextSchema.optional(),
    lines: z
      .array(z.object({ employee: z.uuid(), amount: moneyTextSchema }))
      .min(1)
      .max(1000)
      .optional(),
    reference: optionalText(200),
    note: optionalText(1000),
  })
  .superRefine((v, ctx) => {
    if (v.kind === "bpjs") {
      if (!v.amount) {
        ctx.addIssue({ code: "custom", path: ["amount"], message: "Isi jumlah BPJS yang dibayar" });
      }
      if (v.lines) {
        ctx.addIssue({
          code: "custom",
          path: ["lines"],
          message: "BPJS dibayar sebagai satu jumlah, bukan per karyawan",
        });
      }
    } else {
      if (v.amount) {
        ctx.addIssue({
          code: "custom",
          path: ["amount"],
          message: "Gaji bersih dibayar per karyawan atau seluruh sisa; jangan isi jumlah",
        });
      }
      const seen = new Set<string>();
      v.lines?.forEach((line, index) => {
        if (seen.has(line.employee)) {
          ctx.addIssue({
            code: "custom",
            path: ["lines", index, "employee"],
            message: "Karyawan muncul dua kali",
          });
        }
        seen.add(line.employee);
      });
    }
  });

export const reversePayrollPaymentInputSchema = z.object({
  payment_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  date: isoDateSchema,
  reason: shortReasonSchema,
});

export const payrollPaymentRowSchema = z.object({
  payment_id: z.uuid(),
  payment_number: z.string(),
  kind: payrollPaymentKindSchema,
  status: payrollPaymentStatusSchema,
  payment_date: isoDateSchema,
  amount: signedDecimalTextSchema,
  financial_account_id: z.uuid(),
  reference: z.string().nullable(),
  journal_id: z.uuid(),
  reversal_journal_id: z.uuid().nullable(),
});
export const payrollPaymentsSchema = z.array(payrollPaymentRowSchema);
export type PayrollPaymentRow = z.infer<typeof payrollPaymentRowSchema>;

// ================================================================ payslips
export const payslipFilterSchema = z.object({
  entity_id: z.uuid(),
  run_id: z.uuid().optional(),
  employee_id: z.uuid().optional(),
  limit: z.number().int().min(1).max(500).optional(),
});

export const payslipRowSchema = z.object({
  payslip_id: z.uuid(),
  payslip_number: z.string(),
  status: payslipStatusSchema,
  run_id: z.uuid(),
  employee_id: z.uuid(),
  employee_code: z.string(),
  employee_name: z.string(),
  period: z.string().regex(/^\d{4}-\d{2}$/),
  net_pay: signedDecimalTextSchema,
  issued_at: z.string(),
});
export const payslipListSchema = z.array(payslipRowSchema);
export type PayslipRow = z.infer<typeof payslipRowSchema>;

const payslipComponentSchema = z.object({
  code: z.string(),
  kind: compensationKindSchema,
  label: z.string(),
  amount: signedDecimalTextSchema,
  taxable: z.boolean(),
  bpjs_base: z.boolean(),
});
const payslipAdjustmentSchema = z.object({
  kind: compensationKindSchema,
  label: z.string(),
  amount: signedDecimalTextSchema,
  taxable: z.boolean(),
});
const bpjsShareSchema = z.record(z.string(), signedDecimalTextSchema);

/** The payslip as it was issued (an immutable snapshot); the tax section is absent without `payroll.tax_view`. */
export const payslipDetailSchema = z.object({
  payslip_number: z.string(),
  run_number: z.string(),
  revision: z.number().int(),
  period: z.string().regex(/^\d{4}-\d{2}$/),
  pay_date: isoDateSchema,
  status: payslipStatusSchema,
  issued_at: z.string(),
  voided_at: z.string().nullable(),
  void_reason: z.string().nullable(),
  employee: z.object({ id: z.uuid(), code: z.string(), name: z.string() }),
  components: z.array(payslipComponentSchema),
  adjustments: z.array(payslipAdjustmentSchema),
  earnings_total: signedDecimalTextSchema,
  reductions_total: signedDecimalTextSchema,
  adjustment_earnings: signedDecimalTextSchema,
  adjustment_deductions: signedDecimalTextSchema,
  gross_pay: signedDecimalTextSchema,
  bpjs_employee: bpjsShareSchema,
  bpjs_employer: bpjsShareSchema,
  tax: z
    .object({
      mode: payrollTaxModeSchema.nullable(),
      method: taxMethodSchema.nullable(),
      base: signedDecimalTextSchema,
      pph21: signedDecimalTextSchema,
      allowance: signedDecimalTextSchema,
      withheld_from_employee: signedDecimalTextSchema,
    })
    .optional(),
  net_pay: signedDecimalTextSchema,
  net_paid: signedDecimalTextSchema,
});
export type PayslipDetail = z.infer<typeof payslipDetailSchema>;

// ================================================================ reports
export const taxLedgerInputSchema = z.object({
  entity_id: z.uuid(),
  year: z.number().int().min(2000).max(2100),
  employee_id: z.uuid().optional(),
});

export const taxLedgerRowSchema = z.object({
  employee_id: z.uuid(),
  employee_code: z.string(),
  employee_name: z.string(),
  tax_period: isoDateSchema,
  source: z.enum(["run", "opening"]),
  run_number: z.string().nullable(),
  tax_base: signedDecimalTextSchema,
  tax_mode: payrollTaxModeSchema.nullable(),
  pph21: signedDecimalTextSchema,
  tax_allowance: signedDecimalTextSchema,
  pension_deduction: signedDecimalTextSchema,
});
export const taxLedgerSchema = z.array(taxLedgerRowSchema);
export type TaxLedgerRow = z.infer<typeof taxLedgerRowSchema>;

export const annualReconciliationInputSchema = z.object({
  entity_id: z.uuid(),
  year: z.number().int().min(2000).max(2100),
});

export const annualReconciliationRowSchema = z.object({
  employee_id: z.uuid(),
  employee_code: z.string(),
  employee_name: z.string(),
  months_worked: z.number().int(),
  gross_income: signedDecimalTextSchema,
  annual_tax: signedDecimalTextSchema.nullable(),
  withheld: signedDecimalTextSchema,
  difference: signedDecimalTextSchema.nullable(),
  status: z.enum(["reconciled", "under_withheld", "over_withheld", "incomplete"]),
});
export const annualReconciliationSchema = z.array(annualReconciliationRowSchema);
export type AnnualReconciliationRow = z.infer<typeof annualReconciliationRowSchema>;

export const payrollPeriodInputSchema = z.object({
  entity_id: z.uuid(),
  from: isoDateSchema.optional(),
  to: isoDateSchema.optional(),
});

export const payrollAsOfInputSchema = z.object({
  entity_id: z.uuid(),
  as_of: isoDateSchema.optional(),
});

export const payrollSummaryRowSchema = z.object({
  run_id: z.uuid(),
  run_number: z.string(),
  revision: z.number().int(),
  period_start: isoDateSchema,
  status: payrollStatusSchema,
  employee_count: z.number().int(),
  gross_pay: signedDecimalTextSchema,
  tax_allowance: taxMoney,
  employee_bpjs: signedDecimalTextSchema,
  employer_bpjs: signedDecimalTextSchema,
  pph21: taxMoney,
  net_pay: signedDecimalTextSchema,
  net_unpaid: signedDecimalTextSchema,
  bpjs_unpaid: signedDecimalTextSchema,
  pph21_period_outstanding: taxMoney,
});
export const payrollSummarySchema = z.array(payrollSummaryRowSchema);
export type PayrollSummaryRow = z.infer<typeof payrollSummaryRowSchema>;

export const payrollLiabilityRowSchema = z.object({
  liability: z.enum(["net_pay", "bpjs", "pph21"]),
  period_start: isoDateSchema,
  run_number: z.string().nullable(),
  owed: signedDecimalTextSchema,
  paid: signedDecimalTextSchema,
  outstanding: signedDecimalTextSchema,
});
export const payrollLiabilitySchema = z.array(payrollLiabilityRowSchema);
export type PayrollLiabilityRow = z.infer<typeof payrollLiabilityRowSchema>;

export const payrollControlRowSchema = z.object({
  account_key: z.string(),
  sub_ledger: signedDecimalTextSchema,
  ledger_workflow: signedDecimalTextSchema,
  ledger_other: signedDecimalTextSchema,
  ledger_total: signedDecimalTextSchema,
  difference: signedDecimalTextSchema,
});
export const payrollControlSchema = z.array(payrollControlRowSchema);
export type PayrollControlRow = z.infer<typeof payrollControlRowSchema>;
