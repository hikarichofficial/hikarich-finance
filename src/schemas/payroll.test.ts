import { describe, expect, it } from "vitest";
import {
  addAdjustmentInputSchema,
  annualReconciliationSchema,
  bpjsEnrolmentSchema,
  compensationSchema,
  correctRunInputSchema,
  createEmployeeInputSchema,
  createRunInputSchema,
  employeeListSchema,
  employmentHistorySchema,
  payrollAdjustmentsSchema,
  payrollControlSchema,
  payrollLinesSchema,
  payrollLiabilitySchema,
  payrollPaymentsSchema,
  payrollRunDetailSchema,
  payrollRunListSchema,
  payrollSummarySchema,
  payslipDetailSchema,
  payslipListSchema,
  recordPayrollPaymentInputSchema,
  setBpjsInputSchema,
  setCompensationInputSchema,
  setTaxOpeningInputSchema,
  setTaxProfileInputSchema,
  taxLedgerSchema,
  taxProfileSchema,
} from "./payroll";

const ENTITY = "0b2f6d0e-6d2e-4a55-9c58-3f6f3c1d7a01";
const EMPLOYEE = "0b2f6d0e-6d2e-4a55-9c58-3f6f3c1d7a02";
const RUN = "0b2f6d0e-6d2e-4a55-9c58-3f6f3c1d7a03";
const ACCOUNT = "0b2f6d0e-6d2e-4a55-9c58-3f6f3c1d7a04";
const KEY = "key-payroll-0001";

// ---------------------------------------------------------------- what the database really returns
// These payloads were captured from the P9 RPCs run against synthetic data; they keep the schemas honest.
const employeeListSample: unknown = [
  {
    id: "1881b64d-fcc5-4278-8988-52faca019625",
    status: "active",
    exit_date: null,
    full_name: "Employee A",
    join_date: "2025-03-01",
    department: null,
    employee_code: "EMP-2025-0001",
    position_title: "Staff",
    employment_type: "permanent",
  },
  {
    id: "d88d148a-9ce0-4dde-b696-75b25d4c6eb4",
    status: "active",
    exit_date: null,
    full_name: "Employee C",
    join_date: "2025-06-01",
    department: null,
    employee_code: "EMP-2025-0002",
    position_title: "Director",
    employment_type: "permanent",
  },
  {
    id: "5d659675-2041-4733-80af-e157fafcb3f5",
    status: "active",
    exit_date: null,
    full_name: "Employee D",
    join_date: "2025-04-01",
    department: null,
    employee_code: "EMP-2025-0003",
    position_title: "Clerk",
    employment_type: "permanent",
  },
  {
    id: "4801cab3-f4a2-469a-90c5-fde9fdf5af2c",
    status: "active",
    exit_date: null,
    full_name: "Employee E",
    join_date: "2025-08-01",
    department: null,
    employee_code: "EMP-2025-0004",
    position_title: "Clerk",
    employment_type: "permanent",
  },
];

const historySample: unknown = [
  {
    note: null,
    department: null,
    effective_from: "2025-03-01",
    position_title: "Staff",
    employment_type: "permanent",
  },
];

const compensationSample: unknown = {
  as_of: "2026-09-21",
  components: [
    {
      kind: "earning",
      label: "Gaji pokok",
      amount: "5000000",
      taxable: true,
      bpjs_base: true,
      component: "basic",
      effective_from: "2025-03-01",
    },
    {
      kind: "earning",
      label: "Uang makan",
      amount: "600000",
      taxable: true,
      bpjs_base: false,
      component: "meal",
      effective_from: "2025-03-01",
    },
    {
      kind: "earning",
      label: "Transport",
      amount: "300000",
      taxable: false,
      bpjs_base: false,
      component: "transport",
      effective_from: "2025-03-01",
    },
  ],
  earnings_total: "5900000",
  deductions_total: "0",
};

