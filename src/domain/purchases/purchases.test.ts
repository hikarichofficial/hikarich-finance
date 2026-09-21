import { describe, expect, it } from "vitest";
import { Decimal } from "@/domain/money/decimal";
import { preparePurchaseLines, purchaseProblemMessage, type PurchaseLineDraft } from "./bill";
import {
  checkPaymentDate,
  checkVendorPayment,
  paymentDateProblemMessage,
  vendorPaymentProblemMessage,
  type VendorPaymentDraft,
} from "./payment";
import {
  BILL_STATUS_LABELS,
  EXPENSE_STATUS_LABELS,
  billPosition,
  isPreparing,
  outstandingOf,
} from "./settlement";

function prepared(currency: string, lines: PurchaseLineDraft[]) {
  const result = preparePurchaseLines(currency, lines);
  if (!result.ok) throw new Error(`unexpected problem ${result.problem} on line ${result.line}`);
  return result.purchase;
}

function problem(currency: string, lines: PurchaseLineDraft[]) {
  const result = preparePurchaseLines(currency, lines);
  if (result.ok) throw new Error("expected a problem");
  return result;
}

describe("bill and expense lines", () => {
  it("rounds quantity x price once per line, half-up, to the currency's minor unit", () => {
    const purchase = prepared("IDR", [
      { description: "Bahan", quantity: "3", unitPrice: "33333.335" },
    ]);
    expect(purchase.lines[0].lineTotal.toString()).toBe("100000.01");
    expect(purchase.total.toString()).toBe("100000.01");
  });

  it("rounds each line on its own before adding, never the sum", () => {
    const purchase = prepared("IDR", [
      { description: "A", unitPrice: "0.005" },
      { description: "B", unitPrice: "0.005" },
    ]);
    expect(purchase.total.toString()).toBe("0.02");
  });

  it("a currency without minor units rounds to whole units", () => {
    const purchase = prepared("JPY", [{ description: "Item", quantity: "1.5", unitPrice: "1001" }]);
    expect(purchase.total.toString()).toBe("1502");
  });

  it("defaults the quantity to 1 and the treatment to expense", () => {
    const purchase = prepared("IDR", [{ description: "Sewa", unitPrice: "2500000" }]);
    expect(purchase.lines[0].quantity.toString()).toBe("1");
    expect(purchase.lines[0].treatment).toBe("expense");
    expect(purchase.lines[0].lineNo).toBe(1);
  });

  it("keeps the asset and prepaid treatments", () => {
    const purchase = prepared("IDR", [
      { description: "Laptop", unitPrice: "12000000", treatment: "asset" },
      { description: "Asuransi", unitPrice: "1200000", treatment: "prepaid" },
    ]);
    expect(purchase.lines.map((l) => l.treatment)).toEqual(["asset", "prepaid"]);
    expect(purchase.total.toString()).toBe("13200000.00");
  });

  it("refuses what the database refuses", () => {
    expect(problem("IDR", [{ description: "  ", unitPrice: "1" }])).toEqual({
      ok: false,
      problem: "description_required",
      line: 1,
    });
    expect(problem("IDR", [{ description: "x" }]).problem).toBe("price_required");
    expect(problem("IDR", [{ description: "x", unitPrice: "-1" }]).problem).toBe("price_invalid");
    expect(problem("IDR", [{ description: "x", unitPrice: "1.00001" }]).problem).toBe(
      "price_invalid",
    );
    expect(problem("IDR", [{ description: "x", quantity: "0", unitPrice: "1" }]).problem).toBe(
      "quantity_invalid",
    );
    expect(
      problem("IDR", [{ description: "x", quantity: "1.00001", unitPrice: "1" }]).problem,
    ).toBe("quantity_invalid");
    expect(
      problem("IDR", [{ description: "x", unitPrice: "1", treatment: "inventory" }]).problem,
    ).toBe("treatment_invalid");
    expect(
      problem("IDR", [{ description: "x", quantity: "100", unitPrice: "999999999999" }]).problem,
    ).toBe("amount_too_large");
  });

  it("a line that rounds to zero is refused, and so is a free line", () => {
    expect(problem("IDR", [{ description: "x", unitPrice: "0.004" }]).problem).toBe("amount_zero");
    expect(problem("IDR", [{ description: "x", unitPrice: "0" }]).problem).toBe("amount_zero");
  });

  it("names the failing line", () => {
    const result = problem("IDR", [
      { description: "ok", unitPrice: "1" },
      { description: "", unitPrice: "1" },
    ]);
    expect(result.line).toBe(2);
    expect(purchaseProblemMessage(result.problem, result.line)).toMatch(/^Baris 2: /);
  });

  it("at most 200 lines", () => {
    const lines = Array.from({ length: 201 }, () => ({ description: "x", unitPrice: "1" }));
    expect(problem("IDR", lines).problem).toBe("too_many_lines");
  });
});

