import { describe, expect, it } from "vitest";
import { Decimal } from "@/domain/money/decimal";
import { invoiceProblemMessage, prepareInvoiceLines, type InvoiceLineDraft } from "./invoice";
import { checkPayment, paymentProblemMessage, prorateRemaining } from "./payment";
import { agingBucket, daysOverdue, settlementStatus } from "./settlement";

function prepared(currency: string, lines: InvoiceLineDraft[]) {
  const result = prepareInvoiceLines(currency, lines);
  if (!result.ok) throw new Error(`unexpected problem ${result.problem} on line ${result.line}`);
  return result.invoice;
}

function problem(currency: string, lines: InvoiceLineDraft[]) {
  const result = prepareInvoiceLines(currency, lines);
  if (result.ok) throw new Error("expected a problem");
  return result;
}

describe("invoice lines", () => {
  it("rounds quantity x price once per line, half-up, to the currency's minor unit", () => {
    const invoice = prepared("IDR", [
      { description: "Jasa", quantity: "3", unitPrice: "33333.335" },
    ]);
    expect(invoice.lines[0].lineSubtotal.toString()).toBe("100000.01");
    expect(invoice.total.toString()).toBe("100000.01");
  });

  it("a tie rounds away from zero", () => {
    const invoice = prepared("IDR", [{ description: "Biaya", quantity: "1", unitPrice: "0.005" }]);
    expect(invoice.total.toString()).toBe("0.01");
  });

  it("a currency without minor units rounds to whole units", () => {
    const invoice = prepared("JPY", [{ description: "Item", quantity: "1.5", unitPrice: "1001" }]);
    expect(invoice.total.toString()).toBe("1502");
  });

  it("a percentage discount rounds once, half-up", () => {
    const invoice = prepared("IDR", [
      {
        description: "Paket",
        quantity: "3",
        unitPrice: "33333.335",
        discountType: "percent",
        discountValue: "10",
      },
    ]);
    // 10% of 100000.01 = 10000.001 -> 10000.00
    expect(invoice.lines[0].discountAmount.toString()).toBe("10000.00");
    expect(invoice.lines[0].lineTotal.toString()).toBe("90000.01");
    const half = prepared("IDR", [
      { description: "x", unitPrice: "100", discountType: "percent", discountValue: "12.5" },
    ]);
    expect(half.lines[0].discountAmount.toString()).toBe("12.50");
  });

  it("a fixed discount must fit the currency and cannot exceed the line", () => {
    expect(
      problem("JPY", [
        { description: "x", unitPrice: "1000", discountType: "fixed", discountValue: "10.5" },
      ]).problem,
    ).toBe("fixed_too_precise");
    expect(
      problem("IDR", [
        { description: "x", unitPrice: "1000", discountType: "fixed", discountValue: "1000.01" },
      ]).problem,
    ).toBe("discount_exceeds_line");
    const ok = prepared("IDR", [
      { description: "x", unitPrice: "1000", discountType: "fixed", discountValue: "1000" },
    ]);
    expect(ok.total.isZero()).toBe(true);
  });

  it("totals add the lines exactly", () => {
    const invoice = prepared("IDR", [
      { description: "A", quantity: "2", unitPrice: "150000" },
      { description: "B", unitPrice: "49999.99", discountType: "fixed", discountValue: "0.99" },
    ]);
    expect(invoice.subtotal.toString()).toBe("349999.99");
    expect(invoice.discountTotal.toString()).toBe("0.99");
    expect(invoice.total.toString()).toBe("349999.00");
    expect(invoice.lines.map((l) => l.lineNo)).toEqual([1, 2]);
  });

  it("refuses what the database refuses, naming the line", () => {
    expect(problem("IDR", [{ description: " ", unitPrice: "1" }])).toMatchObject({
      problem: "description_required",
      line: 1,
    });
    expect(problem("IDR", [{ description: "x", quantity: "0", unitPrice: "1" }]).problem).toBe(
      "quantity_invalid",
    );
    expect(
      problem("IDR", [{ description: "x", quantity: "1.00001", unitPrice: "1" }]).problem,
    ).toBe("quantity_invalid");
    expect(problem("IDR", [{ description: "x" }]).problem).toBe("price_required");
    expect(problem("IDR", [{ description: "x", unitPrice: "-1" }]).problem).toBe("price_invalid");
    expect(problem("IDR", [{ description: "x", unitPrice: "1", discountValue: "5" }]).problem).toBe(
      "discount_without_type",
    );
    expect(
      problem("IDR", [
        { description: "x", unitPrice: "1", discountType: "percent", discountValue: "100.5" },
      ]).problem,
    ).toBe("percent_over_100");
    const second = problem("IDR", [
      { description: "ok", unitPrice: "1" },
      { description: "x", unitPrice: "abc" },
    ]);
    expect(second.line).toBe(2);
    expect(invoiceProblemMessage(second.problem, second.line)).toMatch(/^Baris 2:/);
  });

  it("an empty invoice totals zero and more than 200 lines are refused", () => {
    expect(prepared("IDR", []).total.isZero()).toBe(true);
    const many = Array.from({ length: 201 }, () => ({ description: "x", unitPrice: "1" }));
    expect(problem("IDR", many).problem).toBe("too_many_lines");
  });
});

const dec = (text: string) => Decimal.parse(text);

