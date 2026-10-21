import { describe, expect, it } from "vitest";
import { type AiExtraction, aiToParsed } from "./ai";

const TODAY = "2026-10-21";
const base: AiExtraction = {
  kind: "expense",
  merchant: "Kopi Kenangan",
  date: "2026-10-20",
  items: [],
  total: null,
  paymentMethod: null,
  entity: null,
  periodText: null,
};

describe("aiToParsed", () => {
  it("turns a receipt into lines and keeps tax visible", () => {
    const r = aiToParsed(
      {
        ...base,
        items: [
          { description: "Kopi susu", amount: 30_000 },
          { description: "Roti", amount: 20_000 },
        ],
        total: 55_000,
        paymentMethod: "GoPay",
      },
      TODAY,
    );
    expect(r?.total).toBe(55_000);
    expect(r?.lines.at(-1)?.description).toContain("Pajak");
    expect(r?.payee).toBe("Kopi Kenangan");
    expect(r?.accountWords).toEqual(["gopay"]);
    expect(r?.date).toBe("2026-10-20");
  });
  it("trusts the total when items add up to more", () => {
    const r = aiToParsed(
      { ...base, items: [{ description: "A", amount: 60_000 }], total: 50_000 },
      TODAY,
    );
    expect(r?.lines).toHaveLength(1);
    expect(r?.total).toBe(50_000);
  });
  it("uses only a total when there are no items", () => {
    expect(aiToParsed({ ...base, total: 85_000 }, TODAY)?.lines[0]?.description).toBe(
      "Pembelian di Kopi Kenangan",
    );
  });
  it("rejects nonsense", () => {
    expect(aiToParsed({ ...base }, TODAY)).toBeNull();
    expect(aiToParsed({ ...base, kind: "other", total: 5000 }, TODAY)).toBeNull();
    expect(
      aiToParsed(
        {
          ...base,
          items: [
            { description: "x", amount: -5 },
            { description: "y", amount: Number.NaN },
          ],
        },
        TODAY,
      ),
    ).toBeNull();
  });
  it("ignores future or malformed dates and strips markup", () => {
    expect(aiToParsed({ ...base, date: "2027-01-01", total: 1000 }, TODAY)?.date).toBeNull();
    expect(aiToParsed({ ...base, date: "20/10/2026", total: 1000 }, TODAY)?.date).toBeNull();
    expect(aiToParsed({ ...base, merchant: "<b>Toko</b>", total: 1000 }, TODAY)?.payee).toBe(
      "Toko",
    );
  });
});
