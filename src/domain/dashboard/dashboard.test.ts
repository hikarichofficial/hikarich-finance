import { describe, expect, it } from "vitest";
import type { CashFlowRow, EquityChangeRow, ProfitAndLossRow } from "@/schemas/reports";
import type { ArAgingRow } from "@/schemas/sales";
import type { MoneyControlRow, ReconciliationStatusRow } from "@/schemas/money";
import type { TaxCalendarRow, ReviewQueueRow } from "@/schemas/tax";
import type { MissingEvidenceRow } from "@/schemas/purchases";
import {
  activeCashBalance,
  agingSummary,
  buildAttentionItems,
  closingCashFromCashFlowRows,
  mergeRecentActivity,
  netResultFromEquityRows,
  pnlTotals,
  reconciliationsNeedingAttention,
  resolveDashboardPeriod,
  trailingMonths,
  upcomingTaxDeadlines,
} from "./dashboard";

function equityRow(overrides: Partial<EquityChangeRow>): EquityChangeRow {
  return {
    account_id: null,
    code: null,
    name: "Row",
    opening_debit: "0",
    opening_credit: "0",
    period_debit: "0",
    period_credit: "0",
    closing_debit: "0",
    closing_credit: "0",
    ...overrides,
  } as EquityChangeRow;
}

describe("netResultFromEquityRows", () => {
  it("reads the synthetic net-result row in equity (credit-normal) direction", () => {
    const rows = [
      equityRow({ code: "3-1000", name: "Modal", period_debit: "0", period_credit: "1000000" }),
      equityRow({
        code: null,
        name: "Net result for the period",
        period_debit: "200000",
        period_credit: "950000",
      }),
    ];
    const net = netResultFromEquityRows(rows);
    expect(net?.toString()).toBe("750000");
  });

  it("is negative when the period ran at a loss (debit exceeds credit)", () => {
    const rows = [
      equityRow({
        code: null,
        name: "Net result for the period",
        period_debit: "900000",
        period_credit: "300000",
      }),
    ];
    expect(netResultFromEquityRows(rows)?.toString()).toBe("-600000");
  });

  it("returns null when the row is absent rather than defaulting to zero", () => {
    const rows = [equityRow({ code: "3-1000", name: "Modal" })];
    expect(netResultFromEquityRows(rows)).toBeNull();
  });
});

describe("resolveDashboardPeriod", () => {
  it("defaults to the reference date's calendar month", () => {
    const period = resolveDashboardPeriod(undefined, new Date(Date.UTC(2026, 8, 23)));
    expect(period).toEqual({ month: "2026-09", start: "2026-09-01", end: "2026-09-30" });
  });

  it("uses a valid requested month, spanning the full calendar month including a leap February", () => {
    const period = resolveDashboardPeriod("2028-02", new Date(Date.UTC(2026, 8, 23)));
    expect(period).toEqual({ month: "2028-02", start: "2028-02-01", end: "2028-02-29" });
  });

  it("falls back to the reference month when the requested value is malformed", () => {
    const period = resolveDashboardPeriod("not-a-month", new Date(Date.UTC(2026, 8, 23)));
    expect(period.month).toBe("2026-09");
  });
});

describe("trailingMonths", () => {
  it("returns the trailing N months oldest-first, including the given period", () => {
    const period = resolveDashboardPeriod("2026-09", new Date());
    const months = trailingMonths(period, 6).map((p) => p.month);
    expect(months).toEqual(["2026-04", "2026-05", "2026-06", "2026-07", "2026-08", "2026-09"]);
  });

  it("crosses a year boundary correctly", () => {
    const period = resolveDashboardPeriod("2026-02", new Date());
    const months = trailingMonths(period, 3).map((p) => p.month);
    expect(months).toEqual(["2025-12", "2026-01", "2026-02"]);
  });
});

