import { describe, expect, it } from "vitest";
import { Decimal } from "@/domain/money/decimal";
import type { PersonalTariffParams, PersonalTaxSummary } from "@/schemas/personalTax";
import {
  computeCeiling,
  computeFinal,
  computeInstallment,
  computePersonalTax,
  computeProgressive,
  percentOf,
  progressiveTax,
  ptkpLabel,
  roundDownTo,
} from "./personalTax";

const TARIFF: PersonalTariffParams = {
  brackets: [
    { up_to: "60000000", rate: "0.05" },
    { up_to: "250000000", rate: "0.15" },
    { up_to: "500000000", rate: "0.25" },
    { up_to: "5000000000", rate: "0.30" },
    { up_to: null, rate: "0.35" },
  ],
  ptkp: {
    "TK/0": "54000000",
    "K/1": "63000000",
    "K/I/3": "126000000",
  },
  pkp_round_down_to: "1000",
};

const MONTHS = Array.from({ length: 12 }, () => "0");
const ID = "00000000-0000-4000-8000-000000000001";

function summary(over: {
  gross?: string;
  pt?: string;
  costs?: string;
  withheld?: string;
  ptWithheld?: string;
  sales?: string;
  ptkp?: PersonalTaxSummary["ptkp_status"];
  group?: string[];
  paidFinal?: string;
  paidInstallment?: string;
}): PersonalTaxSummary {
  return {
    applicable: true,
    entity_id: ID,
    year: 2026,
    currency: "IDR",
    status: "running",
    ptkp_status: over.ptkp ?? null,
    business: { turnover: over.sales ?? "0", months: MONTHS, withheld_not_credited: "0" },
    freelance: {
      own_gross: over.gross ?? "0",
      own_withheld: over.withheld ?? "0",
      pt_gross: over.pt ?? "0",
      pt_withheld: over.ptWithheld ?? "0",
      months: MONTHS,
    },
    costs: { total: over.costs ?? "0", months: MONTHS },
    payments: {
      final: over.paidFinal ?? "0",
      installment: over.paidInstallment ?? "0",
      installment_months: MONTHS,
    },
    linked_pt: [],
    group: {
      own_turnover: "0",
      others: (over.group ?? []).map((t, i) => ({
        entity_id: ID,
        name: `Buku ${i + 1}`,
        entity_type: "company",
        turnover: t,
      })),
    },
    rules: {
      final: {
        code: "PPH_FINAL_UMKM",
        version: 1,
        params: {
          rate: "0.005",
          annual_ceiling: "4800000000",
          exempt_band: { individual: "500000000" },
        },
      },
      tariff: { code: "PERSONAL_INCOME_TARIFF", version: 1, params: TARIFF },
    },
  };
}

describe("progressiveTax", () => {
  const tax = (n: string) => progressiveTax(Decimal.parse(n), TARIFF.brackets).tax.toString();

  it("taxes each layer at its own rate", () => {
    expect(tax("0")).toBe("0");
    expect(tax("60000000")).toBe("3000000");
    expect(tax("100000000")).toBe("9000000");
    expect(tax("250000000")).toBe("31500000");
    expect(tax("300000000")).toBe("44000000");
    expect(tax("600000000")).toBe("124000000");
  });

  it("splits the amount into layers that add up", () => {
    const { layers } = progressiveTax(Decimal.parse("300000000"), TARIFF.brackets);
    expect(layers.map((l) => l.amount)).toEqual(["60000000", "190000000", "50000000"]);
    expect(layers.map((l) => l.tax)).toEqual(["3000000", "28500000", "12500000"]);
  });

  it("reaches the top layer above Rp 5 miliar", () => {
    // 3 + 28.5 + 62.5 + 1,350 (4,500 jt x 30%) = 1,444 jt, plus 1,000 jt x 35% = 350 jt
    expect(tax("6000000000")).toBe("1794000000");
  });
});