const idr = (over: Partial<VendorPaymentDraft> = {}): VendorPaymentDraft => ({
  baseCurrency: "IDR",
  accountCurrency: "IDR",
  amount: "1000000",
  allocations: [
    { billId: "bill-a", amount: "1000000", outstanding: "1000000", outstandingBase: "1000000" },
  ],
  ...over,
});

function failed(draft: VendorPaymentDraft) {
  const result = checkVendorPayment(draft);
  if (result.ok) throw new Error("expected a problem");
  return result;
}

describe("vendor payments", () => {
  it("a base-currency payment relieves the payable one for one", () => {
    const result = checkVendorPayment(idr());
    if (!result.ok) throw new Error(result.problem);
    expect(result.figures.cashBase.toString()).toBe("1000000");
    expect(result.figures.payableBase.map(String)).toEqual(["1000000"]);
    expect(result.figures.fxDifference.isZero()).toBe(true);
  });

  it("a payment over several bills equals the sum of its allocations", () => {
    const result = checkVendorPayment(
      idr({
        amount: "3000000",
        allocations: [
          { billId: "a", amount: "1000000", outstanding: "5000000", outstandingBase: "5000000" },
          { billId: "b", amount: "2000000", outstanding: "2000000", outstandingBase: "2000000" },
        ],
      }),
    );
    if (!result.ok) throw new Error(result.problem);
    expect(result.figures.allocated.toString()).toBe("3000000");
    expect(result.figures.payableBase[0].eq(Decimal.parse("1000000"))).toBe(true);
    expect(result.figures.payableBase[1].eq(Decimal.parse("2000000"))).toBe(true);
  });

  it("a foreign payment books the payable at the bill's value and the difference as FX", () => {
    // 1,000 USD booked at 15,000 (15,000,000); 400 USD paid at 15,500 (6,200,000 cash, 6,000,000 payable).
    const result = checkVendorPayment({
      baseCurrency: "IDR",
      accountCurrency: "USD",
      amount: "400",
      rate: "15500",
      allocations: [
        { billId: "a", amount: "400", outstanding: "1000", outstandingBase: "15000000" },
      ],
    });
    if (!result.ok) throw new Error(result.problem);
    expect(result.figures.payableBase[0].eq(Decimal.parse("6000000"))).toBe(true);
    expect(result.figures.cashBase.eq(Decimal.parse("6200000"))).toBe(true);
    expect(result.figures.fxDifference.eq(Decimal.parse("-200000"))).toBe(true);
  });

  it("paying less base value than was booked is a gain", () => {
    const result = checkVendorPayment({
      baseCurrency: "IDR",
      accountCurrency: "USD",
      amount: "1000",
      rate: "14900",
      allocations: [
        { billId: "a", amount: "1000", outstanding: "1000", outstandingBase: "15000000" },
      ],
    });
    if (!result.ok) throw new Error(result.problem);
    expect(result.figures.fxDifference.eq(Decimal.parse("100000"))).toBe(true);
  });

  it("the payment that clears a bill takes exactly what is left, a part takes a rounded share", () => {
    const part = checkVendorPayment({
      baseCurrency: "IDR",
      accountCurrency: "USD",
      amount: "1.00",
      rate: "33.33",
      allocations: [
        { billId: "a", amount: "1.00", outstanding: "3.00", outstandingBase: "100.00" },
      ],
    });
    if (!part.ok) throw new Error(part.problem);
    expect(part.figures.payableBase[0].toString()).toBe("33.33");
    const rest = checkVendorPayment({
      baseCurrency: "IDR",
      accountCurrency: "USD",
      amount: "3.00",
      rate: "33.33",
      allocations: [
        { billId: "a", amount: "3.00", outstanding: "3.00", outstandingBase: "100.00" },
      ],
    });
    if (!rest.ok) throw new Error(rest.problem);
    expect(rest.figures.payableBase[0].toString()).toBe("100.00");
  });

  it("refuses what the database refuses", () => {
    expect(failed(idr({ amount: "0" })).problem).toBe("amount_invalid");
    expect(failed(idr({ amount: "1000000.005" })).problem).toBe("too_many_decimals");
    expect(failed(idr({ rate: "1" })).problem).toBe("rate_not_allowed");
    expect(failed(idr({ allocations: [] })).problem).toBe("no_allocations");
    expect(
      failed({
        baseCurrency: "IDR",
        accountCurrency: "USD",
        amount: "10",
        allocations: [{ billId: "a", amount: "10", outstanding: "10", outstandingBase: "150000" }],
      }).problem,
    ).toBe("rate_required");
    expect(
      failed({
        baseCurrency: "IDR",
        accountCurrency: "USD",
        amount: "10",
        rate: "0",
        allocations: [{ billId: "a", amount: "10", outstanding: "10", outstandingBase: "150000" }],
      }).problem,
    ).toBe("rate_invalid");
  });

  it("the payment must equal its allocations: no advance, no shortfall", () => {
    expect(failed(idr({ amount: "1500000" })).problem).toBe("allocations_differ_from_payment");
    expect(failed(idr({ amount: "500000" })).problem).toBe("allocations_differ_from_payment");
  });

  it("an allocation cannot exceed what is outstanding, and a bill appears once", () => {
    const over = failed(
      idr({
        amount: "1000001",
        allocations: [
          { billId: "a", amount: "1000001", outstanding: "1000000", outstandingBase: "1000000" },
        ],
      }),
    );
    expect(over).toMatchObject({ problem: "allocation_exceeds_outstanding", allocation: 0 });
    const twice = failed(
      idr({
        amount: "200",
        allocations: [
          { billId: "a", amount: "100", outstanding: "1000", outstandingBase: "1000" },
          { billId: "a", amount: "100", outstanding: "1000", outstandingBase: "1000" },
        ],
      }),
    );
    expect(twice).toMatchObject({ problem: "duplicate_bill", allocation: 1 });
    expect(vendorPaymentProblemMessage(twice.problem, twice.allocation)).toMatch(/^Alokasi 2: /);
  });

  it("an exchange difference above 20% of the cash is a mistyped rate", () => {
    const result = failed({
      baseCurrency: "IDR",
      accountCurrency: "USD",
      amount: "1000",
      rate: "30000",
      allocations: [
        { billId: "a", amount: "1000", outstanding: "1000", outstandingBase: "15000000" },
      ],
    });
    expect(result.problem).toBe("fx_difference_too_large");
  });
});