const bpjsSample: unknown = {
  as_of: "2026-09-21",
  enrolled: [
    {
      rate_key: null,
      component: "bpjs_jht",
      member_ref: null,
      effective_from: "2025-03-01",
    },
    {
      rate_key: "grade_1",
      component: "bpjs_jkk",
      member_ref: null,
      effective_from: "2025-03-01",
    },
    {
      rate_key: null,
      component: "bpjs_jkm",
      member_ref: null,
      effective_from: "2025-03-01",
    },
    {
      rate_key: null,
      component: "bpjs_jp",
      member_ref: null,
      effective_from: "2025-03-01",
    },
    {
      rate_key: null,
      component: "bpjs_kes",
      member_ref: null,
      effective_from: "2025-03-01",
    },
  ],
};

const taxProfileSample: unknown = {
  note: null,
  recorded: true,
  tax_method: "employee_borne",
  ptkp_status: "TK/0",
  tax_id_masked: "************0001",
  tax_id_status: "has_tax_id",
  effective_from: "2025-03-01",
};

const taxProfileNoneSample: unknown = {
  recorded: false,
};

const runListSample: unknown = [
  {
    run_id: "f1788409-038e-4dea-848e-d52eea69e41c",
    status: "partially_paid",
    net_paid: "3000000.0000",
    pay_date: "2025-07-25",
    revision: 1,
    bpjs_paid: "300000.0000",
    journal_id: "de8bd044-c9c0-4311-b466-c2f5ddb1348c",
    period_end: "2025-07-31",
    run_number: "PR-2025-0001",
    pph21_total: "313314.0000",
    period_start: "2025-07-01",
    review_count: 0,
    net_pay_total: "21616865.0000",
    employee_count: 3,
    corrects_run_id: null,
    gross_pay_total: "21900000.0000",
    employee_bpjs_total: "200000.0000",
    employer_bpjs_total: "512000.0000",
    tax_allowance_total: "230179.0000",
  },
];

const runGetSample: unknown = {
  note: null,
  rules: [
    {
      code: "BPJS_JHT",
      rule_version: 1,
      effective_from: "2015-07-01",
    },
    {
      code: "BPJS_JKK",
      rule_version: 1,
      effective_from: "2015-07-01",
    },
    {
      code: "BPJS_JKM",
      rule_version: 1,
      effective_from: "2015-07-01",
    },
    {
      code: "BPJS_JP",
      rule_version: 1,
      effective_from: "2025-03-01",
    },
    {
      code: "BPJS_KES",
      rule_version: 1,
      effective_from: "2020-07-01",
    },
    {
      code: "PPH21_ANNUAL",
      rule_version: 1,
      effective_from: "2024-01-01",
    },
    {
      code: "PPH21_TER",
      rule_version: 1,
      effective_from: "2024-01-01",
    },
  ],
  stale: false,
  run_id: "f1788409-038e-4dea-848e-d52eea69e41c",
  status: "partially_paid",
  net_paid: "3000000.0000",
  pay_date: "2025-07-25",
  revision: 1,
  bpjs_paid: "300000.0000",
  closed_at: null,
  posted_at: "2026-09-21T22:56:43.618902+08:00",
  journal_id: "de8bd044-c9c0-4311-b466-c2f5ddb1348c",
  period_end: "2025-07-31",
  run_number: "PR-2025-0001",
  approved_at: "2026-09-21T22:56:43.618902+08:00",
  differences: [],
  pph21_total: "313314.0000",
  calc_version: 1,
  corrected_at: null,
  period_start: "2025-07-01",
  posting_date: "2025-07-31",
  review_count: 0,
  submitted_at: "2026-09-21T22:56:43.618902+08:00",
  calculated_at: "2026-09-21T22:56:43.618902+08:00",
  net_pay_total: "21616865.0000",
  employee_count: 3,
  tax_base_total: "21827000.0000",
  corrects_run_id: null,
  gross_pay_total: "21900000.0000",
  correction_reason: null,
  employee_bpjs_total: "200000.0000",
  employer_bpjs_total: "512000.0000",
  reversal_journal_id: null,
  tax_allowance_total: "230179.0000",
};