describe("roundDownTo", () => {
  it("drops the rupiah below the step", () => {
    expect(roundDownTo(Decimal.parse("46123456"), Decimal.parse("1000")).toString()).toBe(
      "46123000",
    );
    expect(roundDownTo(Decimal.parse("999"), Decimal.parse("1000")).toString()).toBe("0");
    expect(roundDownTo(Decimal.parse("5000"), Decimal.parse("1000")).toString()).toBe("5000");
  });
});

describe("computeProgressive", () => {
  it("works from net income, less PTKP, rounded down, less the credit", () => {
    const r = computeProgressive(
      summary({ gross: "100123456", costs: "0", withheld: "1000000" }),
      TARIFF,
    );
    expect(r.net).toBe("100123456");
    expect(r.ptkp).toBe("54000000");
    expect(r.ptkpStatusChosen).toBe(false);
    expect(r.taxable).toBe("46123000");
    expect(r.tax).toBe("2306150");
    expect(r.credit).toBe("1000000");
    expect(r.balance).toBe("1306150");
  });

  it("subtracts the tagged costs before PTKP and adds the PT payments", () => {
    const r = computeProgressive(
      summary({
        gross: "60000000",
        pt: "60000000",
        costs: "10000000",
        ptWithheld: "3000000",
        ptkp: "TK/0",
      }),
      TARIFF,
    );
    expect(r.gross).toBe("120000000");
    expect(r.net).toBe("110000000");
    expect(r.taxable).toBe("56000000");
    expect(r.tax).toBe("2800000");
    expect(r.balance).toBe("-200000");
    expect(r.ptkpStatusChosen).toBe(true);
  });

  it("uses the PTKP of the chosen status", () => {
    const r = computeProgressive(summary({ gross: "100000000", ptkp: "K/1" }), TARIFF);
    expect(r.ptkp).toBe("63000000");
    expect(r.taxable).toBe("37000000");
    expect(r.tax).toBe("1850000");
  });

  it("pays nothing while PTKP covers the net income", () => {
    const r = computeProgressive(summary({ gross: "50000000" }), TARIFF);
    expect(r.taxable).toBe("0");
    expect(r.tax).toBe("0");
    expect(r.layers[0].amount).toBe("0");
  });

  it("treats costs above income as no income, not a negative one", () => {
    const r = computeProgressive(summary({ gross: "10000000", costs: "15000000" }), TARIFF);
    expect(r.loss).toBe(true);
    expect(r.net).toBe("0");
    expect(r.tax).toBe("0");
  });

  it("states the tax as a share of the income", () => {
    const r = computeProgressive(summary({ gross: "120000000", costs: "10000000" }), TARIFF);
    expect(r.tax).toBe("2800000");
    expect(r.effectiveRate).toBe("2.33");
  });
});

describe("computeFinal", () => {
  it("is free inside the Rp 500 juta band", () => {
    const r = computeFinal(summary({ sales: "300000000" }), "0.005", "500000000");
    expect(r.tax).toBe("0");
    expect(r.insideBand).toBe(true);
    expect(r.bandLeft).toBe("200000000");
  });

  it("taxes only the part above the band", () => {
    const r = computeFinal(summary({ sales: "600000000" }), "0.005", "500000000");
    expect(r.taxable).toBe("100000000");
    expect(r.tax).toBe("500000");
    expect(r.insideBand).toBe(false);
  });
});

describe("computeCeiling", () => {
  it("adds the other books of the owner", () => {
    const r = computeCeiling(summary({ group: ["2400000000", "1200000000"] }), "4800000000");
    expect(r.total).toBe("3600000000");
    expect(r.share).toBe("0.75");
    expect(r.over).toBe(false);
    expect(r.parts).toHaveLength(3);
  });

  it("flags a total above the ceiling", () => {
    const r = computeCeiling(summary({ group: ["5000000000"] }), "4800000000");
    expect(r.over).toBe(true);
    expect(r.share).toBe("1");
  });
});

