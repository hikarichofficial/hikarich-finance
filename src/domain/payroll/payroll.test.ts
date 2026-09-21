import { describe, expect, it } from "vitest";
import { Decimal } from "@/domain/money/decimal";
import {
  BPJS_COMPONENT_LABELS,
  PAYROLL_STATUS_LABELS,
  PTKP_STATUSES,
  describePayrollFlag,
  expectedNetPay,
  isInfoFlag,
  netOutstanding,
  payrollIsEditable,
  payrollIsPayable,
  payrollNextActions,
  payrollPeriodLabel,
  payrollPeriodName,
  terCategory,
  type PayrollStatus,
} from "./payroll";

describe("PTKP status and TER category", () => {
  it("maps each PTKP status to its PMK 168/2023 category", () => {
    expect(terCategory("TK/0")).toBe("A");
    expect(terCategory("TK/1")).toBe("A");
    expect(terCategory("K/0")).toBe("A");
    expect(terCategory("TK/2")).toBe("B");
    expect(terCategory("TK/3")).toBe("B");
    expect(terCategory("K/1")).toBe("B");
    expect(terCategory("K/2")).toBe("B");
    expect(terCategory("K/3")).toBe("C");
  });

  it("has no category for an unknown status, and every status is listed once", () => {
    expect(terCategory("unknown")).toBeNull();
    expect(new Set(PTKP_STATUSES).size).toBe(PTKP_STATUSES.length);
  });
});

describe("the run as a screen sees it", () => {
  const all = Object.keys(PAYROLL_STATUS_LABELS) as PayrollStatus[];

  it("labels every status", () => {
    for (const status of all) expect(PAYROLL_STATUS_LABELS[status].length).toBeGreaterThan(0);
  });

  it("edits only a draft or calculated run, and pays only a posted, partly or fully paid one", () => {
    expect(all.filter(payrollIsEditable)).toEqual(["draft", "calculated"]);
    expect(all.filter(payrollIsPayable)).toEqual(["posted", "partially_paid", "paid"]);
  });

  it("offers the next actions that follow the workflow", () => {
    expect(payrollNextActions("draft")).toContain("calculate");
    expect(payrollNextActions("calculated")).toContain("submit");
    expect(payrollNextActions("submitted")).toEqual(["return", "approve"]);
    expect(payrollNextActions("approved")).toContain("post");
    expect(payrollNextActions("partially_paid")).toContain("pay");
    expect(payrollNextActions("closed")).toEqual(["reopen"]);
    expect(payrollNextActions("corrected")).toEqual([]);
    expect(payrollNextActions("discarded")).toEqual([]);
  });
});

describe("flags", () => {
  it("explains a known flag", () => {
    expect(describePayrollFlag("tax_facts_missing")).toMatch(/NPWP/);
    expect(describePayrollFlag("negative_net_pay")).toMatch(/negatif/);
  });

  it("names the BPJS component of a valued flag", () => {
    expect(describePayrollFlag("no_bpjs_rule:bpjs_jp")).toContain(BPJS_COMPONENT_LABELS.bpjs_jp);
    expect(describePayrollFlag("bpjs_rate_option_missing:bpjs_jkk")).toContain(
      BPJS_COMPONENT_LABELS.bpjs_jkk,
    );
  });

  it("shows the over-withheld amount and marks it as information only", () => {
    expect(describePayrollFlag("tax_overwithheld:29135")).toContain("29135");
    expect(isInfoFlag("tax_overwithheld:29135")).toBe(true);
    expect(isInfoFlag("tax_facts_missing")).toBe(false);
  });

  it("shows an unknown flag as it came, so nothing the database says is hidden", () => {
    expect(describePayrollFlag("something_new:1")).toBe("something_new:1");
  });
});

describe("payslip arithmetic", () => {
  it("net pay is gross less employee BPJS less the tax the employee bears", () => {
    // Employee A of the P9 fixtures: 5,900,000 - 200,000 - 29,135 = 5,670,865.
    const net = expectedNetPay({
      gross_pay: "5900000",
      bpjs_employee: "200000",
      pph21: "29135",
      tax_allowance: "0",
    });
    expect(net.toString()).toBe("5670865");
  });

  it("in a gross-up the allowance cancels the withholding so the employee bears no tax", () => {
    const net = expectedNetPay({
      gross_pay: "10000000",
      bpjs_employee: "0",
      pph21: "230179",
      tax_allowance: "230179",
    });
    expect(net.toString()).toBe("10000000");
  });

  it("computes what is still owed on a line exactly", () => {
    const owed = netOutstanding({ net_pay: "5670865.0000", net_paid: "3000000" });
    expect(owed.eq(Decimal.parse("2670865"))).toBe(true);
    expect(owed.toFixed(2)).toBe("2670865.00");
  });
});

describe("period labels", () => {
  it("shows the month of a period", () => {
    expect(payrollPeriodLabel("2025-07-01")).toBe("2025-07");
    expect(payrollPeriodName("2025-07-01")).toBe("Juli 2025");
    expect(payrollPeriodName("2026-12")).toBe("Desember 2026");
  });
});