const runLinesSample: unknown = [
  {
    pph21: "29135.0000",
    line_id: "8c1e4cf4-9369-4319-832e-099373702307",
    net_pay: "5670865.0000",
    net_paid: "3000000.0000",
    tax_base: "5827000.0000",
    tax_calc: {
      base: "5827000",
      mode: "ter",
      rate: "0.005",
      rule: "c0044fa0-19c9-4255-81d9-664d561c5125",
      gross: "5827000",
      method: "employee_borne",
      category: "A",
      no_tax_id: false,
    },
    tax_mode: "ter",
    gross_pay: "5900000.0000",
    info_flags: [],
    tax_method: "employee_borne",
    employee_id: "1881b64d-fcc5-4278-8988-52faca019625",
    review_flags: [],
    bpjs_employee: "200000.0000",
    bpjs_employer: "512000.0000",
    employee_code: "EMP-2025-0001",
    employee_name: "Employee A",
    tax_allowance: "0.0000",
    bpjs_wage_base: "5000000.0000",
    earnings_total: "5900000.0000",
    reductions_total: "0.0000",
    adjustment_earnings: "0.0000",
    adjustment_deductions: "0.0000",
  },
  {
    pph21: "230179.0000",
    line_id: "a11c08d1-2b78-4bb3-bcb8-1c8143efc085",
    net_pay: "10000000.0000",
    net_paid: "0",
    tax_base: "10000000.0000",
    tax_calc: {
      base: "10230179",
      mode: "ter",
      rate: "0.0225",
      rule: "c0044fa0-19c9-4255-81d9-664d561c5125",
      gross: "10230179",
      method: "gross_up",
      category: "A",
      no_tax_id: false,
    },
    tax_mode: "ter",
    gross_pay: "10000000.0000",
    info_flags: [],
    tax_method: "gross_up",
    employee_id: "d88d148a-9ce0-4dde-b696-75b25d4c6eb4",
    review_flags: [],
    bpjs_employee: "0.0000",
    bpjs_employer: "0.0000",
    employee_code: "EMP-2025-0002",
    employee_name: "Employee C",
    tax_allowance: "230179.0000",
    bpjs_wage_base: "0.0000",
    earnings_total: "10000000.0000",
    reductions_total: "0.0000",
    adjustment_earnings: "0.0000",
    adjustment_deductions: "0.0000",
  },
  {
    pph21: "54000.0000",
    line_id: "737c4fc1-1ad7-4d04-9cbd-b385d72de0d3",
    net_pay: "5946000.0000",
    net_paid: "0",
    tax_base: "6000000.0000",
    tax_calc: {
      base: "6000000",
      mode: "ter",
      rate: "0.0075",
      rule: "c0044fa0-19c9-4255-81d9-664d561c5125",
      gross: "6000000",
      method: "employee_borne",
      category: "A",
      no_tax_id: true,
    },
    tax_mode: "ter",
    gross_pay: "6000000.0000",
    info_flags: [],
    tax_method: "employee_borne",
    employee_id: "5d659675-2041-4733-80af-e157fafcb3f5",
    review_flags: [],
    bpjs_employee: "0.0000",
    bpjs_employer: "0.0000",
    employee_code: "EMP-2025-0003",
    employee_name: "Employee D",
    tax_allowance: "0.0000",
    bpjs_wage_base: "0.0000",
    earnings_total: "6000000.0000",
    reductions_total: "0.0000",
    adjustment_earnings: "0.0000",
    adjustment_deductions: "0.0000",
  },
];