describe("payment dates", () => {
  const today = "2026-09-20";
  it("not in the future, not before the bill", () => {
    expect(checkPaymentDate("2026-09-21", today, [{ billDate: "2026-09-01" }])).toBe("future");
    expect(checkPaymentDate("2026-08-31", today, [{ billDate: "2026-09-01" }])).toBe("before_bill");
    expect(checkPaymentDate("2026-09-01", today, [{ billDate: "2026-09-01" }])).toBeNull();
  });

  it("not before a reversal already booked on the same bill", () => {
    const bills = [{ billDate: "2026-09-01", lastReversedDate: "2026-09-10" }];
    expect(checkPaymentDate("2026-09-09", today, bills)).toBe("before_reversal");
    expect(checkPaymentDate("2026-09-10", today, bills)).toBeNull();
    expect(paymentDateProblemMessage("before_reversal")).toMatch(/dibatalkan/);
  });
});

describe("bill positions", () => {
  it("compares amounts as exact decimals, whatever scale the database printed", () => {
    expect(outstandingOf("5000000.0000", "0").toString()).toBe("5000000.0000");
    expect(outstandingOf("5000000", "5000000.0000").isZero()).toBe(true);
    expect(() => outstandingOf("x", "0")).toThrow();
  });

  it("derives settlement and overdue days from the figures", () => {
    const unpaid = billPosition({
      total: "5000000.0000",
      settled: "0",
      dueDate: "2026-09-10",
      asOf: "2026-09-20",
    });
    expect(unpaid).toMatchObject({ settlement: "unpaid", daysOverdue: 10, isOverdue: true });
    const partial = billPosition({
      total: "5000000.0000",
      settled: "2000000.0000",
      dueDate: "2026-09-20",
      asOf: "2026-09-20",
    });
    expect(partial).toMatchObject({ settlement: "partial", daysOverdue: 0, isOverdue: false });
    expect(partial.outstanding.eq(Decimal.parse("3000000"))).toBe(true);
    const paid = billPosition({
      total: "5000000",
      settled: "5000000.0000",
      dueDate: "2026-01-01",
      asOf: "2026-09-20",
    });
    expect(paid).toMatchObject({ settlement: "paid", daysOverdue: 0, isOverdue: false });
  });

  it("labels every status and knows which documents are still being prepared", () => {
    expect(Object.keys(BILL_STATUS_LABELS)).toHaveLength(5);
    expect(Object.keys(EXPENSE_STATUS_LABELS)).toHaveLength(5);
    expect(isPreparing("draft")).toBe(true);
    expect(isPreparing("submitted")).toBe(true);
    expect(isPreparing("approved")).toBe(false);
    expect(isPreparing("confirmed")).toBe(false);
  });
});
