import { describe, expect, it } from "vitest";
import {
  ACCOUNT_CLASS_LABELS,
  ACCOUNT_CLASS_NORMAL_BALANCE,
  BALANCE_SHEET_SECTION_ORDER,
  CASH_FLOW_BUCKET_LABELS,
  CASH_FLOW_BUCKET_ORDER,
  PNL_SECTION_ORDER,
  REPORT_SUBROUTE_TARGETS,
  agingTotals,
  balanceSheetTotals,
  cashFlowTotals,
  consolidatedCashPositionTotals,
  customReportTotals,
  equityClosingTotal,
  equityRowAmounts,
  generalLedgerOpeningBalance,
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
  resolveConsolidatedEntityIds,
  resolveCustomReportDataset,
  resolveGeneralLedgerAccount,
  resolveLoanDueThrough,
  resolveReportRange,
  loanDueTotals,
  loanSummaryTotals,
  payrollSummaryTotals,
  payrollControlAccountLabel,
  payrollControlRowBalanced,
  payrollControlSummary,
  resolveFiscalScheduleAsset,
  fiscalScheduleTotalDepreciation,
  assetControlAccountLabel,
  assetControlRowBalanced,
  assetControlSummary,
  reportSubrouteHref,
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

describe("generalLedgerOpeningBalance", () => {
  it("is the first running balance less the first line's own movement", () => {
    const rows = [
      { debit: "200.0000", credit: "0.0000", running_balance: "1200.0000" },
      { debit: "0.0000", credit: "100.0000", running_balance: "1100.0000" },
    ];
    expect(generalLedgerOpeningBalance(rows, "debit")?.toString()).toBe("1000.0000");
  });

  it("reads a credit-normal account the other way round", () => {
    const rows = [{ debit: "0.0000", credit: "300.0000", running_balance: "800.0000" }];
    expect(generalLedgerOpeningBalance(rows, "credit")?.toString()).toBe("500.0000");
  });

  it("is null when the range has no line", () => {
    expect(generalLedgerOpeningBalance([], "debit")).toBeNull();
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

describe("resolveConsolidatedEntityIds", () => {
  const eligible = [{ entity_id: "pt-1" }, { entity_id: "personal-1" }];

  it("keeps requested ids that are all eligible", () => {
    expect(resolveConsolidatedEntityIds(eligible, ["personal-1"])).toEqual(["personal-1"]);
  });

  it("drops requested ids that are not eligible without failing the whole selection", () => {
    expect(resolveConsolidatedEntityIds(eligible, ["pt-1", "not-eligible"])).toEqual(["pt-1"]);
  });

  it("falls back to every eligible Entity when nothing is requested", () => {
    expect(resolveConsolidatedEntityIds(eligible, [])).toEqual(["pt-1", "personal-1"]);
  });

  it("falls back to every eligible Entity when every requested id was dropped", () => {
    expect(resolveConsolidatedEntityIds(eligible, ["not-eligible"])).toEqual([
      "pt-1",
      "personal-1",
    ]);
  });

  it("returns an empty selection when there is no eligible Entity at all", () => {
    expect(resolveConsolidatedEntityIds([], ["pt-1"])).toEqual([]);
  });
});

describe("consolidatedCashPositionTotals", () => {
  it("sums cash_balance across Entities that share one base currency", () => {
    const rows = [
      { entity_id: "pt-1", cash_balance: "1000000.0000" },
      { entity_id: "personal-1", cash_balance: "250000.0000" },
    ];
    const totals = consolidatedCashPositionTotals(rows, { "pt-1": "IDR", "personal-1": "IDR" });
    expect(totals.entityCount).toBe(2);
    expect(totals.totalCashBalance?.toString()).toBe("1250000.0000");
  });

  it("returns a null total, never a mixed-currency sum, when Entities do not share one base currency", () => {
    const rows = [
      { entity_id: "pt-1", cash_balance: "1000000.0000" },
      { entity_id: "us-1", cash_balance: "500.0000" },
    ];
    const totals = consolidatedCashPositionTotals(rows, { "pt-1": "IDR", "us-1": "USD" });
    expect(totals.entityCount).toBe(2);
    expect(totals.totalCashBalance).toBeNull();
  });

  it("returns a zero total and zero count for no rows", () => {
    const totals = consolidatedCashPositionTotals([], {});
    expect(totals.entityCount).toBe(0);
    expect(totals.totalCashBalance?.toString()).toBe("0");
  });
});

describe("resolveLoanDueThrough", () => {
  const reference = new Date("2026-09-28T12:00:00Z");

  it("falls back to 30 days past reference when missing or invalid", () => {
    expect(resolveLoanDueThrough(undefined, reference)).toBe("2026-10-28");
    expect(resolveLoanDueThrough("not-a-date", reference)).toBe("2026-10-28");
  });

  it("keeps a valid requested date", () => {
    expect(resolveLoanDueThrough("2026-12-31", reference)).toBe("2026-12-31");
  });
});

describe("loanDueTotals", () => {
  it("sums outstanding principal/interest/fee and counts overdue rows", () => {
    const rows = [
      {
        principal_outstanding: "1000000.0000",
        interest_outstanding: "50000.0000",
        fee_outstanding: "10000.0000",
        overdue: true,
      },
      {
        principal_outstanding: "500000.0000",
        interest_outstanding: "20000.0000",
        fee_outstanding: "0.0000",
        overdue: false,
      },
      {
        principal_outstanding: "250000.0000",
        interest_outstanding: "5000.0000",
        fee_outstanding: "0.0000",
        overdue: true,
      },
    ];
    const totals = loanDueTotals(rows);
    expect(totals.principalOutstanding.toString()).toBe("1750000.0000");
    expect(totals.interestOutstanding.toString()).toBe("75000.0000");
    expect(totals.feeOutstanding.toString()).toBe("10000.0000");
    expect(totals.overdueCount).toBe(2);
  });

  it("returns zero totals and a zero overdue count for no rows", () => {
    const totals = loanDueTotals([]);
    expect(totals.principalOutstanding.toString()).toBe("0");
    expect(totals.interestOutstanding.toString()).toBe("0");
    expect(totals.feeOutstanding.toString()).toBe("0");
    expect(totals.overdueCount).toBe(0);
  });
});

describe("loanSummaryTotals", () => {
  it("sums every column across loans", () => {
    const rows = [
      {
        opening_principal: "1000000.0000",
        proceeds: "0.0000",
        principal_repaid: "200000.0000",
        principal_written_off: "0.0000",
        closing_principal: "800000.0000",
        interest_paid: "30000.0000",
        fees_paid: "5000.0000",
      },
      {
        opening_principal: "0.0000",
        proceeds: "500000.0000",
        principal_repaid: "100000.0000",
        principal_written_off: "50000.0000",
        closing_principal: "350000.0000",
        interest_paid: "10000.0000",
        fees_paid: "0.0000",
      },
    ];
    const totals = loanSummaryTotals(rows);
    expect(totals.openingPrincipal.toString()).toBe("1000000.0000");
    expect(totals.proceeds.toString()).toBe("500000.0000");
    expect(totals.principalRepaid.toString()).toBe("300000.0000");
    expect(totals.principalWrittenOff.toString()).toBe("50000.0000");
    expect(totals.closingPrincipal.toString()).toBe("1150000.0000");
    expect(totals.interestPaid.toString()).toBe("40000.0000");
    expect(totals.feesPaid.toString()).toBe("5000.0000");
  });

  it("returns zero totals for no rows", () => {
    const totals = loanSummaryTotals([]);
    expect(totals.openingPrincipal.toString()).toBe("0");
    expect(totals.proceeds.toString()).toBe("0");
    expect(totals.principalRepaid.toString()).toBe("0");
    expect(totals.principalWrittenOff.toString()).toBe("0");
    expect(totals.closingPrincipal.toString()).toBe("0");
    expect(totals.interestPaid.toString()).toBe("0");
    expect(totals.feesPaid.toString()).toBe("0");
  });
});

describe("agingTotals", () => {
  it("sums every bucket across customers/vendors and counts the rows", () => {
    const rows = [
      {
        not_due: "1000000.0000",
        days_1_30: "500000.0000",
        days_31_60: "0.0000",
        days_61_90: "0.0000",
        days_over_90: "0.0000",
        total: "1500000.0000",
      },
      {
        not_due: "0.0000",
        days_1_30: "0.0000",
        days_31_60: "200000.0000",
        days_61_90: "100000.0000",
        days_over_90: "50000.0000",
        total: "350000.0000",
      },
    ];
    const totals = agingTotals(rows);
    expect(totals.notDue.toString()).toBe("1000000.0000");
    expect(totals.days1to30.toString()).toBe("500000.0000");
    expect(totals.days31to60.toString()).toBe("200000.0000");
    expect(totals.days61to90.toString()).toBe("100000.0000");
    expect(totals.daysOver90.toString()).toBe("50000.0000");
    expect(totals.total.toString()).toBe("1850000.0000");
    expect(totals.recordCount).toBe(2);
  });

  it("returns zero totals and a zero count for no rows", () => {
    const totals = agingTotals([]);
    expect(totals.notDue.toString()).toBe("0");
    expect(totals.days1to30.toString()).toBe("0");
    expect(totals.days31to60.toString()).toBe("0");
    expect(totals.days61to90.toString()).toBe("0");
    expect(totals.daysOver90.toString()).toBe("0");
    expect(totals.total.toString()).toBe("0");
    expect(totals.recordCount).toBe(0);
  });
});

describe("payrollSummaryTotals", () => {
  it("sums every non-masked column across runs", () => {
    const rows = [
      {
        gross_pay: "50000000.0000",
        tax_allowance: "1000000.0000",
        employee_bpjs: "2000000.0000",
        employer_bpjs: "3000000.0000",
        pph21: "1500000.0000",
        net_pay: "45000000.0000",
        net_unpaid: "0.0000",
        bpjs_unpaid: "5000000.0000",
        pph21_period_outstanding: "1500000.0000",
      },
      {
        gross_pay: "40000000.0000",
        tax_allowance: "800000.0000",
        employee_bpjs: "1500000.0000",
        employer_bpjs: "2500000.0000",
        pph21: "1000000.0000",
        net_pay: "36000000.0000",
        net_unpaid: "36000000.0000",
        bpjs_unpaid: "0.0000",
        pph21_period_outstanding: null,
      },
    ];
    const totals = payrollSummaryTotals(rows);
    expect(totals.grossPay.toString()).toBe("90000000.0000");
    expect(totals.employeeBpjs.toString()).toBe("3500000.0000");
    expect(totals.employerBpjs.toString()).toBe("5500000.0000");
    expect(totals.netPay.toString()).toBe("81000000.0000");
    expect(totals.netUnpaid.toString()).toBe("36000000.0000");
    expect(totals.bpjsUnpaid.toString()).toBe("5000000.0000");
    expect(totals.taxAllowance?.toString()).toBe("1800000.0000");
    expect(totals.pph21?.toString()).toBe("2500000.0000");
    expect(totals.pph21PeriodOutstanding?.toString()).toBe("1500000.0000");
  });

  it("returns null, not zero, for a masked column that is null on every row", () => {
    const rows = [
      {
        gross_pay: "50000000.0000",
        tax_allowance: null,
        employee_bpjs: "2000000.0000",
        employer_bpjs: "3000000.0000",
        pph21: null,
        net_pay: "45000000.0000",
        net_unpaid: "0.0000",
        bpjs_unpaid: "0.0000",
        pph21_period_outstanding: null,
      },
    ];
    const totals = payrollSummaryTotals(rows);
    expect(totals.taxAllowance).toBeNull();
    expect(totals.pph21).toBeNull();
    expect(totals.pph21PeriodOutstanding).toBeNull();
    expect(totals.grossPay.toString()).toBe("50000000.0000");
  });

  it("returns zero money totals and null masked totals for no rows", () => {
    const totals = payrollSummaryTotals([]);
    expect(totals.grossPay.toString()).toBe("0");
    expect(totals.netPay.toString()).toBe("0");
    expect(totals.taxAllowance).toBeNull();
    expect(totals.pph21).toBeNull();
    expect(totals.pph21PeriodOutstanding).toBeNull();
  });
});

describe("payrollControlAccountLabel", () => {
  it("labels the two known account keys", () => {
    expect(payrollControlAccountLabel("PAYROLL_LIABILITY")).toBe("Utang Gaji Karyawan");
    expect(payrollControlAccountLabel("BPJS_LIABILITY")).toBe("Utang BPJS");
  });

  it("falls back to the raw key for an unrecognized value", () => {
    expect(payrollControlAccountLabel("SOMETHING_ELSE")).toBe("SOMETHING_ELSE");
  });
});

describe("payrollControlSummary", () => {
  it("counts nonzero differences as mismatches", () => {
    const rows = [
      { difference: "0.0000" },
      { difference: "150000.0000" },
      { difference: "-50000.0000" },
    ];
    const summary = payrollControlSummary(rows);
    expect(summary.accountCount).toBe(3);
    expect(summary.mismatchCount).toBe(2);
  });

  it("returns zero counts for no rows", () => {
    const summary = payrollControlSummary([]);
    expect(summary.accountCount).toBe(0);
    expect(summary.mismatchCount).toBe(0);
  });
});

describe("payrollControlRowBalanced", () => {
  it("is true for a zero difference", () => {
    expect(payrollControlRowBalanced({ difference: "0.0000" })).toBe(true);
  });

  it("is false for a nonzero difference, positive or negative", () => {
    expect(payrollControlRowBalanced({ difference: "150000.0000" })).toBe(false);
    expect(payrollControlRowBalanced({ difference: "-50000.0000" })).toBe(false);
  });
});

describe("resolveFiscalScheduleAsset", () => {
  const assets = [{ asset_id: "asset-1" }, { asset_id: "asset-2" }];

  it("keeps a requested id that is a real asset", () => {
    expect(resolveFiscalScheduleAsset(assets, "asset-2")).toBe("asset-2");
  });

  it("falls back to the first asset when nothing valid is requested", () => {
    expect(resolveFiscalScheduleAsset(assets, undefined)).toBe("asset-1");
  });

  it("falls back to the first asset when the requested id is unknown", () => {
    expect(resolveFiscalScheduleAsset(assets, "not-a-real-id")).toBe("asset-1");
  });

  it("returns null when the Entity has no assets at all", () => {
    expect(resolveFiscalScheduleAsset([], undefined)).toBeNull();
  });
});

describe("fiscalScheduleTotalDepreciation", () => {
  it("sums the depreciation column across fiscal years", () => {
    const rows = [
      { depreciation: "1000000.0000" },
      { depreciation: "1000000.0000" },
      { depreciation: "500000.0000" },
    ];
    expect(fiscalScheduleTotalDepreciation(rows).toString()).toBe("2500000.0000");
  });

  it("returns zero for no rows", () => {
    expect(fiscalScheduleTotalDepreciation([]).toString()).toBe("0");
  });
});

describe("assetControlAccountLabel", () => {
  it("labels the two known account keys", () => {
    expect(assetControlAccountLabel("FIXED_ASSET_COST")).toBe("Biaya Perolehan Aset Tetap");
    expect(assetControlAccountLabel("ACCUMULATED_DEPRECIATION")).toBe("Akumulasi Penyusutan");
  });

  it("falls back to the raw key for an unrecognized value", () => {
    expect(assetControlAccountLabel("SOMETHING_ELSE")).toBe("SOMETHING_ELSE");
  });
});

describe("assetControlSummary", () => {
  it("counts nonzero differences as mismatches", () => {
    const rows = [{ difference: "0.0000" }, { difference: "-75000.0000" }];
    const summary = assetControlSummary(rows);
    expect(summary.accountCount).toBe(2);
    expect(summary.mismatchCount).toBe(1);
  });

  it("returns zero counts for no rows", () => {
    const summary = assetControlSummary([]);
    expect(summary.accountCount).toBe(0);
    expect(summary.mismatchCount).toBe(0);
  });
});

describe("assetControlRowBalanced", () => {
  it("is true for a zero difference", () => {
    expect(assetControlRowBalanced({ difference: "0.0000" })).toBe(true);
  });

  it("is false for a nonzero difference", () => {
    expect(assetControlRowBalanced({ difference: "42.0000" })).toBe(false);
  });
});

describe("reportSubrouteHref", () => {
  it("forwards each sub-route to its statement tab", () => {
    expect(reportSubrouteHref("cashflow", undefined)).toBe("/reports?statement=cashflow");
    expect(reportSubrouteHref("payroll", undefined)).toBe("/reports?statement=payroll_summary");
    expect(reportSubrouteHref("custom", undefined)).toBe("/reports?statement=custom");
  });

  it("carries the active Entity code forward, URL-encoded", () => {
    expect(reportSubrouteHref("cashflow", "HKR 01")).toBe(
      "/reports?statement=cashflow&entity=HKR+01",
    );
  });

  // Decision 393: one "Aset & Pinjaman" item that opened fixed-asset control alone is now two items, each
  // landing on the report it is named after.
  it("forwards loans and assets to their own tabs, and tax to the Tax Ledger", () => {
    expect(reportSubrouteHref("loans", undefined)).toBe("/reports?statement=loan_summary");
    expect(reportSubrouteHref("assets", undefined)).toBe("/reports?statement=asset_control");
    expect(reportSubrouteHref("tax", undefined)).toBe("/tax/ledger");
    expect(reportSubrouteHref("tax", "HKR 01")).toBe("/tax/ledger?entity=HKR+01");
  });

  it("maps exactly the six sub-routes with an existing destination", () => {
    expect(Object.keys(REPORT_SUBROUTE_TARGETS).sort()).toEqual([
      "assets",
      "cashflow",
      "custom",
      "loans",
      "payroll",
      "tax",
    ]);
  });
});