const paymentsSample: unknown = [
  {
    kind: "bpjs",
    amount: "300000.0000",
    status: "confirmed",
    reference: null,
    journal_id: "0ae138e6-6f61-44b6-82fd-72a7da8e8c10",
    payment_id: "9fe56ba3-415d-485a-93d7-f222155cd6a5",
    payment_date: "2025-08-05",
    payment_number: "PYP-2025-0002",
    reversal_journal_id: null,
    financial_account_id: "daa74b7a-8212-4eaa-92f0-eb73cd5e79bd",
  },
  {
    kind: "net_pay",
    amount: "3000000.0000",
    status: "confirmed",
    reference: null,
    journal_id: "63611e02-b113-4244-9e0e-4f84b43f124f",
    payment_id: "4b6be8d1-4cdf-4b87-91f4-6bd6d29ada60",
    payment_date: "2025-08-01",
    payment_number: "PYP-2025-0001",
    reversal_journal_id: null,
    financial_account_id: "daa74b7a-8212-4eaa-92f0-eb73cd5e79bd",
  },
];

const payslipListSample: unknown = [
  {
    period: "2025-07",
    run_id: "f1788409-038e-4dea-848e-d52eea69e41c",
    status: "issued",
    net_pay: "10000000",
    issued_at: "2026-09-21T22:56:43.618902+08:00",
    payslip_id: "c6bbdb8e-db6f-4373-80c9-f072d9eb6be5",
    employee_id: "d88d148a-9ce0-4dde-b696-75b25d4c6eb4",
    employee_code: "EMP-2025-0002",
    employee_name: "Employee C",
    payslip_number: "PSL-2025-0003",
  },
  {
    period: "2025-07",
    run_id: "f1788409-038e-4dea-848e-d52eea69e41c",
    status: "issued",
    net_pay: "5946000",
    issued_at: "2026-09-21T22:56:43.618902+08:00",
    payslip_id: "aea5db60-a897-4eb0-8629-78222fea1f1e",
    employee_id: "5d659675-2041-4733-80af-e157fafcb3f5",
    employee_code: "EMP-2025-0003",
    employee_name: "Employee D",
    payslip_number: "PSL-2025-0002",
  },
  {
    period: "2025-07",
    run_id: "f1788409-038e-4dea-848e-d52eea69e41c",
    status: "issued",
    net_pay: "5670865",
    issued_at: "2026-09-21T22:56:43.618902+08:00",
    payslip_id: "784281ee-ddba-436a-8498-662efe5ba66e",
    employee_id: "1881b64d-fcc5-4278-8988-52faca019625",
    employee_code: "EMP-2025-0001",
    employee_name: "Employee A",
    payslip_number: "PSL-2025-0001",
  },
];

const payslipGetSample: unknown = {
  tax: {
    base: "10000000",
    mode: "ter",
    pph21: "230179",
    method: "gross_up",
    allowance: "230179",
    withheld_from_employee: "0",
  },
  period: "2025-07",
  status: "issued",
  net_pay: "10000000",
  employee: {
    id: "d88d148a-9ce0-4dde-b696-75b25d4c6eb4",
    code: "EMP-2025-0002",
    name: "Employee C",
  },
  net_paid: "0",
  pay_date: "2025-07-25",
  revision: 1,
  gross_pay: "10000000",
  issued_at: "2026-09-21T22:56:43.618902+08:00",
  voided_at: null,
  components: [
    {
      code: "basic",
      kind: "earning",
      label: "Gaji pokok",
      amount: "10000000",
      taxable: true,
      bpjs_base: false,
    },
  ],
  run_number: "PR-2025-0001",
  adjustments: [],
  void_reason: null,
  bpjs_employee: {
    jp: "0",
    jht: "0",
    kes: "0",
  },
  bpjs_employer: {
    jp: "0",
    jht: "0",
    jkk: "0",
    jkm: "0",
    kes: "0",
  },
  earnings_total: "10000000",
  payslip_number: "PSL-2025-0003",
  reductions_total: "0",
  adjustment_earnings: "0",
  adjustment_deductions: "0",
};

