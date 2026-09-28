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
  customReportTotals,
  equityClosingTotal,
  equityRowAmounts,
  generalLedgerTotals,
  groupByAccountClass,
  hasPnlComparison,
  isFiscalYearClosureActive,
  naturalAmount,
  pnlCompareAmount,
  pnlCompareNetIncome,
  pnlCompareSubtotal,
  pnlNetIncome,
  resolveAsOfDate,
  resolveCompareRange,
  resolveCustomReportDataset,
  resolveGeneralLedgerAccount,
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

describe("resolveCompareRange", () => {
  it("returns undefined when nothing is requested", () => {
    expect(resolveCompareRange(undefined, undefined)).toBeUndefined();
  });

  it("returns undefined when only one side of the pair is given", () => {
    expect(resolveCompareRange("2026-01-01", undefined)).toBeUndefined();
    expect(resolveCompareRange(undefined, "2026-01-31")).toBeUndefined();
  });

  it("returns undefined for an invalid date", () => {
    expect(resolveCompareRange("not-a-date", "2026-01-31")).toBeUndefined();
  });

  it("returns undefined for an inverted pair", () => {
    expect(resolveCompareRange("2026-02-01", "2026-01-01")).toBeUndefined();
  });

  it("keeps a valid requested pair", () => {
    expect(resolveCompareRange("2025-01-01", "2025-12-31")).toEqual({
      from: "2025-01-01",
      to: "2025-12-31",
    });
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

describe("hasPnlComparison / pnlCompareAmount / pnlCompareSubtotal / pnlCompareNetIncome", () => {
  const withCompare = [
    {
      debit: "0.0000",
      credit: "1000.0000",
      compare_debit: "0.0000",
      compare_credit: "800.0000",
      account_class: "revenue" as AccountClass,
    },
    {
      debit: "300.0000",
      credit: "0.0000",
      compare_debit: "250.0000",
      compare_credit: "0.0000",
      account_class: "expense" as AccountClass,
    },
  ];
  const withoutCompare = [
    {
      debit: "0.0000",
      credit: "1000.0000",
      compare_debit: null,
      compare_credit: null,
      account_class: "revenue" as AccountClass,
    },
  ];

  it("hasPnlComparison reads true only when compare_debit is present", () => {
    expect(hasPnlComparison(withCompare)).toBe(true);
    expect(hasPnlComparison(withoutCompare)).toBe(false);
    expect(hasPnlComparison([])).toBe(false);
  });

  it("pnlCompareAmount is null when the row carries no comparison figures", () => {
    expect(pnlCompareAmount(withoutCompare[0])?.toString()).toBeUndefined();
    expect(pnlCompareAmount(withCompare[0])?.toString()).toBe("800.0000");
    expect(pnlCompareAmount(withCompare[1])?.toString()).toBe("250.0000");
  });

  it("pnlCompareSubtotal sums a homogeneous set of rows, null when none carry a comparison", () => {
    expect(pnlCompareSubtotal([withCompare[0]])?.toString()).toBe("800.0000");
    expect(pnlCompareSubtotal(withoutCompare)).toBeNull();
  });

  it("pnlCompareNetIncome nets income minus cost for the comparison period, null when none", () => {
    // compare income 800; compare cost 250; net 550
    expect(pnlCompareNetIncome(withCompare)?.toString()).toBe("550.0000");
    expect(pnlCompareNetIncome(withoutCompare)).toBeNull();
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

describe("resolveGeneralLedgerAccount", () => {
  const accounts = [
    { id: "group-1", is_group: true },
    { id: "acc-1", is_group: false },
    { id: "acc-2", is_group: false },
  ];

  it("keeps a requested id that is a real posting account", () => {
    expect(resolveGeneralLedgerAccount(accounts, "acc-2")).toBe("acc-2");
  });

  it("falls back to the first posting account when nothing valid is requested", () => {
    expect(resolveGeneralLedgerAccount(accounts, undefined)).toBe("acc-1");
  });

  it("falls back to the first posting account when the requested id is a group account", () => {
    expect(resolveGeneralLedgerAccount(accounts, "group-1")).toBe("acc-1");
  });

  it("falls back to the first posting account when the requested id is unknown", () => {
    expect(resolveGeneralLedgerAccount(accounts, "not-a-real-id")).toBe("acc-1");
  });

  it("returns null when the Entity has no posting account at all", () => {
    expect(resolveGeneralLedgerAccount([{ id: "group-1", is_group: true }], undefined)).toBeNull();
    expect(resolveGeneralLedgerAccount([], undefined)).toBeNull();
  });
});

describe("generalLedgerTotals", () => {
  it("sums debit/credit and takes the last row's own running_balance as the closing balance", () => {
    const rows = [
      { debit: "1000.0000", credit: "0.0000", running_balance: "1000.0000" },
      { debit: "0.0000", credit: "300.0000", running_balance: "700.0000" },
      { debit: "200.0000", credit: "0.0000", running_balance: "900.0000" },
    ];
    const totals = generalLedgerTotals(rows);
    expect(totals.debit.toString()).toBe("1200.0000");
    expect(totals.credit.toString()).toBe("300.0000");
    expect(totals.closingBalance.toString()).toBe("900.0000");
  });

  it("returns zero totals and a zero closing balance for no rows", () => {
    const totals = generalLedgerTotals([]);
    expect(totals.debit.toString()).toBe("0");
    expect(totals.credit.toString()).toBe("0");
    expect(totals.closingBalance.toString()).toBe("0");
  });
});

describe("resolveCustomReportDataset", () => {
  const datasets = [
    { dataset_key: "invoices_by_customer" },
    { dataset_key: "bills_by_vendor" },
    { dataset_key: "expenses_by_payee" },
  ];

  it("keeps a requested key that is a dataset the caller may run", () => {
    expect(resolveCustomReportDataset(datasets, "bills_by_vendor")).toBe("bills_by_vendor");
  });

  it("falls back to the first available dataset when nothing valid is requested", () => {
    expect(resolveCustomReportDataset(datasets, undefined)).toBe("invoices_by_customer");
  });

  it("falls back to the first available dataset when the requested key is unknown", () => {
    expect(resolveCustomReportDataset(datasets, "not_a_real_dataset")).toBe("invoices_by_customer");
  });

  it("falls back to the first available dataset when the requested key was filtered out for lacking permission", () => {
    const permitted = datasets.filter((d) => d.dataset_key !== "invoices_by_customer");
    expect(resolveCustomReportDataset(permitted, "invoices_by_customer")).toBe("bills_by_vendor");
  });

  it("returns null when the caller may run no dataset at all", () => {
    expect(resolveCustomReportDataset([], undefined)).toBeNull();
  });
});

describe("customReportTotals", () => {
  it("sums row_count and total_amount across every dimension row", () => {
    const rows = [
      { dimension: "Acme Corp", row_count: 3, total_amount: "1500.0000" },
      { dimension: "Beta Ltd", row_count: 2, total_amount: "800.5000" },
    ];
    const totals = customReportTotals(rows);
    expect(totals.rowCount).toBe(5);
    expect(totals.totalAmount.toString()).toBe("2300.5000");
  });

  it("returns a zero grand total for no rows", () => {
    const totals = customReportTotals([]);
    expect(totals.rowCount).toBe(0);
    expect(totals.totalAmount.toString()).toBe("0");
  });
});
