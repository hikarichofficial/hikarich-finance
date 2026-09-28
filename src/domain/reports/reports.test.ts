import { describe, expect, it } from "vitest";
import {
  ACCOUNT_CLASS_LABELS,
  ACCOUNT_CLASS_NORMAL_BALANCE,
  BALANCE_SHEET_SECTION_ORDER,
  CASH_FLOW_BUCKET_LABELS,
  CASH_FLOW_BUCKET_ORDER,
  PNL_SECTION_ORDER,
  balanceSheetTotals,
  cashFlowTotals,
  equityClosingTotal,
  equityRowAmounts,
  groupByAccountClass,
  isFiscalYearClosureActive,
  naturalAmount,
  pnlNetIncome,
  resolveAsOfDate,
  resolveReportRange,
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

describe("resolveReportRange", () => {
  const reference = new Date("2026-09-28T12:00:00Z");

  it("falls back to year-to-date when nothing valid is requested", () => {
    expect(resolveReportRange(undefined, undefined, reference)).toEqual({
      from: "2026-01-01",
      to: "2026-09-28",
    });
  });

  it("falls back to year-to-date when the pair is inverted", () => {
    expect(resolveReportRange("2026-06-01", "2026-01-01", reference)).toEqual({
      from: "2026-01-01",
      to: "2026-09-28",
    });
  });

  it("keeps a valid requested pair", () => {
    expect(resolveReportRange("2026-02-01", "2026-02-28", reference)).toEqual({
      from: "2026-02-01",
      to: "2026-02-28",
    });
  });
});

describe("resolveAsOfDate", () => {
  const reference = new Date("2026-09-28T12:00:00Z");

  it("falls back to today when missing or invalid", () => {
    expect(resolveAsOfDate(undefined, reference)).toBe("2026-09-28");
    expect(resolveAsOfDate("not-a-date", reference)).toBe("2026-09-28");
  });

  it("keeps a valid requested date", () => {
    expect(resolveAsOfDate("2026-03-31", reference)).toBe("2026-03-31");
  });
});

describe("groupByAccountClass", () => {
  const rows = [
    {
      account_id: "a1",
      code: "4000",
      name: "Sales",
      account_class: "revenue" as AccountClass,
      debit: "0.0000",
      credit: "1000.0000",
    },
    {
      account_id: "a2",
      code: "5000",
      name: "Rent",
      account_class: "expense" as AccountClass,
      debit: "300.0000",
      credit: "0.0000",
    },
  ];

  it("groups by class in the given order, skipping empty classes", () => {
    const sections = groupByAccountClass(rows, PNL_SECTION_ORDER);
    expect(sections.map((s) => s.accountClass)).toEqual(["revenue", "expense"]);
    expect(sections[0].label).toBe(ACCOUNT_CLASS_LABELS.revenue);
    expect(sections[0].subtotal.toString()).toBe("1000.0000");
    expect(sections[1].subtotal.toString()).toBe("300.0000");
  });

  it("returns nothing for an order with no matching rows", () => {
    expect(groupByAccountClass(rows, ["asset"])).toEqual([]);
  });
});

describe("pnlNetIncome", () => {
  it("nets income-side classes minus cost-side classes", () => {
    const rows = [
      { debit: "0.0000", credit: "1000.0000", account_class: "revenue" as AccountClass },
      { debit: "0.0000", credit: "200.0000", account_class: "other_income" as AccountClass },
      { debit: "50.0000", credit: "0.0000", account_class: "contra_revenue" as AccountClass },
      { debit: "300.0000", credit: "0.0000", account_class: "expense" as AccountClass },
    ];
    // income 1000 + 200 = 1200; cost 50 + 300 = 350; net 850
    expect(pnlNetIncome(rows).toString()).toBe("850.0000");
  });

  it("nets to a real loss when costs exceed income", () => {
    const rows = [
      { debit: "0.0000", credit: "100.0000", account_class: "revenue" as AccountClass },
      { debit: "500.0000", credit: "0.0000", account_class: "expense" as AccountClass },
    ];
    expect(pnlNetIncome(rows).toString()).toBe("-400.0000");
  });
});

describe("balanceSheetTotals", () => {
  it("agrees when assets equal liabilities plus equity (a balanced ledger)", () => {
    const rows = [
      { debit: "1000.0000", credit: "0.0000", account_class: "asset" as AccountClass },
      { debit: "0.0000", credit: "400.0000", account_class: "liability" as AccountClass },
      { debit: "0.0000", credit: "600.0000", account_class: "equity" as AccountClass },
    ];
    const totals = balanceSheetTotals(rows);
    expect(totals.assets.toString()).toBe("1000.0000");
    expect(totals.liabilitiesAndEquity.toString()).toBe("1000.0000");
    expect(totals.balanced).toBe(true);
  });

  it("flags a genuine mismatch rather than hiding it", () => {
    const rows = [
      { debit: "1000.0000", credit: "0.0000", account_class: "asset" as AccountClass },
      { debit: "0.0000", credit: "400.0000", account_class: "liability" as AccountClass },
    ];
    expect(balanceSheetTotals(rows).balanced).toBe(false);
  });

  it("covers every class BALANCE_SHEET_SECTION_ORDER names", () => {
    expect(BALANCE_SHEET_SECTION_ORDER).toEqual(["asset", "contra_asset", "liability", "equity"]);
  });
});

describe("equityRowAmounts / equityClosingTotal", () => {
  const rows = [
    {
      account_id: "e1",
      code: "3000",
      name: "Owner Capital",
      opening_debit: "0.0000",
      opening_credit: "5000.0000",
      period_debit: "0.0000",
      period_credit: "1000.0000",
      closing_debit: "0.0000",
      closing_credit: "6000.0000",
    },
    {
      account_id: null,
      code: null,
      name: "Net result for the period",
      opening_debit: "0.0000",
      opening_credit: "0.0000",
      period_debit: "0.0000",
      period_credit: "850.0000",
      closing_debit: "0.0000",
      closing_credit: "850.0000",
    },
  ];

  it("nets each column credit minus debit (equity is credit-normal)", () => {
    const amounts = equityRowAmounts(rows[0]);
    expect(amounts.opening.toString()).toBe("5000.0000");
    expect(amounts.period.toString()).toBe("1000.0000");
    expect(amounts.closing.toString()).toBe("6000.0000");
  });

  it("totals closing across every row, including the computed net-result row", () => {
    expect(equityClosingTotal(rows).toString()).toBe("6850.0000");
  });
});

describe("cashFlowTotals", () => {
  it("reconciles opening + flows to closing when the RPC's own buckets already agree", () => {
    const rows = [
      { bucket: "opening_cash" as const, amount: "1000.0000" },
      { bucket: "operating" as const, amount: "500.0000" },
      { bucket: "investing" as const, amount: "-200.0000" },
      { bucket: "financing" as const, amount: "100.0000" },
      { bucket: "closing_cash" as const, amount: "1400.0000" },
    ];
    const totals = cashFlowTotals(rows);
    expect(totals.reconciled).toBe(true);
    expect(totals.closing.toString()).toBe("1400.0000");
  });

  it("treats a bucket missing from the result as zero rather than throwing", () => {
    const rows = [
      { bucket: "opening_cash" as const, amount: "1000.0000" },
      { bucket: "closing_cash" as const, amount: "1000.0000" },
    ];
    const totals = cashFlowTotals(rows);
    expect(totals.operating.toString()).toBe("0");
    expect(totals.reconciled).toBe(true);
  });

  it("flags a genuine mismatch rather than hiding it", () => {
    const rows = [
      { bucket: "opening_cash" as const, amount: "1000.0000" },
      { bucket: "operating" as const, amount: "500.0000" },
      { bucket: "closing_cash" as const, amount: "1000.0000" },
    ];
    expect(cashFlowTotals(rows).reconciled).toBe(false);
  });
});