const ledgerSample: unknown = [
  {
    pph21: "29135.0000",
    source: "run",
    tax_base: "5827000.0000",
    tax_mode: "ter",
    run_number: "PR-2025-0001",
    tax_period: "2025-07-01",
    employee_id: "1881b64d-fcc5-4278-8988-52faca019625",
    employee_code: "EMP-2025-0001",
    employee_name: "Employee A",
    tax_allowance: "0.0000",
    pension_deduction: "150000.0000",
  },
  {
    pph21: "230179.0000",
    source: "run",
    tax_base: "10000000.0000",
    tax_mode: "ter",
    run_number: "PR-2025-0001",
    tax_period: "2025-07-01",
    employee_id: "d88d148a-9ce0-4dde-b696-75b25d4c6eb4",
    employee_code: "EMP-2025-0002",
    employee_name: "Employee C",
    tax_allowance: "230179.0000",
    pension_deduction: "0.0000",
  },
  {
    pph21: "54000.0000",
    source: "run",
    tax_base: "6000000.0000",
    tax_mode: "ter",
    run_number: "PR-2025-0001",
    tax_period: "2025-07-01",
    employee_id: "5d659675-2041-4733-80af-e157fafcb3f5",
    employee_code: "EMP-2025-0003",
    employee_name: "Employee D",
    tax_allowance: "0.0000",
    pension_deduction: "0.0000",
  },
];

const annualSample: unknown = [
  {
    status: "over_withheld",
    withheld: "29135",
    annual_tax: "0",
    difference: "-29135",
    employee_id: "1881b64d-fcc5-4278-8988-52faca019625",
    gross_income: "5827000",
    employee_code: "EMP-2025-0001",
    employee_name: "Employee A",
    months_worked: 10,
  },
  {
    status: "over_withheld",
    withheld: "230179",
    annual_tax: "0",
    difference: "-230179",
    employee_id: "d88d148a-9ce0-4dde-b696-75b25d4c6eb4",
    gross_income: "10230179",
    employee_code: "EMP-2025-0002",
    employee_name: "Employee C",
    months_worked: 7,
  },
  {
    status: "over_withheld",
    withheld: "54000",
    annual_tax: "0",
    difference: "-54000",
    employee_id: "5d659675-2041-4733-80af-e157fafcb3f5",
    gross_income: "6000000",
    employee_code: "EMP-2025-0003",
    employee_name: "Employee D",
    months_worked: 9,
  },
  {
    status: "incomplete",
    withheld: "0",
    annual_tax: null,
    difference: null,
    employee_id: "4801cab3-f4a2-469a-90c5-fde9fdf5af2c",
    gross_income: "0",
    employee_code: "EMP-2025-0004",
    employee_name: "Employee E",
    months_worked: 5,
  },
];

const summarySample: unknown = [
  {
    pph21: "313314.0000",
    run_id: "f1788409-038e-4dea-848e-d52eea69e41c",
    status: "partially_paid",
    net_pay: "21616865.0000",
    revision: 1,
    gross_pay: "21900000.0000",
    net_unpaid: "18616865.0000",
    run_number: "PR-2025-0001",
    bpjs_unpaid: "412000.0000",
    period_start: "2025-07-01",
    employee_bpjs: "200000.0000",
    employer_bpjs: "512000.0000",
    tax_allowance: "230179.0000",
    employee_count: 3,
    pph21_period_outstanding: "213314.0000",
  },
];

