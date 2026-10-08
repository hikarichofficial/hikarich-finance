import { describe, expect, it } from "vitest";
import {
  buildRecurringLinesJson,
  newRecurringLineRow,
  serializedRowKeys,
  type RecurringLineRow,
} from "@/domain/planning/recurringLines";

function row(patch: Partial<RecurringLineRow>): RecurringLineRow {
  return { ...newRecurringLineRow(1), ...patch };
}

describe("buildRecurringLinesJson", () => {
  it("splits a receipt total that includes VAT into the price before VAT and the VAT", () => {
    const json = buildRecurringLinesJson(
      [row({ description: "IndiHome", unit_price: "397000", price_includes_vat: true })],
      "expense",
    );
    const [line] = JSON.parse(json);
    expect(line.unit_price).toBe("357658");
    expect(line.tax_amount).toBe("39342");
  });

  it("leaves the amount as typed when the box is not ticked", () => {
    const [line] = JSON.parse(
      buildRecurringLinesJson([row({ description: "Kertas", unit_price: "50000" })], "expense"),
    );
    expect(line.unit_price).toBe("50000");
    expect(line.tax_amount).toBeUndefined();
  });

  it("does not split a line with a quantity other than 1", () => {
    const [line] = JSON.parse(
      buildRecurringLinesJson(
        [
          row({
            description: "Kabel",
            quantity: "3",
            unit_price: "111000",
            price_includes_vat: true,
          }),
        ],
        "bill",
      ),
    );
    expect(line.unit_price).toBe("111000");
  });

  it("classifies the purchase of an asset as not a withholding object without asking", () => {
    const [asset] = JSON.parse(
      buildRecurringLinesJson(
        [row({ description: "Laptop", unit_price: "9000000", treatment: "asset" })],
        "expense",
      ),
    );
    expect(asset.wht_object).toBe("wht_none");
    const [expense] = JSON.parse(
      buildRecurringLinesJson([row({ description: "Sewa", unit_price: "1000" })], "expense"),
    );
    expect(expense.wht_object).toBeUndefined();
  });
});

describe("serializedRowKeys", () => {
  it("lists the rows that are sent, which is how the database numbers its lines", () => {
    const rows = [
      row({ key: "a", description: "Satu", unit_price: "1" }),
      row({ key: "b", description: "Tanpa jumlah" }),
      row({ key: "c", description: "Tiga", unit_price: "3" }),
    ];
    expect(serializedRowKeys(rows)).toEqual(["a", "c"]);
  });
});
