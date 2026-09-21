import { describe, expect, it } from "vitest";
import { Decimal } from "@/domain/money/decimal";
import {
  EQUITY_KIND_LABELS,
  LOAN_METHOD_LABELS,
  TAX_REVIEW_LABELS,
  addMonthsClamped,
  divideRounded,
  equityNeedsApproval,
  loanOutstanding,
  loanPlan,
  type EquityKind,
  type LoanPlanInput,
} from "./financing";

function planOf(input: Partial<LoanPlanInput> = {}) {
  const result = loanPlan({
    method: "annuity",
    principal: "12000000",
    ratePercent: "12",
    installments: 12,
    stepMonths: 1,
    firstDue: "2027-01-31",
    ...input,
  });
  if (!result.ok) throw new Error(`unexpected problem ${result.problem}`);
  return result;
}

describe("exact division", () => {
  it("rounds half up to the requested scale", () => {
    expect(divideRounded(Decimal.parse("10"), Decimal.parse("3"), 2).toString()).toBe("3.33");
    expect(divideRounded(Decimal.parse("20"), Decimal.parse("3"), 2).toString()).toBe("6.67");
    expect(divideRounded(Decimal.parse("1"), Decimal.parse("8"), 2).toString()).toBe("0.13");
    expect(divideRounded(Decimal.parse("-1"), Decimal.parse("8"), 2).toString()).toBe("-0.13");
    expect(divideRounded(Decimal.parse("1.5"), Decimal.parse("0.25"), 0).toString()).toBe("6");
  });

  it("refuses to divide by zero", () => {
    expect(() => divideRounded(Decimal.parse("1"), Decimal.zero(), 2)).toThrow(RangeError);
  });
});

describe("month arithmetic like PostgreSQL", () => {
  it("keeps the day, or clamps to the end of a shorter month", () => {
    expect(addMonthsClamped("2027-01-31", 1)).toBe("2027-02-28");
    expect(addMonthsClamped("2027-01-31", 2)).toBe("2027-03-31");
    expect(addMonthsClamped("2028-01-31", 1)).toBe("2028-02-29");
    expect(addMonthsClamped("2027-03-15", 3)).toBe("2027-06-15");
    expect(addMonthsClamped("2027-11-30", 3)).toBe("2028-02-29");
    expect(addMonthsClamped("2027-12-31", 12)).toBe("2028-12-31");
  });
});