describe("closingCashFromCashFlowRows", () => {
  it("reads the closing_cash bucket", () => {
    const rows: CashFlowRow[] = [
      { bucket: "opening_cash", amount: "1000000" },
      { bucket: "operating", amount: "200000" },
      { bucket: "investing", amount: "0" },
      { bucket: "financing", amount: "0" },
      { bucket: "closing_cash", amount: "1200000" },
    ];
    expect(closingCashFromCashFlowRows(rows)?.toString()).toBe("1200000");
  });

  it("returns null when the bucket is absent", () => {
    expect(closingCashFromCashFlowRows([])).toBeNull();
  });
});

describe("pnlTotals", () => {
  function plRow(overrides: Partial<ProfitAndLossRow>): ProfitAndLossRow {
    return {
      account_id: "00000000-0000-0000-0000-000000000001",
      code: "4-1000",
      name: "Row",
      account_class: "revenue",
      parent_id: null,
      debit: "0",
      credit: "0",
      compare_debit: null,
      compare_credit: null,
      ...overrides,
    } as ProfitAndLossRow;
  }

  it("sums revenue and other_income as positive, expense and other_expense as positive", () => {
    const rows = [
      plRow({ account_class: "revenue", debit: "0", credit: "5000000" }),
      plRow({ account_class: "other_income", debit: "0", credit: "100000" }),
      plRow({ account_class: "expense", debit: "3000000", credit: "0" }),
      plRow({ account_class: "other_expense", debit: "50000", credit: "0" }),
      plRow({ account_class: "asset", debit: "10", credit: "0" }),
    ];
    const totals = pnlTotals(rows);
    expect(totals.revenue.toString()).toBe("5100000");
    expect(totals.expense.toString()).toBe("3050000");
  });

  it("returns zero totals for an empty period", () => {
    const totals = pnlTotals([]);
    expect(totals.revenue.isZero()).toBe(true);
    expect(totals.expense.isZero()).toBe(true);
  });
});

describe("agingSummary", () => {
  function arRow(overrides: Partial<ArAgingRow>): ArAgingRow {
    return {
      customer_id: "00000000-0000-0000-0000-000000000001",
      customer_name: "Customer",
      not_due: "0",
      days_1_30: "0",
      days_31_60: "0",
      days_61_90: "0",
      days_over_90: "0",
      total: "0",
      invoice_count: 1,
      ...overrides,
    } as ArAgingRow;
  }

  it("totals every bucket, and overdue as every bucket except not_due", () => {
    const rows = [
      arRow({ not_due: "100000", days_1_30: "20000", total: "120000" }),
      arRow({ days_31_60: "5000", days_over_90: "1000", total: "6000" }),
    ];
    const summary = agingSummary(rows);
    expect(summary.total.toString()).toBe("126000");
    expect(summary.overdue.toString()).toBe("26000");
  });
});

describe("activeCashBalance", () => {
  function accountRow(overrides: Partial<MoneyControlRow>): MoneyControlRow {
    return {
      financial_account_id: "00000000-0000-0000-0000-000000000001",
      name: "Bank",
      kind: "bank",
      currency: "IDR",
      is_active: true,
      movement_balance: "0",
      movement_base_balance: "0",
      ledger_balance: "0",
      difference: "0",
      is_negative: false,
      ...overrides,
    } as MoneyControlRow;
  }

  it("sums only active accounts, in base currency", () => {
    const rows = [
      accountRow({ is_active: true, movement_base_balance: "1000000" }),
      accountRow({ is_active: true, movement_base_balance: "500000" }),
      accountRow({ is_active: false, movement_base_balance: "999999999" }),
    ];
    expect(activeCashBalance(rows).toString()).toBe("1500000");
  });
});