const liabilitySample: unknown = [
  {
    owed: "712000.0000",
    paid: "300000.0000",
    liability: "bpjs",
    run_number: "PR-2025-0001",
    outstanding: "412000.0000",
    period_start: "2025-07-01",
  },
  {
    owed: "21616865.0000",
    paid: "3000000.0000",
    liability: "net_pay",
    run_number: "PR-2025-0001",
    outstanding: "18616865.0000",
    period_start: "2025-07-01",
  },
  {
    owed: "313314.0000",
    paid: "100000.0000",
    liability: "pph21",
    run_number: null,
    outstanding: "213314.0000",
    period_start: "2025-07-01",
  },
];

const controlSample: unknown = [
  {
    difference: "0.0000",
    sub_ledger: "18616865.0000",
    account_key: "PAYROLL_LIABILITY",
    ledger_other: "0.0000",
    ledger_total: "18616865.0000",
    ledger_workflow: "18616865.0000",
  },
  {
    difference: "0.0000",
    sub_ledger: "412000.0000",
    account_key: "BPJS_LIABILITY",
    ledger_other: "0.0000",
    ledger_total: "412000.0000",
    ledger_workflow: "412000.0000",
  },
];

describe("outputs match what the database returns", () => {
  it("employees and their records", () => {
    expect(employeeListSchema.parse(employeeListSample)).toHaveLength(4);
    expect(employmentHistorySchema.parse(historySample)).toHaveLength(1);
    expect(compensationSchema.parse(compensationSample).components).toHaveLength(3);
    expect(bpjsEnrolmentSchema.parse(bpjsSample).enrolled).toHaveLength(5);
  });

  it("the tax profile is masked, and 'not recorded' is its own shape", () => {
    const profile = taxProfileSchema.parse(taxProfileSample);
    expect(profile.recorded).toBe(true);
    if (profile.recorded) expect(profile.tax_id_masked).toMatch(/^\*+\d{4}$/);
    expect(taxProfileSchema.parse(taxProfileNoneSample)).toEqual({ recorded: false });
  });

  it("the run list, the run and its lines", () => {
    expect(payrollRunListSchema.parse(runListSample)).toHaveLength(1);
    const run = payrollRunDetailSchema.parse(runGetSample);
    expect(run.status).toBe("partially_paid");
    expect(run.stale).toBe(false);
    expect(payrollLinesSchema.parse(runLinesSample)).toHaveLength(3);
    expect(payrollAdjustmentsSchema.parse([])).toEqual([]);
  });

  it("a person without payroll.tax_view sees null tax figures", () => {
    const run = payrollRunDetailSchema.parse({
      ...(runGetSample as object),
      tax_allowance_total: null,
      pph21_total: null,
      tax_base_total: null,
    });
    expect(run.pph21_total).toBeNull();
    const lines = payrollLinesSchema.parse(
      (runLinesSample as Record<string, unknown>[]).map((l) => ({
        ...l,
        tax_base: null,
        tax_mode: null,
        tax_method: null,
        pph21: null,
        tax_allowance: null,
        tax_calc: null,
      })),
    );
    expect(lines[0]?.pph21).toBeNull();
  });

  it("payments, payslips and the tax section of a payslip", () => {
    expect(payrollPaymentsSchema.parse(paymentsSample)).toHaveLength(2);
    expect(payslipListSchema.parse(payslipListSample)).toHaveLength(3);
    const slip = payslipDetailSchema.parse(payslipGetSample);
    expect(slip.tax?.pph21).toMatch(/^\d+$/);
    const withoutTax = { ...(payslipGetSample as Record<string, unknown>) };
    delete withoutTax.tax;
    expect(payslipDetailSchema.parse(withoutTax).tax).toBeUndefined();
  });

  it("the reports", () => {
    expect(taxLedgerSchema.parse(ledgerSample)).toHaveLength(3);
    const annual = annualReconciliationSchema.parse(annualSample);
    expect(annual.some((r) => r.status === "incomplete" && r.annual_tax === null)).toBe(true);
    expect(payrollSummarySchema.parse(summarySample)).toHaveLength(1);
    expect(payrollLiabilitySchema.parse(liabilitySample)).toHaveLength(3);
    expect(payrollControlSchema.parse(controlSample)).toHaveLength(2);
  });

  it("rejects an amount that is not decimal text", () => {
    const bad = (runListSample as Record<string, unknown>[]).map((r) => ({
      ...r,
      net_pay_total: 21616865,
    }));
    expect(payrollRunListSchema.safeParse(bad).success).toBe(false);
  });
});

