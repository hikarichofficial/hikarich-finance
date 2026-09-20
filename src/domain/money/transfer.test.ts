import { describe, expect, it } from "vitest";
import { checkTransfer, transferProblemMessage, type TransferProblem } from "./transfer";

const IDR = { baseCurrency: "IDR", fromCurrency: "IDR", toCurrency: "IDR" } as const;

function figures(result: ReturnType<typeof checkTransfer>) {
  if (!result.ok) throw new Error(`unexpected problem ${result.problem}`);
  return {
    amountIn: result.figures.amountIn.toString(),
    baseOut: result.figures.baseOut.toString(),
    baseIn: result.figures.baseIn.toString(),
    baseFee: result.figures.baseFee.toString(),
    fx: result.figures.fxDifference.toString(),
  };
}

describe("transfer pre-check", () => {
  it("same currency: no FX, the fee is separate", () => {
    const f = figures(checkTransfer({ ...IDR, amountOut: "1000000", fee: "6500" }));
    expect(f).toEqual({
      amountIn: "1000000",
      baseOut: "1000000",
      baseIn: "1000000",
      baseFee: "6500",
      fx: "0",
    });
  });

  it("IDR -> USD: the rate of the USD side gives the base value and the FX difference", () => {
    const f = figures(
      checkTransfer({
        baseCurrency: "IDR",
        fromCurrency: "IDR",
        toCurrency: "USD",
        amountOut: "16000000",
        amountIn: "1000",
        rateIn: "16100",
      }),
    );
    expect(f.baseIn).toBe("16100000.00");
    expect(f.fx).toBe("100000.00");
  });

  it("USD -> IDR: a loss is negative, the fee converts at the source rate", () => {
    const f = figures(
      checkTransfer({
        baseCurrency: "IDR",
        fromCurrency: "USD",
        toCurrency: "IDR",
        amountOut: "100",
        amountIn: "1590000",
        fee: "1.5",
        rateOut: "16000",
      }),
    );
    expect(f.baseOut).toBe("1600000.00");
    expect(f.baseFee).toBe("24000.00");
    expect(f.fx).toBe("-10000.00");
  });

  it("USD -> USD at one rate books no exchange difference", () => {
    const f = figures(
      checkTransfer({
        baseCurrency: "IDR",
        fromCurrency: "USD",
        toCurrency: "USD",
        amountOut: "100",
        rateOut: "16000",
        rateIn: "16000",
      }),
    );
    expect(f.fx).toBe("0.00");
  });

  it("is exact where floating point would drift", () => {
    const f = figures(
      checkTransfer({
        baseCurrency: "IDR",
        fromCurrency: "USD",
        toCurrency: "IDR",
        amountOut: "0.10",
        amountIn: "1600",
        rateOut: "16000.1234567891",
      }),
    );
    expect(f.baseOut).toBe("1600.01");
    expect(f.fx).toBe("-0.01");
  });

  const problems: Array<[TransferProblem, Parameters<typeof checkTransfer>[0]]> = [
    ["amount_invalid", { ...IDR, amountOut: "0" }],
    ["amount_invalid", { ...IDR, amountOut: "abc" }],
    ["amount_invalid", { ...IDR, amountOut: "-5" }],
    ["fee_invalid", { ...IDR, amountOut: "100", fee: "-1" }],
    [
      "amount_in_required",
      {
        baseCurrency: "IDR",
        fromCurrency: "IDR",
        toCurrency: "USD",
        amountOut: "100",
        rateIn: "16000",
      },
    ],
    ["amount_in_differs", { ...IDR, amountOut: "100", amountIn: "99" }],
    ["too_many_decimals", { ...IDR, amountOut: "100.005" }],
    ["rate_not_allowed", { ...IDR, amountOut: "100", rateOut: "1" }],
    [
      "rate_required",
      {
        baseCurrency: "IDR",
        fromCurrency: "IDR",
        toCurrency: "USD",
        amountOut: "16000",
        amountIn: "1",
      },
    ],
    [
      "rate_invalid",
      {
        baseCurrency: "IDR",
        fromCurrency: "IDR",
        toCurrency: "USD",
        amountOut: "16000",
        amountIn: "1",
        rateIn: "0",
      },
    ],
    [
      "rates_differ",
      {
        baseCurrency: "IDR",
        fromCurrency: "USD",
        toCurrency: "USD",
        amountOut: "100",
        rateOut: "16000",
        rateIn: "19000",
      },
    ],
    [
      "too_small",
      {
        baseCurrency: "IDR",
        fromCurrency: "USD",
        toCurrency: "IDR",
        amountOut: "0.01",
        amountIn: "1",
        rateOut: "0.0001",
      },
    ],
    [
      "fx_difference_too_large",
      {
        baseCurrency: "IDR",
        fromCurrency: "IDR",
        toCurrency: "USD",
        amountOut: "16000000",
        amountIn: "1000",
        rateIn: "21000",
      },
    ],
  ];
  it.each(problems)("refuses %s", (problem, draft) => {
    const result = checkTransfer(draft);
    expect(result).toEqual({ ok: false, problem });
    expect(transferProblemMessage(problem).length).toBeGreaterThan(10);
  });
});
