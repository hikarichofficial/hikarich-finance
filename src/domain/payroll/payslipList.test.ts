import { describe, expect, it } from "vitest";
import {
  PAYSLIP_STATUS_FILTER_OPTIONS,
  filterPayslipRows,
  matchesPayslipQuery,
  matchesPayslipStatus,
  parsePayslipStatusFilter,
  payslipStatusBadge,
} from "./payslipList";
import type { PayslipRow } from "@/schemas/payroll";

function row(overrides: Partial<PayslipRow> = {}): PayslipRow {
  return {
    payslip_id: "11111111-1111-1111-1111-111111111111",
    payslip_number: "PS-2025-07-001",
    status: "issued",
    run_id: "22222222-2222-2222-2222-222222222222",
    employee_id: "33333333-3333-3333-3333-333333333333",
    employee_code: "EMP001",
    employee_name: "Budi Santoso",
    period: "2025-07",
    net_pay: "9500000",
    issued_at: "2025-08-05T00:00:00Z",
    ...overrides,
  };
}

describe("payslipStatusBadge", () => {
  it("returns the Indonesian label and tone for each status", () => {
    expect(payslipStatusBadge("issued")).toEqual({ text: "Diterbitkan", tone: "success" });
    expect(payslipStatusBadge("voided")).toEqual({ text: "Dibatalkan", tone: "neutral" });
  });
});

describe("PAYSLIP_STATUS_FILTER_OPTIONS", () => {
  it("starts with the all-status option and lists both statuses", () => {
    expect(PAYSLIP_STATUS_FILTER_OPTIONS[0]).toEqual({ value: null, label: "Semua Status" });
    expect(PAYSLIP_STATUS_FILTER_OPTIONS).toHaveLength(3);
  });
});

describe("parsePayslipStatusFilter", () => {
  it("parses a known status and treats anything else as no filter", () => {
    expect(parsePayslipStatusFilter("voided")).toBe("voided");
    expect(parsePayslipStatusFilter(undefined)).toBeUndefined();
    expect(parsePayslipStatusFilter("bogus")).toBeUndefined();
  });
});

describe("matchesPayslipStatus", () => {
  it("matches exactly or passes everything when null", () => {
    expect(matchesPayslipStatus(row({ status: "issued" }), "issued")).toBe(true);
    expect(matchesPayslipStatus(row({ status: "issued" }), "voided")).toBe(false);
    expect(matchesPayslipStatus(row(), null)).toBe(true);
  });
});

describe("matchesPayslipQuery", () => {
  it("matches the payslip number, employee code/name and period", () => {
    expect(matchesPayslipQuery(row(), "ps-2025-07")).toBe(true);
    expect(matchesPayslipQuery(row(), "emp001")).toBe(true);
    expect(matchesPayslipQuery(row(), "budi")).toBe(true);
    expect(matchesPayslipQuery(row(), "2025-07")).toBe(true);
    expect(matchesPayslipQuery(row(), "2025-08")).toBe(false);
  });

  it("treats an empty query as matching everything", () => {
    expect(matchesPayslipQuery(row(), "  ")).toBe(true);
  });
});

describe("filterPayslipRows", () => {
  it("combines the status filter and the free-text query", () => {
    const rows = [
      row({ payslip_id: "1", status: "issued", employee_code: "EMP001" }),
      row({ payslip_id: "2", status: "voided", employee_code: "EMP002" }),
    ];
    expect(filterPayslipRows(rows, "issued", "").map((r) => r.payslip_id)).toEqual(["1"]);
    expect(filterPayslipRows(rows, null, "emp002").map((r) => r.payslip_id)).toEqual(["2"]);
  });
});