describe("payment pre-check", () => {
  const same = { baseCurrency: "IDR", accountCurrency: "IDR" } as const;

  it("a partial payment in the base currency", () => {
    const result = checkPayment({
      ...same,
      amount: "400000",
      allocations: [{ amount: "400000", outstanding: "1000000", outstandingBase: "1000000" }],
    });
    if (!result.ok) throw new Error(result.problem);
    expect(result.figures.allocated.eq(dec("400000"))).toBe(true);
    expect(result.figures.advance.isZero()).toBe(true);
    expect(result.figures.fxDifference.isZero()).toBe(true);
    expect(result.figures.receivableBase[0].eq(dec("400000"))).toBe(true);
  });

  it("the payment that clears an invoice takes exactly what is left of its base value", () => {
    expect(prorateRemaining(dec("3"), dec("100.01"), dec("1"), 2).toString()).toBe("33.34");
    expect(prorateRemaining(dec("2"), dec("66.67"), dec("1"), 2).toString()).toBe("33.34");
    expect(prorateRemaining(dec("1"), dec("33.33"), dec("1"), 2).toString()).toBe("33.33");
    // the three parts add up to the invoice's base value, to the cent
    expect(dec("33.34").add(dec("33.34")).add(dec("33.33")).eq(dec("100.01"))).toBe(true);
    expect(() => prorateRemaining(dec("1"), dec("10"), dec("2"), 2)).toThrow();
  });

  it("a foreign-currency payment books the gain or loss against the invoice's own rate", () => {
    const result = checkPayment({
      baseCurrency: "IDR",
      accountCurrency: "USD",
      amount: "400",
      rate: "16000",
      allocations: [{ amount: "400", outstanding: "1000", outstandingBase: "15000000.00" }],
    });
    if (!result.ok) throw new Error(result.problem);
    expect(result.figures.cashBase.toString()).toBe("6400000.00");
    expect(result.figures.receivableBase[0].toString()).toBe("6000000.00");
    expect(result.figures.fxDifference.toString()).toBe("400000.00");
  });

  it("an excess is kept as a customer advance only when the person says so", () => {
    const draft = {
      baseCurrency: "IDR",
      accountCurrency: "USD",
      amount: "1500",
      rate: "16000",
      allocations: [{ amount: "1000", outstanding: "1000", outstandingBase: "16000000.00" }],
    };
    expect(checkPayment(draft)).toMatchObject({ ok: false, problem: "advance_not_confirmed" });
    const result = checkPayment({ ...draft, allowAdvance: true });
    if (!result.ok) throw new Error(result.problem);
    expect(result.figures.advance.toString()).toBe("500");
    expect(result.figures.cashBase.toString()).toBe("24000000.00");
    expect(result.figures.allocatedCashBase.toString()).toBe("16000000.00");
    expect(result.figures.advanceBase.toString()).toBe("8000000.00");
    expect(result.figures.fxDifference.isZero()).toBe(true);
  });

  it("refuses over-allocation, bad rates and mistyped rates", () => {
    const one = { amount: "100", outstanding: "100", outstandingBase: "100" };
    expect(
      checkPayment({ ...same, amount: "100", allocations: [{ ...one, amount: "101" }] }),
    ).toMatchObject({ ok: false, problem: "allocation_exceeds_outstanding", allocation: 0 });
    expect(checkPayment({ ...same, amount: "50", allocations: [one] })).toMatchObject({
      ok: false,
      problem: "allocations_exceed_payment",
    });
    expect(checkPayment({ ...same, amount: "100", rate: "1", allocations: [one] })).toMatchObject({
      ok: false,
      problem: "rate_not_allowed",
    });
    expect(
      checkPayment({
        baseCurrency: "IDR",
        accountCurrency: "USD",
        amount: "100",
        allocations: [one],
      }),
    ).toMatchObject({ ok: false, problem: "rate_required" });
    expect(
      checkPayment({
        baseCurrency: "IDR",
        accountCurrency: "USD",
        amount: "100",
        rate: "30000",
        allocations: [{ amount: "100", outstanding: "100", outstandingBase: "1500000.00" }],
      }),
    ).toMatchObject({ ok: false, problem: "fx_difference_too_large" });
    expect(checkPayment({ ...same, amount: "0", allocations: [] })).toMatchObject({
      ok: false,
      problem: "amount_invalid",
    });
    expect(checkPayment({ ...same, amount: "10.001", allocations: [] })).toMatchObject({
      ok: false,
      problem: "too_many_decimals",
    });
    expect(paymentProblemMessage("allocation_invalid", 1)).toMatch(/^Alokasi 2:/);
  });
});

describe("settlement helpers", () => {
  it("status is derived from what is settled", () => {
    expect(settlementStatus(dec("100"), dec("0"))).toBe("unpaid");
    expect(settlementStatus(dec("100"), dec("40"))).toBe("partial");
    expect(settlementStatus(dec("100"), dec("100.00"))).toBe("paid");
  });

  it("a due date of today is not overdue; months and years are counted in real days", () => {
    expect(daysOverdue("2026-09-20", "2026-09-20")).toBe(0);
    expect(daysOverdue("2026-09-25", "2026-09-20")).toBe(0);
    expect(daysOverdue("2026-08-31", "2026-09-30")).toBe(30);
    expect(daysOverdue("2025-12-31", "2026-01-02")).toBe(2);
    expect(daysOverdue("2024-02-28", "2024-03-01")).toBe(2);
  });

  it("aging buckets follow Step 12", () => {
    expect(agingBucket(0)).toBe("not_due");
    expect(agingBucket(1)).toBe("days_1_30");
    expect(agingBucket(30)).toBe("days_1_30");
    expect(agingBucket(31)).toBe("days_31_60");
    expect(agingBucket(60)).toBe("days_31_60");
    expect(agingBucket(61)).toBe("days_61_90");
    expect(agingBucket(90)).toBe("days_61_90");
    expect(agingBucket(91)).toBe("days_over_90");
  });
});