describe("the loan schedule (the same figures as app_private.loan_plan)", () => {
  it("annuity: 12,000,000 at 12% over 12 months", () => {
    const { rows } = planOf();
    expect(rows).toHaveLength(12);
    expect(rows[0].interest.toString()).toBe("120000.00");
    expect(rows[0].principal.toString()).toBe("946185.46");
    expect(rows[1].principal.toString()).toBe("955647.31");
    expect(rows[1].interest.toString()).toBe("110538.15");
    expect(rows[10].principal.toString()).toBe("1045177.39");
    expect(rows[11].principal.toString()).toBe("1055629.23");
    expect(rows[11].interest.toString()).toBe("10556.29");
    expect(rows[11].dueDate).toBe("2027-12-31");
  });

  it("annuity: the principal parts add up exactly, whatever the rounding", () => {
    const { rows, totalInterest } = planOf({
      principal: "7777777.77",
      ratePercent: "13.37",
      installments: 24,
    });
    const sum = rows.reduce((total, row) => total.add(row.principal), Decimal.zero());
    expect(sum.toString()).toBe("7777777.77");
    expect(rows[0].principal.toString()).toBe("284465.47");
    expect(rows[0].interest.toString()).toBe("86657.41");
    expect(rows[22].principal.toString()).toBe("362989.21");
    expect(rows[23].principal.toString()).toBe("367033.67");
    expect(totalInterest.toString()).toBe("1129171.51");
  });

  it("annuity: payments are equal apart from the rounding and the principal part grows", () => {
    const { rows } = planOf();
    const totals = rows.slice(0, 11).map((row) => row.total);
    const spread = totals
      .reduce((max, t) => (t.cmp(max) > 0 ? t : max))
      .sub(totals.reduce((min, t) => (t.cmp(min) < 0 ? t : min)));
    expect(spread.cmp(Decimal.parse("0.02")) < 0).toBe(true);
    for (let i = 1; i < rows.length; i += 1) {
      expect(rows[i].principal.cmp(rows[i - 1].principal)).toBe(1);
    }
  });

  it("a zero rate schedules equal principal and no interest", () => {
    const { rows, totalInterest } = planOf({ ratePercent: "0", principal: "1200000" });
    expect(totalInterest.isZero()).toBe(true);
    expect(rows.every((row) => row.principal.toString() === "100000.00")).toBe(true);
  });

  it("flat: interest on the original principal, the last part absorbs the remainder", () => {
    const { rows } = planOf({
      method: "flat",
      principal: "1000000",
      ratePercent: "10",
      installments: 3,
    });
    expect(rows.map((row) => row.principal.toString())).toEqual([
      "333333.33",
      "333333.33",
      "333333.34",
    ]);
    expect(rows.every((row) => row.interest.toString() === "8333.33")).toBe(true);
    expect(rows.map((row) => row.dueDate)).toEqual(["2027-01-31", "2027-02-28", "2027-03-31"]);
  });

  it("interest only: interest every step, all principal at the end", () => {
    const { rows } = planOf({
      method: "interest_only",
      principal: "5000000",
      ratePercent: "9.75",
      installments: 6,
      stepMonths: 3,
      firstDue: "2027-03-31",
    });
    expect(rows.slice(0, 5).every((row) => row.principal.isZero())).toBe(true);
    expect(rows[5].principal.toString()).toBe("5000000.00");
    expect(rows.every((row) => row.interest.toString() === "121875.00")).toBe(true);
    expect(rows.map((row) => row.dueDate)).toEqual([
      "2027-03-31",
      "2027-06-30",
      "2027-09-30",
      "2027-12-31",
      "2028-03-31",
      "2028-06-30",
    ]);
  });

  it("a single installment repays the principal", () => {
    const { rows } = planOf({ principal: "500000", installments: 1, ratePercent: "9" });
    expect(rows).toHaveLength(1);
    expect(rows[0].principal.toString()).toBe("500000.00");
  });

  it("reports what is wrong instead of guessing", () => {
    const base: LoanPlanInput = {
      method: "annuity",
      principal: "1000",
      ratePercent: "12",
      installments: 12,
      stepMonths: 1,
      firstDue: "2027-01-31",
    };
    const problem = (patch: Partial<LoanPlanInput>) => {
      const result = loanPlan({ ...base, ...patch });
      return result.ok ? null : result.problem;
    };
    expect(problem({ principal: "0" })).toBe("principal");
    expect(problem({ principal: "abc" })).toBe("principal");
    expect(problem({ principal: "10.005" })).toBe("principal");
    expect(problem({ ratePercent: "120" })).toBe("rate");
    expect(problem({ ratePercent: "-1" })).toBe("rate");
    expect(problem({ installments: 0 })).toBe("installments");
    expect(problem({ installments: 601 })).toBe("installments");
    expect(problem({ stepMonths: 2 as 1 })).toBe("step");
    expect(problem({ method: "balloon" as "flat" })).toBe("method");
    expect(problem({ firstDue: "31/01/2027" })).toBe("first_due");
    expect(problem({})).toBeNull();
  });
});

describe("outstanding principal", () => {
  it("is what was funded less repaid and written off, never below zero", () => {
    expect(loanOutstanding("12000000", "500000").toString()).toBe("11500000");
    expect(loanOutstanding("12000000", "500000", "1000000").toString()).toBe("10500000");
    expect(loanOutstanding("1000", "2000").isZero()).toBe(true);
  });
});

describe("labels and rules", () => {
  it("labels every equity kind, method and tax status", () => {
    const kinds: EquityKind[] = [
      "contribution",
      "capital_return",
      "dividend",
      "investment_contribution",
      "investment_return",
      "distribution_received",
    ];
    for (const kind of kinds) expect(EQUITY_KIND_LABELS[kind].length).toBeGreaterThan(0);
    expect(Object.keys(LOAN_METHOD_LABELS)).toHaveLength(4);
    expect(Object.keys(TAX_REVIEW_LABELS)).toHaveLength(3);
  });

  it("only a dividend and a capital return need the owner's approval", () => {
    expect(equityNeedsApproval("dividend")).toBe(true);
    expect(equityNeedsApproval("capital_return")).toBe(true);
    expect(equityNeedsApproval("contribution")).toBe(false);
    expect(equityNeedsApproval("distribution_received")).toBe(false);
  });
});
