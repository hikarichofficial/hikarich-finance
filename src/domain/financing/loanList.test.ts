import { describe, expect, it } from "vitest";
import {
  filterLoanRows,
  loanOverdueBadge,
  loanPaymentStatusBadge,
  loanScheduleStateBadge,
  loanStatusBadge,
  loanVersionStatusBadge,
  matchesLoanQuery,
  parseLoanDirectionFilter,
  parseLoanStatusFilter,
} from "./loanList";
import type { LoanRow } from "@/schemas/financing";

function row(overrides: Partial<LoanRow> = {}): LoanRow {
  return {
    loan_id: "11111111-1111-1111-1111-111111111111",
    loan_number: "LN-2026-0001",
    direction: "borrowed",
    status: "active",
    counterparty_name: "Bank Mandiri",
    purpose: "Modal kerja",
    principal: "50000000",
    outstanding: "40000000",
    rate: "12",
    maturity_date: "2027-01-10",
    next_due_date: "2026-10-10",
    next_due_amount: "5000000",
    overdue_amount: null,
    overdue: false,
    term_class: "long",
    asset_id: null,
    related_entity_id: null,
    source_type: "proceeds",
    ...overrides,
  };
}

describe("loanStatusBadge", () => {
  it("labels and tones every status", () => {
    expect(loanStatusBadge("active")).toEqual({ text: "Berjalan", tone: "success" });
    expect(loanStatusBadge("draft").tone).toBe("neutral");
    expect(loanStatusBadge("closed").tone).toBe("neutral");
    expect(loanStatusBadge("cancelled").tone).toBe("critical");
  });
});

describe("loanOverdueBadge", () => {
  it("returns a critical badge when overdue, null otherwise", () => {
    expect(loanOverdueBadge(true)).toEqual({ text: "Terlambat", tone: "critical" });
    expect(loanOverdueBadge(false)).toBeNull();
  });
});

describe("matchesLoanQuery / filterLoanRows", () => {
  it("matches the loan number or counterparty name, case-insensitively", () => {
    expect(matchesLoanQuery(row(), "ln-2026")).toBe(true);
    expect(matchesLoanQuery(row(), "mandiri")).toBe(true);
    expect(matchesLoanQuery(row(), "tidak ada")).toBe(false);
  });

  it("treats an empty query as matching everything", () => {
    expect(matchesLoanQuery(row(), "")).toBe(true);
  });

  it("filters a list down to the matches", () => {
    const rows = [
      row({ loan_id: "1", counterparty_name: "Bank Mandiri" }),
      row({ loan_id: "2", counterparty_name: "Koperasi Sejahtera" }),
    ];
    expect(filterLoanRows(rows, "koperasi").map((r) => r.loan_id)).toEqual(["2"]);
  });
});

describe("parseLoanDirectionFilter / parseLoanStatusFilter", () => {
  it("accepts a listed direction and rejects anything else", () => {
    expect(parseLoanDirectionFilter("borrowed")).toBe("borrowed");
    expect(parseLoanDirectionFilter("lent")).toBe("lent");
    expect(parseLoanDirectionFilter("sideways")).toBeUndefined();
  });

  it("accepts a listed status and rejects anything else", () => {
    expect(parseLoanStatusFilter("active")).toBe("active");
    expect(parseLoanStatusFilter("not_a_status")).toBeUndefined();
  });
});

describe("loanScheduleStateBadge", () => {
  it("labels and tones every schedule state", () => {
    expect(loanScheduleStateBadge("paid", false)).toEqual({ text: "Lunas", tone: "success" });
    expect(loanScheduleStateBadge("partially_paid", false).tone).toBe("attention");
    expect(loanScheduleStateBadge("scheduled", false).tone).toBe("neutral");
  });

  it("shows overdue as critical regardless of the underlying state", () => {
    expect(loanScheduleStateBadge("due", true)).toEqual({ text: "Terlambat", tone: "critical" });
    expect(loanScheduleStateBadge("scheduled", true).tone).toBe("critical");
  });
});

describe("loanVersionStatusBadge", () => {
  it("labels and tones every version status", () => {
    expect(loanVersionStatusBadge("active")).toEqual({ text: "Berlaku", tone: "success" });
    expect(loanVersionStatusBadge("superseded").text).toBe("Digantikan");
    expect(loanVersionStatusBadge("draft").tone).toBe("neutral");
  });
});

describe("loanPaymentStatusBadge", () => {
  it("labels and tones every payment status", () => {
    expect(loanPaymentStatusBadge("active")).toEqual({ text: "Aktif", tone: "success" });
    expect(loanPaymentStatusBadge("reversed")).toEqual({ text: "Dibalik", tone: "attention" });
  });
});
