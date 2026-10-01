import { describe, expect, it } from "vitest";
import { expenseStatusSchema, type ExpenseRow } from "@/schemas/expenses";
import {
  EXPENSE_STATUS_LABELS,
  EXPENSE_STATUS_TONE,
  expenseActions,
  expensePayeeLabel,
  filterExpenses,
  parseExpenseFilter,
  type ExpensePermissions,
} from "./expenseList";

const ALL: ExpensePermissions = {
  canEdit: true,
  canSubmit: true,
  canPay: true,
  canVoid: true,
  canCreate: true,
};
const NONE: ExpensePermissions = {
  canEdit: false,
  canSubmit: false,
  canPay: false,
  canVoid: false,
  canCreate: false,
};

function row(overrides: Partial<ExpenseRow>): ExpenseRow {
  return {
    id: "0f8fad5b-d9cb-469f-a165-70867728950e",
    status: "draft",
    expense_number: null,
    payee_id: null,
    payee_name: "Toko A",
    receipt_reference: null,
    financial_account_id: "7c9e6679-7425-40de-944b-e07fc1f90ae7",
    currency: "IDR",
    expense_date: "2026-10-01",
    notes: null,
    subtotal: "100.0000",
    tax_total: "0.0000",
    total: "100.0000",
    journal_id: null,
    reversal_journal_id: null,
    reject_reason: null,
    closed_reason: null,
    replaces_expense_id: null,
    replaced_by_expense_id: null,
    created_at: "2026-10-01T00:00:00Z",
    version: 1,
    ...overrides,
  };
}

describe("labels", () => {
  it("covers every status", () => {
    for (const s of expenseStatusSchema.options) {
      expect(EXPENSE_STATUS_LABELS[s]).toBeTruthy();
      expect(EXPENSE_STATUS_TONE[s]).toBeTruthy();
    }
  });
});

describe("expenseActions", () => {
  it("follows the P6 guards for each status with every permission", () => {
    expect(expenseActions("draft", ALL)).toEqual({
      submit: true,
      recall: false,
      reject: false,
      confirm: true,
      cancel: true,
      reverse: false,
      correct: false,
    });
    expect(expenseActions("submitted", ALL)).toEqual({
      submit: false,
      recall: true,
      reject: true,
      confirm: true,
      cancel: true,
      reverse: false,
      correct: false,
    });
    expect(expenseActions("confirmed", ALL)).toMatchObject({
      reverse: true,
      correct: true,
      confirm: false,
      cancel: false,
    });
    for (const s of ["reversed", "cancelled"] as const) {
      expect(Object.values(expenseActions(s, ALL)).some(Boolean)).toBe(false);
    }
  });

  it("offers nothing without permissions", () => {
    for (const s of expenseStatusSchema.options) {
      expect(Object.values(expenseActions(s, NONE)).some(Boolean)).toBe(false);
    }
  });

  it("needs bills.void to cancel a submitted expense but only bills.edit for a draft", () => {
    const editOnly = { ...NONE, canEdit: true };
    expect(expenseActions("draft", editOnly).cancel).toBe(true);
    expect(expenseActions("submitted", editOnly).cancel).toBe(false);
  });

  it("needs both bills.void and bills.create to correct", () => {
    expect(expenseActions("confirmed", { ...NONE, canVoid: true }).correct).toBe(false);
    expect(expenseActions("confirmed", { ...NONE, canVoid: true, canCreate: true }).correct).toBe(
      true,
    );
  });
});

describe("filtering", () => {
  const vendor = "a3bb189e-8bf9-3888-9912-ace4e6543002";
  const names = new Map([[vendor, "PT Vendor"]]);
  const rows = [
    row({ expense_number: "EXP-1", status: "confirmed", payee_name: null, payee_id: vendor }),
    row({ status: "draft", payee_name: "Warung B", receipt_reference: "STRUK-9" }),
  ];

  it("parses known status filters only", () => {
    expect(parseExpenseFilter("confirmed")).toBe("confirmed");
    expect(parseExpenseFilter("constructor")).toBeUndefined();
  });

  it("filters by status and searches number, payee and receipt", () => {
    expect(filterExpenses(rows, "draft", "", names)).toHaveLength(1);
    expect(filterExpenses(rows, undefined, "vendor", names)[0].expense_number).toBe("EXP-1");
    expect(filterExpenses(rows, undefined, "struk", names)[0].payee_name).toBe("Warung B");
  });

  it("labels the payee from the vendor list or the free-text name", () => {
    expect(expensePayeeLabel(rows[0], names)).toBe("PT Vendor");
    expect(expensePayeeLabel(rows[1], names)).toBe("Warung B");
  });
});