describe("upcomingTaxDeadlines", () => {
  function calRow(overrides: Partial<TaxCalendarRow>): TaxCalendarRow {
    return {
      tax_type: "vat",
      tax_period: "2026-09-01",
      step: "pay",
      due_date: "2026-10-15",
      state: "upcoming",
      outstanding: null,
      rule_code: null,
      rule_version: null,
      detail: null,
      ...overrides,
    } as TaxCalendarRow;
  }

  it("drops done/not_applicable/no_rule rows and rows without a due date", () => {
    const rows = [
      calRow({ state: "done" }),
      calRow({ state: "not_applicable" }),
      calRow({ state: "no_rule" }),
      calRow({ state: "upcoming", due_date: null }),
      calRow({ state: "due", due_date: "2026-09-25" }),
    ];
    const result = upcomingTaxDeadlines(rows);
    expect(result).toHaveLength(1);
    expect(result[0].state).toBe("due");
  });

  it("orders overdue before due before upcoming, then by nearest due date", () => {
    const rows = [
      calRow({ state: "upcoming", due_date: "2026-10-15", rule_code: "A" }),
      calRow({ state: "overdue", due_date: "2026-09-10", rule_code: "B" }),
      calRow({ state: "due", due_date: "2026-09-22", rule_code: "C" }),
      calRow({ state: "overdue", due_date: "2026-09-05", rule_code: "D" }),
    ];
    const result = upcomingTaxDeadlines(rows);
    expect(result.map((r) => r.rule_code)).toEqual(["D", "B", "C", "A"]);
  });

  it("respects the limit", () => {
    const rows = Array.from({ length: 10 }, (_, i) =>
      calRow({ state: "upcoming", due_date: `2026-10-${String(i + 1).padStart(2, "0")}` }),
    );
    expect(upcomingTaxDeadlines(rows, 3)).toHaveLength(3);
  });
});

describe("reconciliationsNeedingAttention", () => {
  function recRow(overrides: Partial<ReconciliationStatusRow>): ReconciliationStatusRow {
    return {
      financial_account_id: "00000000-0000-0000-0000-000000000001",
      name: "Bank",
      last_reconciled_until: null,
      last_statement_closing: null,
      session_in_progress: false,
      unresolved_lines: 0,
      outstanding_movements: 0,
      last_difference: null,
      ...overrides,
    } as ReconciliationStatusRow;
  }

  it("flags accounts with an open session or unresolved lines, not clean ones", () => {
    const rows = [
      recRow({ name: "Clean", session_in_progress: false, unresolved_lines: 0 }),
      recRow({ name: "Open session", session_in_progress: true }),
      recRow({ name: "Unresolved", unresolved_lines: 2 }),
    ];
    const result = reconciliationsNeedingAttention(rows);
    expect(result.map((r) => r.name)).toEqual(["Open session", "Unresolved"]);
  });
});

describe("buildAttentionItems", () => {
  function reviewRow(overrides: Partial<ReviewQueueRow>): ReviewQueueRow {
    return {
      source_type: "invoice",
      source_id: "00000000-0000-0000-0000-000000000001",
      reference: "INV-001",
      event_date: "2026-09-20",
      status: "needs_review",
      reasons: ["Beda tarif"],
      ...overrides,
    } as ReviewQueueRow;
  }
  function evidenceRow(overrides: Partial<MissingEvidenceRow>): MissingEvidenceRow {
    return {
      doc_kind: "bill",
      doc_id: "00000000-0000-0000-0000-000000000002",
      doc_number: "BILL-001",
      doc_date: "2026-09-18",
      party_name: "Vendor A",
      currency: "IDR",
      total: "500000",
      ...overrides,
    } as MissingEvidenceRow;
  }
  function recRow(overrides: Partial<ReconciliationStatusRow>): ReconciliationStatusRow {
    return {
      financial_account_id: "00000000-0000-0000-0000-000000000003",
      name: "Bank BCA",
      last_reconciled_until: "2026-09-19",
      last_statement_closing: null,
      session_in_progress: true,
      unresolved_lines: 0,
      outstanding_movements: 0,
      last_difference: null,
      ...overrides,
    } as ReconciliationStatusRow;
  }

  it("merges all three sources and sorts newest date first", () => {
    const items = buildAttentionItems({
      taxReviewQueue: [reviewRow({ event_date: "2026-09-20" })],
      missingEvidence: [evidenceRow({ doc_date: "2026-09-22" })],
      staleReconciliations: [recRow({ last_reconciled_until: "2026-09-19" })],
    });
    expect(items.map((i) => i.kind)).toEqual(["missing_evidence", "tax_review", "reconciliation"]);
  });

  it("labels an open reconciliation session distinctly from unresolved lines", () => {
    const items = buildAttentionItems({
      taxReviewQueue: [],
      missingEvidence: [],
      staleReconciliations: [
        recRow({ session_in_progress: true, unresolved_lines: 0 }),
        recRow({ financial_account_id: "x", session_in_progress: false, unresolved_lines: 3 }),
      ],
    });
    expect(items[0].detail).toContain("belum diselesaikan");
    expect(items[1].detail).toContain("3 baris");
  });
});