describe("employee inputs", () => {
  it("creates an employee with a name, a join date, a type and a position", () => {
    const base = {
      entity_id: ENTITY,
      idempotency_key: KEY,
      full_name: "Employee A",
      join_date: "2025-03-01",
      employment_type: "permanent" as const,
      position_title: "Staff",
    };
    expect(createEmployeeInputSchema.safeParse(base).success).toBe(true);
    expect(createEmployeeInputSchema.safeParse({ ...base, full_name: "A" }).success).toBe(false);
    expect(
      createEmployeeInputSchema.safeParse({ ...base, employment_type: "intern" }).success,
    ).toBe(false);
    expect(createEmployeeInputSchema.safeParse({ ...base, idempotency_key: "short" }).success).toBe(
      false,
    );
  });

  it("compensation is 1 to 30 distinct components; only an earning can be the BPJS base", () => {
    const item = {
      component: "Basic",
      kind: "earning" as const,
      label: "Gaji pokok",
      amount: "5000000",
      bpjs_base: true,
    };
    const base = {
      employee_id: EMPLOYEE,
      idempotency_key: KEY,
      effective_from: "2025-03-01",
      items: [item],
    };
    const ok = setCompensationInputSchema.parse(base);
    expect(ok.items[0]?.component).toBe("basic");
    expect(setCompensationInputSchema.safeParse({ ...base, items: [] }).success).toBe(false);
    expect(setCompensationInputSchema.safeParse({ ...base, items: [item, item] }).success).toBe(
      false,
    );
    expect(
      setCompensationInputSchema.safeParse({
        ...base,
        items: [{ ...item, kind: "deduction" }],
      }).success,
    ).toBe(false);
    expect(
      setCompensationInputSchema.safeParse({
        ...base,
        items: [{ ...item, amount: "-5" }],
      }).success,
    ).toBe(false);
  });

  it("a tax number is required exactly when the status is has_tax_id", () => {
    const base = {
      employee_id: EMPLOYEE,
      idempotency_key: KEY,
      effective_from: "2025-03-01",
      ptkp_status: "TK/0" as const,
    };
    expect(
      setTaxProfileInputSchema.safeParse({
        ...base,
        tax_id_status: "has_tax_id",
        tax_id: "3200.0000.0000.0001",
      }).success,
    ).toBe(true);
    expect(
      setTaxProfileInputSchema.safeParse({ ...base, tax_id_status: "has_tax_id" }).success,
    ).toBe(false);
    expect(
      setTaxProfileInputSchema.safeParse({ ...base, tax_id_status: "has_tax_id", tax_id: "123" })
        .success,
    ).toBe(false);
    expect(
      setTaxProfileInputSchema.safeParse({
        ...base,
        tax_id_status: "no_tax_id",
        tax_id: "3200000000000001",
      }).success,
    ).toBe(false);
    const parsed = setTaxProfileInputSchema.parse({ ...base, tax_id_status: "unknown" });
    expect(parsed.tax_method).toBe("employee_borne");
  });

  it("BPJS enrolment lists each component once", () => {
    const item = { component: "bpjs_jkk" as const, enrolled: true, rate_key: "grade_1" };
    const base = {
      employee_id: EMPLOYEE,
      idempotency_key: KEY,
      effective_from: "2025-03-01",
      items: [item],
    };
    expect(setBpjsInputSchema.safeParse(base).success).toBe(true);
    expect(setBpjsInputSchema.safeParse({ ...base, items: [item, item] }).success).toBe(false);
    expect(
      setBpjsInputSchema.safeParse({ ...base, items: [{ ...item, rate_key: "Grade 1" }] }).success,
    ).toBe(false);
  });

  it("opening tax figures cover months 1 to 11 of a year, with pension defaulting to zero", () => {
    const base = {
      employee_id: EMPLOYEE,
      idempotency_key: KEY,
      tax_year: 2026,
      through_month: 8,
      taxable_gross: "40000000",
      pph21_withheld: "1200000",
    };
    expect(setTaxOpeningInputSchema.parse(base).pension_deduction).toBe("0");
    expect(setTaxOpeningInputSchema.safeParse({ ...base, through_month: 12 }).success).toBe(false);
    expect(setTaxOpeningInputSchema.safeParse({ ...base, through_month: 0 }).success).toBe(false);
  });
});

