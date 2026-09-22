import { describe, expect, it } from "vitest";
import {
  createBudgetInputSchema,
  createRecurringRuleInputSchema,
  createRevenueTargetInputSchema,
  pauseRecurringRuleInputSchema,
  setBudgetLinesInputSchema,
  setRevenueTargetLinesInputSchema,
} from "./planning";

const ENTITY = "0b2f6d0e-6d2e-4a55-9c58-3f6f3c1d7a01";
const CUSTOMER = "0b2f6d0e-6d2e-4a55-9c58-3f6f3c1d7a02";
const CATEGORY = "0b2f6d0e-6d2e-4a55-9c58-3f6f3c1d7a03";
const KEY = "key-planning-0001";

describe("recurring rules", () => {
  const invoiceTemplate = {
    customer_id: CUSTOMER,
    lines: [{ description: "Retainer bulanan", unit_price: "5000000" }],
  };

  it("accepts a monthly invoice rule with a valid template", () => {
    const result = createRecurringRuleInputSchema.safeParse({
      entity_id: ENTITY,
      idempotency_key: KEY,
      kind: "invoice",
      label: "Retainer klien A",
      frequency: "monthly",
      start_date: "2027-01-31",
      template: invoiceTemplate,
    });
    expect(result.success).toBe(true);
  });

  it("rejects a template with no lines", () => {
    const result = createRecurringRuleInputSchema.safeParse({
      entity_id: ENTITY,
      idempotency_key: KEY,
      kind: "invoice",
      label: "Retainer klien A",
      frequency: "monthly",
      start_date: "2027-01-31",
      template: { customer_id: CUSTOMER, lines: [] },
    });
    expect(result.success).toBe(false);
  });

  it("an expense template needs a payee id or name", () => {
    const withoutPayee = {
      account_id: CUSTOMER,
      lines: [{ description: "Sewa kantor", unit_price: "3000000" }],
    };
    expect(
      createRecurringRuleInputSchema.safeParse({
        entity_id: ENTITY,
        idempotency_key: KEY,
        kind: "expense",
        label: "Sewa bulanan",
        frequency: "monthly",
        start_date: "2027-01-01",
        template: withoutPayee,
      }).success,
    ).toBe(false);
  });

  it("pausing requires a reason of at least 5 characters", () => {
    expect(
      pauseRecurringRuleInputSchema.safeParse({ rule_id: ENTITY, reason: "stop" }).success,
    ).toBe(false);
    expect(
      pauseRecurringRuleInputSchema.safeParse({ rule_id: ENTITY, reason: "client paused" }).success,
    ).toBe(true);
  });
});

describe("budgets", () => {
  it("rejects an end date before the start date", () => {
    const result = createBudgetInputSchema.safeParse({
      entity_id: ENTITY,
      idempotency_key: KEY,
      name: "Anggaran 2027",
      period_type: "annual",
      start_date: "2027-01-01",
      end_date: "2026-12-01",
    });
    expect(result.success).toBe(false);
  });

  it("accepts a valid budget line grid", () => {
    const result = setBudgetLinesInputSchema.safeParse({
      budget_id: ENTITY,
      lines: [{ category_id: CATEGORY, period_month: "2027-01-01", budgeted_amount: "1000000" }],
    });
    expect(result.success).toBe(true);
  });

  it("rejects a period_month that is not the first of the month", () => {
    const result = setBudgetLinesInputSchema.safeParse({
      budget_id: ENTITY,
      lines: [{ category_id: CATEGORY, period_month: "2027-01-15", budgeted_amount: "1000000" }],
    });
    expect(result.success).toBe(false);
  });
});

describe("revenue targets", () => {
  it("accepts a monthly breakdown", () => {
    const result = createRevenueTargetInputSchema.safeParse({
      entity_id: ENTITY,
      idempotency_key: KEY,
      name: "Target 2027",
      period_type: "annual",
      start_date: "2027-01-01",
      end_date: "2027-12-31",
    });
    expect(result.success).toBe(true);
  });

  it("rejects more than 120 monthly lines", () => {
    const lines = Array.from({ length: 121 }, (_, i) => ({
      period_month: "2027-01-01",
      target_amount: String(i),
    }));
    expect(setRevenueTargetLinesInputSchema.safeParse({ target_id: ENTITY, lines }).success).toBe(
      false,
    );
  });
});
