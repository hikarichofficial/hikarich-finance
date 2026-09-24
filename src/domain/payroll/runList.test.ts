import { describe, expect, it } from "vitest";
import {
  PAYROLL_RUN_STATUS_FILTER_OPTIONS,
  filterPayrollRunRows,
  matchesPayrollRunQuery,
  parsePayrollRunStatusFilter,
  payrollRunPaymentStatusBadge,
  payrollRunStatusBadge,
} from "./runList";
import type { PayrollRunRow } from "@/schemas/payroll";

function row(overrides: Partial<PayrollRunRow> = {}): PayrollRunRow {
  return {
    run_id: "11111111-1111-1111-1111-111111111111",
    run_number: "PR-2025-07",
    revision: 1,
    period_start: "2025-07-01",
    period_end: "2025-07-31",
    pay_date: "2025-08-05",
    status: "draft",
    corrects_run_id: null,
    journal_id: null,
    employee_count: 5,
    review_count: 0,
    gross_pay_total: "50000000",
    tax_allowance_total: "0",
    employee_bpjs_total: "1000000",
    employer_bpjs_total: "2000000",
    pph21_total: "1500000",
    net_pay_total: "47500000",
    net_paid: "0",
    bpjs_paid: "0",
    ...overrides,
  };
}

describe("payrollRunStatusBadge", () => {
  it("returns the Indonesian label and tone for each status", () => {
    expect(payrollRunStatusBadge("draft")).toEqual({ text: "Draf", tone: "neutral" });
    expect(payrollRunStatusBadge("calculated").tone).toBe("progress");
    expect(payrollRunStatusBadge("submitted").tone).toBe("progress");
    expect(payrollRunStatusBadge("approved").tone).toBe("progress");
    expect(payrollRunStatusBadge("posted")).toEqual({ text: "Terposting", tone: "success" });
    expect(payrollRunStatusBadge("partially_paid").tone).toBe("progress");
    expect(payrollRunStatusBadge("paid").tone).toBe("success");
    expect(payrollRunStatusBadge("closed").tone).toBe("success");
    expect(payrollRunStatusBadge("corrected").tone).toBe("attention");
    expect(payrollRunStatusBadge("discarded")).toEqual({ text: "Dibuang", tone: "critical" });
  });
});

describe("payrollRunPaymentStatusBadge", () => {
  it("returns the Indonesian label and tone for each payment status", () => {
    expect(payrollRunPaymentStatusBadge("confirmed")).toEqual({
      text: "Terkonfirmasi",
      tone: "success",
    });
    expect(payrollRunPaymentStatusBadge("reversed")).toEqual({
      text: "Dibalik",
      tone: "attention",
    });
  });
});

describe("PAYROLL_RUN_STATUS_FILTER_OPTIONS", () => {
  it("starts with the all-status option and lists all ten statuses", () => {
    expect(PAYROLL_RUN_STATUS_FILTER_OPTIONS[0]).toEqual({ value: null, label: "Semua Status" });
    expect(PAYROLL_RUN_STATUS_FILTER_OPTIONS).toHaveLength(11);
  });
});

describe("parsePayrollRunStatusFilter", () => {
  it("parses a known status and treats anything else as no filter", () => {
    expect(parsePayrollRunStatusFilter("posted")).toBe("posted");
    expect(parsePayrollRunStatusFilter(undefined)).toBeUndefined();
    expect(parsePayrollRunStatusFilter("bogus")).toBeUndefined();
  });
});

describe("matchesPayrollRunQuery", () => {
  it("matches the run number case-insensitively", () => {
    expect(matchesPayrollRunQuery(row({ run_number: "PR-2025-07" }), "pr-2025")).toBe(true);
    expect(matchesPayrollRunQuery(row({ run_number: "PR-2025-07" }), "pr-2025-08")).toBe(false);
  });

  it("matches the Indonesian period name", () => {
    expect(matchesPayrollRunQuery(row({ period_start: "2025-07-01" }), "juli")).toBe(true);
    expect(matchesPayrollRunQuery(row({ period_start: "2025-07-01" }), "agustus")).toBe(false);
  });

  it("treats an empty query as matching everything", () => {
    expect(matchesPayrollRunQuery(row(), "  ")).toBe(true);
  });
});

describe("filterPayrollRunRows", () => {
  it("filters by the free-text query only", () => {
    const rows = [
      row({ run_id: "1", run_number: "PR-2025-07" }),
      row({ run_id: "2", run_number: "PR-2025-08", period_start: "2025-08-01" }),
    ];
    expect(filterPayrollRunRows(rows, "2025-08").map((r) => r.run_id)).toEqual(["2"]);
    expect(filterPayrollRunRows(rows, "").map((r) => r.run_id)).toEqual(["1", "2"]);
  });
});