describe("run inputs", () => {
  it("a payroll month starts on the first day", () => {
    const base = {
      entity_id: ENTITY,
      idempotency_key: KEY,
      period: "2025-07-01",
      pay_date: "2025-07-25",
    };
    expect(createRunInputSchema.safeParse(base).success).toBe(true);
    expect(createRunInputSchema.safeParse({ ...base, period: "2025-07-15" }).success).toBe(false);
  });

  it("an adjustment is a positive amount for a kind", () => {
    const base = {
      run_id: RUN,
      idempotency_key: KEY,
      employee_id: EMPLOYEE,
      kind: "earning" as const,
      label: "Bonus",
      amount: "250000",
    };
    expect(addAdjustmentInputSchema.parse(base).taxable).toBe(true);
    expect(addAdjustmentInputSchema.safeParse({ ...base, amount: "0" }).success).toBe(false);
    expect(addAdjustmentInputSchema.safeParse({ ...base, kind: "bonus" }).success).toBe(false);
  });

  it("a correction needs a date and a reason", () => {
    const base = { run_id: RUN, idempotency_key: KEY, date: "2025-08-31", reason: "Salah tarif" };
    expect(correctRunInputSchema.safeParse(base).success).toBe(true);
    expect(correctRunInputSchema.safeParse({ ...base, reason: "x" }).success).toBe(false);
  });
});

describe("payment inputs", () => {
  const base = {
    run_id: RUN,
    idempotency_key: KEY,
    date: "2025-08-01",
    account_id: ACCOUNT,
  };

  it("BPJS is one amount and never lines", () => {
    expect(
      recordPayrollPaymentInputSchema.safeParse({ ...base, kind: "bpjs", amount: "300000" })
        .success,
    ).toBe(true);
    expect(recordPayrollPaymentInputSchema.safeParse({ ...base, kind: "bpjs" }).success).toBe(
      false,
    );
    expect(
      recordPayrollPaymentInputSchema.safeParse({
        ...base,
        kind: "bpjs",
        amount: "300000",
        lines: [{ employee: EMPLOYEE, amount: "1" }],
      }).success,
    ).toBe(false);
  });

  it("net pay is per employee or everything still owed, never an amount", () => {
    expect(recordPayrollPaymentInputSchema.safeParse({ ...base, kind: "net_pay" }).success).toBe(
      true,
    );
    expect(
      recordPayrollPaymentInputSchema.safeParse({
        ...base,
        kind: "net_pay",
        lines: [{ employee: EMPLOYEE, amount: "3000000" }],
      }).success,
    ).toBe(true);
    expect(
      recordPayrollPaymentInputSchema.safeParse({ ...base, kind: "net_pay", amount: "3000000" })
        .success,
    ).toBe(false);
    expect(
      recordPayrollPaymentInputSchema.safeParse({
        ...base,
        kind: "net_pay",
        lines: [
          { employee: EMPLOYEE, amount: "1" },
          { employee: EMPLOYEE, amount: "2" },
        ],
      }).success,
    ).toBe(false);
  });
});
