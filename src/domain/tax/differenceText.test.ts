import { describe, expect, it } from "vitest";
import { differenceDetailText } from "./differenceText";

describe("differenceDetailText", () => {
  it("translates a missing filing", () => {
    expect(
      differenceDetailText(
        { code: "filing_missing", text: "No filing is recorded for this period", amount: null },
        "IDR",
      ),
    ).toBe("Belum ada pelaporan yang dicatat untuk masa pajak ini.");
  });
  it("reads the amount out of an unpaid sentence", () => {
    const text = differenceDetailText(
      {
        code: "unpaid",
        text: "150000 of the tax for this period is not paid yet",
        amount: "150000",
      },
      "IDR",
    );
    expect(text).toContain("belum dibayar");
    expect(text).toContain("150.000");
  });
  it("falls back to the original text for an unknown code", () => {
    expect(differenceDetailText({ code: "x", text: "Something", amount: null }, "IDR")).toBe(
      "Something",
    );
  });
});