describe("mergeRecentActivity", () => {
  it("only includes confirmed payments and issued invoices, newest first, limited", () => {
    const items = mergeRecentActivity(
      {
        customerPayments: [
          {
            payment_id: "p1",
            payment_number: "PMT-1",
            status: "confirmed",
            payment_date: "2026-09-20",
            customer_id: "c1",
            customer_name: "Toko A",
            currency: "IDR",
            amount: "100000",
            allocated_amount: "100000",
            advance_remaining: null,
            refunded: "0",
            refundable: "0",
            refund_status: "none",
            reference: null,
          },
          {
            payment_id: "p2",
            payment_number: "PMT-2",
            status: "reversed",
            payment_date: "2026-09-21",
            customer_id: "c1",
            customer_name: "Toko A",
            currency: "IDR",
            amount: "50000",
            allocated_amount: "0",
            advance_remaining: null,
            refunded: "0",
            refundable: "0",
            refund_status: "none",
            reference: null,
          },
        ] as never,
        vendorPayments: [
          {
            payment_id: "v1",
            payment_number: "VPMT-1",
            status: "confirmed",
            payment_date: "2026-09-22",
            vendor_id: "vd1",
            vendor_name: "Supplier B",
            currency: "IDR",
            amount: "80000",
            base_amount: "80000",
            fx_difference: "0",
            reference: null,
            bill_count: 1,
          },
        ] as never,
        issuedInvoices: [
          {
            invoice_id: "i1",
            invoice_number: "INV-001",
            customer_id: "c1",
            customer_name: "Toko A",
            currency: "IDR",
            status: "issued",
            issue_date: "2026-09-23",
            due_date: "2026-10-23",
            total: "200000",
            settled: "0",
            outstanding: "200000",
            base_outstanding: "200000",
            refunded: "0",
            settlement_status: "unpaid",
            refund_status: null,
            is_overdue: false,
            days_overdue: 0,
          },
          {
            invoice_id: "i2",
            invoice_number: "INV-002",
            customer_id: "c1",
            customer_name: "Toko A",
            currency: "IDR",
            status: "draft",
            issue_date: "2026-09-23",
            due_date: "2026-10-23",
            total: "999999",
            settled: "0",
            outstanding: "999999",
            base_outstanding: "999999",
            refunded: "0",
            settlement_status: null,
            refund_status: null,
            is_overdue: false,
            days_overdue: 0,
          },
        ] as never,
      },
      5,
    );
    expect(items.map((i) => i.id)).toEqual(["i1", "v1", "p1"]);
  });

  it("respects the limit", () => {
    const customerPayments = Array.from({ length: 10 }, (_, i) => ({
      payment_id: `p${i}`,
      payment_number: `PMT-${i}`,
      status: "confirmed",
      payment_date: `2026-09-${String(i + 1).padStart(2, "0")}`,
      customer_id: "c1",
      customer_name: "Toko A",
      currency: "IDR",
      amount: "1000",
      allocated_amount: "1000",
      advance_remaining: null,
      refunded: "0",
      refundable: "0",
      refund_status: "none",
      reference: null,
    })) as never;
    const items = mergeRecentActivity(
      { customerPayments, vendorPayments: [], issuedInvoices: [] },
      3,
    );
    expect(items).toHaveLength(3);
  });
});