describe("computePersonalTax", () => {
  it("adds the final tax and the progressive balance", () => {
    const r = computePersonalTax(
      summary({ sales: "600000000", gross: "120000000", costs: "10000000", withheld: "1000000" }),
    );
    expect(r.ready).toBe(true);
    expect(r.final?.tax).toBe("500000");
    expect(r.progressive?.tax).toBe("2800000");
    expect(r.totalTax).toBe("3300000");
    expect(r.totalToPay).toBe("2300000");
  });

  it("never shows a negative amount to pay", () => {
    const r = computePersonalTax(summary({ gross: "100000000", withheld: "9000000" }));
    expect(r.progressive?.balance).toBe("-6700000");
    expect(r.totalToPay).toBe("0");
  });

  it("subtracts what the person has already paid in, each tax on its own", () => {
    const r = computePersonalTax(
      summary({
        sales: "600000000",
        gross: "120000000",
        costs: "10000000",
        withheld: "1000000",
        paidFinal: "500000",
        paidInstallment: "1000000",
      }),
    );
    expect(r.final?.balance).toBe("0");
    expect(r.progressive?.prepaid).toBe("1000000");
    expect(r.progressive?.balance).toBe("800000");
    expect(r.totalToPay).toBe("800000");
  });

  it("does not let an overpaid instalment cancel the final tax still owed", () => {
    const r = computePersonalTax(
      summary({
        sales: "600000000",
        gross: "100000000",
        withheld: "9000000",
        paidInstallment: "1000000",
      }),
    );
    expect(r.progressive?.balance).toBe("-7700000");
    expect(r.final?.balance).toBe("500000");
    expect(r.totalToPay).toBe("500000");
  });

  it("says so when the rule data is missing", () => {
    const base = summary({});
    const r = computePersonalTax({ ...base, rules: { final: null, tariff: null } });
    expect(r.ready).toBe(false);
    expect(r.notReady).not.toBeNull();
  });
});

describe("helpers", () => {
  it("percentOf keeps two decimals and drops trailing zeros", () => {
    expect(percentOf(Decimal.parse("250000"), Decimal.parse("10000000"))).toBe("2.5");
    expect(percentOf(Decimal.parse("1"), Decimal.parse("3"))).toBe("33.33");
    expect(percentOf(Decimal.parse("5"), Decimal.parse("0"))).toBe("0");
  });

  it("ptkpLabel reads the status in words", () => {
    expect(ptkpLabel("TK/0")).toBe("Tidak kawin, tanpa tanggungan");
    expect(ptkpLabel("K/2")).toBe("Kawin, 2 tanggungan");
    expect(ptkpLabel("K/I/3")).toBe("Kawin, istri berpenghasilan, 3 tanggungan");
  });
});

describe("computeInstallment", () => {
  const prior = (over: Parameters<typeof summary>[0]) => computePersonalTax(summary(over));

  it("is last year's tax less credits divided by 12", () => {
    // gross 120 jt, TK/0: tax 2.800.000 after 10 jt of costs; credit 1.000.000 -> 1.800.000 / 12 = 150.000
    const r = computeInstallment(
      prior({ gross: "120000000", costs: "10000000", withheld: "1000000" }),
      summary({ paidInstallment: "300000" }),
    );
    expect(r.kind).toBe("amount");
    expect(r.basis).toBe("1800000");
    expect(r.monthly).toBe("150000");
    expect(r.paid).toBe("300000");
    expect(r.dueDay).toBe(15);
  });

  it("rounds to whole rupiah, half up", () => {
    // tax 3.000.000 (60 jt over TK/0 54 jt = 6 jt? use gross 114 jt: PKP 60 jt -> 3.000.000) less credit 1 -> 2.999.999 / 12
    const r = computeInstallment(prior({ gross: "114000000", withheld: "1" }), summary({}));
    expect(r.monthly).toBe("250000");
  });

  it("is nil for a new taxpayer with no income last year", () => {
    expect(computeInstallment(null, summary({})).kind).toBe("nihil");
    expect(computeInstallment(prior({}), summary({})).kind).toBe("nihil");
  });

  it("is nil when withholding already covers last year's tax", () => {
    const r = computeInstallment(prior({ gross: "100000000", withheld: "9000000" }), summary({}));
    expect(r.kind).toBe("nihil");
    expect(r.reason).toContain("dipotong");
  });
});
