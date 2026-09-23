import { describe, expect, it } from "vitest";
import {
  ACCOUNT_CLASS_LABELS,
  ACCOUNT_CLASS_NORMAL_BALANCE,
  CASH_FLOW_BUCKET_LABELS,
  CASH_FLOW_BUCKET_ORDER,
  isFiscalYearClosureActive,
  naturalAmount,
  type AccountClass,
} from "./reports";

const ALL_ACCOUNT_CLASSES: AccountClass[] = [
  "asset",
  "contra_asset",
  "liability",
  "equity",
  "revenue",
  "contra_revenue",
  "expense",
  "other_income",
  "other_expense",
  "other",
  "tax",
  "special",
];

describe("ACCOUNT_CLASS_NORMAL_BALANCE / ACCOUNT_CLASS_LABELS completeness", () => {
  it("covers every account_class the database's check constraint allows, with no extras", () => {
    expect(Object.keys(ACCOUNT_CLASS_NORMAL_BALANCE).sort()).toEqual(
      [...ALL_ACCOUNT_CLASSES].sort(),
    );
    expect(Object.keys(ACCOUNT_CLASS_LABELS).sort()).toEqual([...ALL_ACCOUNT_CLASSES].sort());
  });

  it("matches the exact COA-provisioning case (20260919100500_p1_accounting_core.sql)", () => {
    const debitNormal: AccountClass[] = [
      "asset",
      "expense",
      "other_expense",
      "other",
      "tax",
      "special",
      "contra_revenue",
    ];
    const creditNormal: AccountClass[] = [
      "contra_asset",
      "liability",
      "equity",
      "revenue",
      "other_income",
    ];
    for (const cls of debitNormal) expect(ACCOUNT_CLASS_NORMAL_BALANCE[cls]).toBe("debit");
    for (const cls of creditNormal) expect(ACCOUNT_CLASS_NORMAL_BALANCE[cls]).toBe("credit");
  });
});

describe("naturalAmount", () => {
  it("a debit-normal account (asset) nets debit minus credit", () => {
    expect(naturalAmount("1000.0000", "200.0000", "asset").toString()).toBe("800.0000");
  });

  it("a credit-normal account (liability) nets credit minus debit", () => {
    expect(naturalAmount("100.0000", "500.0000", "liability").toString()).toBe("400.0000");
  });

  it("a contra_asset (credit-normal) flips relative to a plain asset", () => {
    expect(naturalAmount("100.0000", "500.0000", "contra_asset").toString()).toBe("400.0000");
  });

  it("a contra_revenue (debit-normal) flips relative to plain revenue", () => {
    expect(naturalAmount("300.0000", "50.0000", "contra_revenue").toString()).toBe("250.0000");
    expect(naturalAmount("300.0000", "50.0000", "revenue").toString()).toBe("-250.0000");
  });

  it("an account running the 'wrong way' returns a real negative, never clamped", () => {
    // an asset with more credit than debit posted against it (e.g. an overdrawn account)
    expect(naturalAmount("200.0000", "900.0000", "asset").toString()).toBe("-700.0000");
  });

  it("zero movement nets to zero", () => {
    expect(naturalAmount("0.0000", "0.0000", "expense").toString()).toBe("0.0000");
  });
});

describe("CASH_FLOW_BUCKET_LABELS / CASH_FLOW_BUCKET_ORDER", () => {
  it("the order contains exactly the labelled buckets, opening first and closing last", () => {
    expect(new Set(CASH_FLOW_BUCKET_ORDER)).toEqual(new Set(Object.keys(CASH_FLOW_BUCKET_LABELS)));
    expect(CASH_FLOW_BUCKET_ORDER[0]).toBe("opening_cash");
    expect(CASH_FLOW_BUCKET_ORDER[CASH_FLOW_BUCKET_ORDER.length - 1]).toBe("closing_cash");
  });
});

describe("isFiscalYearClosureActive", () => {
  it("is active when never reversed", () => {
    expect(isFiscalYearClosureActive({ reversed_at: null })).toBe(true);
  });

  it("is inactive once a reversal timestamp is recorded", () => {
    expect(isFiscalYearClosureActive({ reversed_at: "2026-07-01T00:00:00Z" })).toBe(false);
  });
});
